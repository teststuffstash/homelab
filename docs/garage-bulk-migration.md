# Garage data → longhorn-bulk migration (executed 2026-07-13)

_One-shot recipe, kept because STS volumeClaimTemplates are immutable — any future PVC
class/size change on a StatefulSet repeats this dance. Context: ADR-089 bulk tier;
`tofu/garage.tf` holds the target values (150Gi / `longhorn-bulk`)._

**Shape: PV-rebind, not copy-out-copy-back.** A temp-PVC round trip needs headroom for
old+temp+new simultaneously — and at execution time bulk had ~152G (new alone = 150G) and std
≤9G, so the staged temp-copy variant could not schedule. Rebinding the old PV under a new PVC
name needs zero extra capacity and keeps the original data intact as the rollback until the
final cleanup.

1. **Retain the old PV** (rollback insurance):
   `kubectl -n garage patch pv <old-pv> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'`
2. **Quiesce**: `kubectl -n garage scale sts garage --replicas=0` — writers (loki, transcript
   uploads, apps) buffer/retry; minutes of S3 downtime is the accepted cost.
3. **Orphan-delete the STS** (frees the volumeClaimTemplate for recreation):
   `kubectl -n garage delete sts garage --cascade=orphan`
4. **Free the PVC name**: `kubectl -n garage delete pvc data-garage-0` → PV goes `Released`
   (data safe, Retain).
5. **Rebind old data under a rollback name**: clear the PV's claimRef
   (`kubectl patch pv <old-pv> --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'`),
   then create PVC `garage-data-old` (same class/size, `volumeName:` pinned to the old PV).
6. **Create the new `data-garage-0`**: `longhorn-bulk` / 150Gi (must match the new VCT exactly
   or the recreated STS won't adopt it).
7. **Copy**: a one-shot pod mounting both, `cp -a /old/. /new/`.
8. **Recreate the STS from code**: `devbox run tf-apply -- -target=helm_release.garage`
   (the helm upgrade recreates the STS with the new VCT; it adopts `data-garage-0` and the
   untouched `meta-garage-0`).
9. **Grow the Garage layout** (the fs is bigger but Garage still books its old capacity):
   `garage layout assign -z dc1 -c 140G <node-id>` + `garage layout apply --version <n>`
   (see docs/garage.md; 140G leaves fs slack under the 150Gi volume).
10. **Verify**: `garage status` (capacity, no pending layout), `garage bucket list`, loki still
    ingesting (its chunks flush within minutes), `devbox run garage-s3 s3 ls`.
11. **Cleanup after a soak day**: delete PVC `garage-data-old` and the Released old PV.

Rollback at any point before step 11: scale to 0, delete the new `data-garage-0`, recreate it
with the OLD class/size pinned to the old PV (step-5 style), revert `tofu/garage.tf`, apply.
