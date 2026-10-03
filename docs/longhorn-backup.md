# Longhorn backup — the target outside Longhorn, the classes, the restore

_Tracked by FU-299 ([`follow-ups.md`](follow-ups.md)). Capacity sums: [`storage-ledger.md`](storage-ledger.md).
In-cluster Garage (a different thing): [`garage.md`](garage.md). Machine row: [`/machines/`](../machines/)._

Until 2026-10-03 Longhorn had **no backup at all**: the BackupTarget `default` had an empty URL,
there were 0 RecurringJobs and 0 Backups. ADR-031's aside about "Longhorn/HA backups currently sent
to external S3/B2" was stale. That matters beyond data loss. A Longhorn upgrade cannot be
downgraded, so **restore is the only rollback** a bad Longhorn upgrade has.

## The target

A **single-node Garage v2.3.0** in an unprivileged LXC, **CT 220 `backup-garage` @ `192.168.2.73`
on nx-02**. Its rootfs is 400 G thin on nx-02's 700 G SA400 `local-lvm` pool. S3 is on `:3900`,
`/health` and `/metrics` are on `:3903`. One bucket (`longhorn-backup`) and one key (`longhorn-backup`, RW).

| Piece | Home |
|---|---|
| the LXC | `tofu/provisioning/backup-target.tf` — the root that survives a cluster wipe, like Matchbox |
| Garage (binary, config, layout, bucket, key) | `ansible/garage-backup.yml` → `roles/garage-backup` (idempotent; re-run converges) |
| BackupTarget `default` | `tofu/longhorn.tf` chart values `defaultBackupStore` (`s3://longhorn-backup@garage/`) |
| credential Secret `longhorn-system/longhorn-backup-target` | ExternalSecret in `argocd/resources/longhorn-backup/` ← Infisical `LONGHORN_BACKUP_{KEY_ID,SECRET}` |
| canonical key | wallet `longhorn-backup-key-id` / `longhorn-backup-secret` |
| belts | `LonghornBackupTargetDown` (blackbox `/health`), `LonghornBackupStale` (newest backup > 36 h) — same dir, promtool-pinned |

**Why outside Longhorn.** The in-cluster Garage rides `longhorn-local-xfs`. A Longhorn failure
would take the copies along with the originals.

**Why an LXC, not a VM.** On 2026-10-02 nx-02's VMs had 60.5 of its 62 GiB committed, and NUMA
node0 had 625 MB free. A container costs only what Garage uses. The pool is already metered
(`pve_lvm_thin_pool_data_percent{host="nx-02"}`, the PveThinPool* alerts).

**Why rf=1.** The backup is itself the redundancy. A second copy belongs off-site, not as a second
replica inside the same LXC.

**Same failure domain, accepted for now.** nx-02 is one chassis with nx-01 (storage-ledger's
"ONE failure domain" row), and it carries no Longhorn replica. So a disk or Longhorn failure on the
std/bulk tiers cannot reach the target. Losing the nx-02 box loses only the backups, never the
originals. The off-site copy is what closes the gap for a whole-site loss.

## Classes — which volumes are backed up

Read live on 2026-10-03 (43 volumes). This is a **proposal until the RecurringJob lands**; the
class is per PVC.

| Class | Volumes | Why | Actual size |
|---|---|---|---|
| **daily** | `home-assistant-config`, `unifi-config`, `unifi-mongo`, `forgejo/gitea-shared-storage`, the CNPG instance volumes (`infisical-pg-*`, `forgejo-pg-*`, `grafana-pg-*`, `oracle-pg-*`), `coordinator-transcripts` (×5) | irreplaceable state. A CNPG volume snapshot is crash-consistent, which Postgres recovers from. CNPG-native `ScheduledBackup` ([`postgres.md`](postgres.md)) would be better and stays a separate choice | ≈ 14 G |
| **none — rebuildable** | the registry/pypi/npm/nix/uv caches, `mirror-*`, `arc-uv-cache`, `registry-data` (CI rebuilds it), `devbox-search-data`, eventbus JetStream, `redis` | a cache re-warms. A day of slow builds is the cost, not data loss | — |
| **none — accepted loss** | `prometheus-*`, `data-loki-0`, `alertmanager`, `pushgateway` | telemetry history. Losing it is acceptable | — |
| **none — own replication** | `data-garage-*`, `meta-garage-*` | Garage rf=3 across three zones. 340 G does not fit here, and backing up Garage means bucket-level copies off-site, not block backups | — |

## Restore — the recipe the drill proved

FU-299's drill, step by step, run against a throwaway volume:

1. A PVC `backup-drill` (1 Gi, default class) in a scratch namespace, written by a pod with a known
   file + its `sha256sum`.
2. Backup: a Longhorn `Snapshot` CR → a `Backup` CR naming it (or the UI's "Create Backup"). Wait
   for `status.state: Completed`, and check that a `BackupVolume` exists on the target.
3. Delete the PVC (the volume goes with it).
4. Restore: a Longhorn `Volume` CR with `spec.fromBackup: <backup URL>`. Then a PV/PVC bound to it
   (`kubectl` or the UI's "Create PV/PVC").
5. A pod mounts the restored PVC and compares the checksum.

**After a total loss**, Infisical is gone too, because it rides Longhorn. Seed the Secret from the
wallet first:

```bash
kubectl -n longhorn-system create secret generic longhorn-backup-target \
  --from-literal=AWS_ACCESS_KEY_ID="$(keepassxc-cli show … longhorn-backup-key-id -a Password)" \
  --from-literal=AWS_SECRET_ACCESS_KEY="$(keepassxc-cli show … longhorn-backup-secret -a Password)" \
  --from-literal=AWS_ENDPOINTS=http://192.168.2.73:3900
```

Then restore Infisical's CNPG volumes first. ESO takes the Secret back over once Infisical serves.

## Open

The FU tracks these, not this doc:

- the daily RecurringJob for the **daily** class
- the off-site second copy
- a periodic restore drill
