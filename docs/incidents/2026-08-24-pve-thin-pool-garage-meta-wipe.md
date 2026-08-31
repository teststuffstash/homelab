# 2026-08-24 — pve thin pool hit 100% (third time), froze wk-01 twice, and wiped Garage's metadata

**Triggers: cascade + third occurrence.** The `pve/data` LVM thin pool filling is the exact
failure [`docs/storage-ledger.md`](../storage-ledger.md) §"A THIRD sum" predicted and "resolved"
on 2026-08-07 — this is its third fill (2026-08-07, 2026-08-18 inferred, 2026-08-24), and this
time one cause degraded five namespaces and destroyed the Garage metadata DB.

## Timeline (UTC)

- **08-07** — pool found at 99.14%; extended +15G, `thin_pool_autoextend_threshold=80` armed,
  `discard=on` + one-shot trim → 47.69%. The extend left the VG with **257 free extents (~1G)**.
- **08-17 22:19** — pool crossed 80%; dmeventd autoextend **failed**: `Insufficient free space:
  18067 extents needed, but only 257 available`. No alert — no pve-layer exporter exists.
- **08-18 ~15:50** — (inferred) pool reached 100%; wk-01 froze — the "unexplained reboot"
  homelab#883 remembers. Garage's meta volume grew a rebuilt replica on hp-01 at 15:53; garage-0
  restarted onto wk-01.
- **08-24 14:04** — dmeventd: pool **100.00% full**; wk-01 guest I/O stalls.
- **14:18** — wk-01 kubelet stops posting, node NotReady. `prometheus-...-0` (on wk-01) stuck
  Terminating; StatefulSet cannot recreate it → **Grafana and Alertmanager both show no data**
  (the operator's first symptom).
- **14:25** — taint eviction stamps deletionTimestamps on wk-01's pods (garage-0, loki-0,
  forgejo, forgejo-pg-1, infisical-pg-3, home-assistant, registry mirrors, eventbus,
  openrouter-proxy) — all wedge in Unknown/Terminating.
- **15:14–15:17** — jail session: `qm reset 8111` ineffective (QEMU wedged in `prelaunch`,
  109% CPU); `qm stop` + `qm start` recovers it. **15:18** wk-01 Ready.
- **15:26–15:28** — post-reboot kubelet never confirms the old deletions; all stuck pods
  force-deleted; replacements schedule (garage-0 → wk-02).
- **15:30–15:31** — meta volume reattaches on wk-02 (rebuild from the hp-01 replica);
  garage-0 opens the LMDB **cleanly — no corruption error — and every table is empty**
  (first `Bucket not found` at 15:31:04). Crossplane reconciles the 14 Bucket/Key CRs against
  the empty store and recreates them all, fresh and zero-object.
- **15:40–15:45** — responder files homelab#883 (wk-01 unreachable), #884 (Garage metadata
  wiped platform-wide — correct diagnosis, `report-only`), #885 (Longhorn PDB).
- **15:41** — recovery writes push the still-full pool to 100% again; wk-01 pauses with
  `qm status` **io-error** (second hang).
- **15:39–15:52** — `fstrim` via node-debug pods: wk-02 returned **236GiB**, wk-03 36GiB,
  wk-01 76GiB (after `qm resume`); pool **100% → 56%**. All nodes Ready; Prometheus 2/2;
  Grafana/Alertmanager verified serving data.
- **~16:10** — Longhorn snapshot `pre-restore-2026-08-24-meta-wipe` taken of the garage
  **data** volume (55GB of blocks — intact); `metadata_fsync = true` +
  `metadata_auto_snapshot_interval = 6h` landed (`57fbb0e5`).

## Root cause

Thin-pool overcommit (488G promised on 352.86G) with **no return path for freed blocks**: Talos
guests never run fstrim, so `discard=on` (the 08-07 fix) only ever helped once, at the moment it
was applied with a manual trim. Deletes inside the guests (registry-mirror GC, Longhorn replica
churn, loki retention) freed filesystem space that the pool never got back — wk-02 held 225G of
pool blocks for 88.5GiB of real use. The autoextend belt was armed on 08-07 but had 257 extents
of VG to draw from, i.e. it was decorative, and the ledger's own caveat said so. Nothing meters
the pve layer, so the 08-17 threshold breach and both 100% events fired no alert (predicted
verbatim in storage-ledger.md: "no alert could have fired").

**Garage metadata loss mechanism — best guess, labelled as such:** `metadata_fsync` was unset,
and Garage's default is **false**; a hard VM freeze/stop can therefore lose committed LMDB
state. Ruled out: the init container re-creating the DB (it only templates garage.toml); a
stale-replica revert at the filesystem level (`lifecycle_worker_state` mtime 2026-08-24 00:00
was present on the recovered volume); Longhorn reporting any fault (volume attached healthy).
Not explained: why a clean `mdb_env_open` yielded *empty* tables rather than merely losing
recent transactions — June-era pages were long since synced. The 2.4GB `data.mdb` (file dates
June 14) still sits on the meta volume; the single Longhorn snapshot (15:31:05) almost certainly
post-dates the wipe (empty reads began 15:31:04).

## Collateral

- Monitoring dark ~1h15m (Prometheus pinned to wk-01 by its Longhorn PVC attachment).
- **Garage: all 14 buckets reset to empty.** Data blocks (55GB) survived; metadata did not.
  loki had 158,286 objects / 9.1GiB at 08:36 (recorded by #811). agent-transcripts is flagged
  irreplaceable in docs/garage.md. Local object backup exists: `backups/garage/` on the jail
  host, **last synced 2026-08-04** (4.8G) — the restore decision is the operator's, tracked in
  homelab#884 / FU-137.
- specs.oracle.teststuff.net (and every Garage web endpoint) 404.
- openrouter-operator OOM-crashlooped after rescheduling off wk-01 (256Mi limit vs ~75-CR
  resume) — limit → 512Mi (`d1cdf37c`), a belt not a root-cause fix.
- Longhorn instance-manager PDB alert (#885) — self-resolved when wk-01 returned.
- Argo/coordinator pods errored through the window (#869/#873/#880 runs).

## Fixes

- fstrim of all four VMs — **mitigation**, pool 100% → 56% (this recurs without a periodic trim).
- `qm stop/start` + `qm resume` of wk-01 — recovery, not a fix.
- `metadata_fsync = true` + 6h LMDB auto-snapshot (`57fbb0e5`) — root-cause-class for the *data
  loss*, does nothing for the *pool*.
- openrouter-operator 512Mi (`d1cdf37c`) — belt.
- Residual (the actual pool fix + metering + restore): FU-093, FU-137.

## Probe lesson

- `qm list` saying `running` proves only that QEMU exists. `qm status <id>` distinguishes
  `prelaunch` (wedged — reset won't take, needs stop/start) from `io-error` (paused on a full
  pool — `qm resume` after freeing space, state preserved, no reboot).
- The one metric that predicted everything: `lvs pve/data` Data%. It lives below every layer we
  meter and above none that alerts.
- fstrim on Talos: `kubectl debug node/<n> -n kube-system --profile=sysadmin` (PodSecurity
  blocks it in `default`), then `fstrim /host/var`. Shell variables don't survive the debug
  arg path — use literal paths.
- A StatefulSet pod on a dead-then-rebooted node can wedge forever: the reborn kubelet no longer
  knows the old pod and never confirms its deletion — force-delete is safe once the VM is
  *verifiably* power-cycled.
- Crossplane recreating buckets is camouflage: "the bucket exists" post-incident proves
  reconciliation, not survival. Check `Created:` dates.

## Restore (same day, operator go ~16:50Z)

Aug-4 backup re-uploaded in full — all 11 buckets count-verified (351,683 objects; allure-reports
needed one idempotent re-sync for 10 failed PUTs). Content-addressing re-adopted matching orphan
blocks in place. `homelab-browse` + `tofu-state` keys re-imported with wallet id/secret.
**The stale-key tail:** Crossplane re-minted every app key with NEW ids; consumers whose secret
is a *static copy* (Infisical-held: sleep-ingester) or whose pod predated the re-mint (loki-0,
grafana's sleep sidecar) kept 403ing — loki silently failed every flush for ~28h ("No such key:
GK…" in its log was the tell). Fixed by restarting the stale pods and re-importing the old sleep
keys via `garage key import` (ESO chains reading in-cluster Kubernetes stores self-healed;
static stores did not — that asymmetry is the lesson). specs.oracle 200, sleep-ingester verify
job green, loki flushing clean, restore key deleted.
**And a second half of that same asymmetry, found 2026-08-25 — a re-imported key comes back
WITHOUT its grants.** `garage key import` restores the id/secret so cached credentials keep
working; the bucket↔key permissions live in the wiped metadata and are not part of the import.
The 21 app keys were fine because Crossplane declares bucket+key+grant together and replayed all
three. Of the two hand-made keys re-imported above, `tofu-state` was re-granted and
`homelab-browse` was not — so for 24h it authenticated correctly and returned `AccessDenied` on
every bucket (`Operation is not allowed for this key`, which is the *grant* failure; the stale-key
tail above says `No such key`, which is the *identity* failure — the two read very differently and
are worth telling apart). Re-granted 2026-08-25 and verified by fetching an object over the LAN
endpoint. A full sweep the same day found all 23 keys correctly granted, all 31 in-cluster Secret
references pointing at live keys, and no other pod predating the wipe holding S3 credentials. Buckets born after Aug 4 had no backup:
`jail-transcripts` (forensic target), `circles-specs` (regenerated).

## Tier-2 recovery — the Aug-4→24 delta carved back out (same day, evening)

The Aug-4 restore left a 20-day hole. It turned out to be recoverable in full: Garage purges orphan
blocks only on a **manual** `garage repair blocks`, so the content was still on disk, and LMDB's
copy-on-write meant the emptied tables' old pages were still readable in the frozen meta-volume
layer. Tier-1 (afternoon) proved the pages were there; Tier-2 (evening) decoded them. Method and
tooling: [`scripts/garage-forensics/`](../../scripts/garage-forensics/README.md).

- **10,846 objects / 2.14 GB re-uploaded, 0 failures** — 4,846 recoverable from metadata alone
  (Garage inlines small objects), 6,000 reassembled from blocks, every one joined to its version
  row. Each object's md5 was checked against the pre-wipe ETag before the PUT.
- **`jail-transcripts` (224 objects, 322 MB) came back from nothing** — the bucket post-dated the
  Aug-4 backup, so this was its only copy.
- **Verified over a second path** (LAN endpoint, not the in-cluster Service): 10,843 of 10,846 exact
  on size + ETag.
- **`cloudflare/terraform.tfstate` recovered**: carved serial 2 (Aug-9 12:15Z) replaced the restored
  serial 1, same lineage. The first plan then wanted one resource — `minutark_www`, which exists in
  Cloudflare but whose state write also fell in the hole — `tofu import`ed it; **re-plan reports no
  changes**. The pre-swap serial-1 copy is kept alongside the evidence.
- **The restore's silent tail, found by the verify pass:** the never-overwrite rule correctly skips
  keys that exist, which means *mutable singletons* restored from the Aug-4 backup stay regressed —
  `_ledger.jsonl` had lost 299 of 387 rows and `_model-scout/known-models.json` 90 of 416 ids.
  Both merged (union, live wins per key) and re-uploaded. Left alone, the scout's next tick would
  have re-announced ~90 models as new and canaried them.

**Still frozen, deliberately:** `backups/garage-meta-forensics/` (the meta layer images) and the
`pre-restore-2026-08-24-meta-wipe` Longhorn snapshot. The `garage repair blocks` hold stays ON: the
metadata for the out-of-scope buckets (loki, allure, oracle `parsed/`, sleep) is equally intact in
that layer, and repair would foreclose recovering them. Widening the carve is an operator call on
homelab#884 — the scope was narrowed when Tier-2's cost was unknown, and it is now a proven pipeline.

## Tier-3 — the widened carve (2026-08-25), and the two failures it caused

Operator widened the scope to the remaining buckets. One pass over the same frozen layer carved the
**whole store: 956,600 objects, zero orphan versions**, and recovered the **bucket_alias table**
(all 14 names → old ids), so buckets were identified exactly rather than guessed from key shapes —
which corrected an assumption: the `parsed/` prefix is in **ert-snapshots**, not an oracle bucket.
`ert-snapshots` and `circles-specs` were at **0 objects live** (never in the Aug-4 backup), so like
`jail-transcripts` they were from-nothing recoveries. Live-key filtering left 544,548 objects.

Outcome: **361,484 restored, 0 failures**; 884 blocks genuinely gone (loki chunks deleted before
the wipe — their rc had already dropped, so normal GC took them); 214 blocked by `oracle-specs`
hitting its **1.0 GiB bucket quota** (app-owned, and that bucket regenerates from CI).

**The restore took Garage down for an hour.** It filled the 10Gi meta volume (`LMDB: No space left
on device`, 503 on every write, ~08:24–09:27Z). Recovery: `meta-garage-0` expanded 10Gi→30Gi. That
needed `numberOfReplicas` 2→1 (wk-02) and `dataLocality` best-effort→disabled, because the `std`
tier had no disk that could take a grown second replica — hp-01 sits **below** Longhorn's 25%
minimal-available floor, so it rejected *any* expansion at *any* size. The rf=1 debt is FU-137's.

Three lessons, each of which cost something:

- **Restore ORDER sizes the metadata DB.** The carve emits page order, which is random against
  Garage's key space; that fed the B-tree random inserts at ~20.3 KB/object — ~8× the pre-wipe
  store — and filled the volume. Sorted by (bucket, key) it ran ~13 KB/object cumulative. Sorting
  is now `build-work.py`'s default. ⚠ the first ~30k sorted objects showed **zero** growth, which
  is the wipe's free pages being consumed, not steady state — do not size a volume off that window
  (an earlier revision of the code comment did exactly that).
- **☠ Aborting a multipart upload DESTROYS the orphan blocks it read.** A part upload references a
  content-addressed block that had *no rc entry* (invisible to GC); aborting drops it to **rc=0**,
  which is garbage, and the resync worker deletes the file ~10 min later. Two killed runs plus two
  `garage bucket cleanup-incomplete-uploads` calls cost **3,952 of `corpus.sqlite`'s 5,766 blocks**,
  silently and ~10 minutes after the fact — the prescan had reported every block present four hours
  earlier. Failed uploads are now left dangling on purpose and blocks are stat'd before an upload is
  created. Never run `cleanup-incomplete-uploads` against a bucket still being recovered.
- **Longhorn replica churn is charged to the pve thin pool.** Moving/rebuilding the meta replicas
  pushed it 69%→84% with only 1 GiB of VG left to autoextend into — the 08-24 corner again. `fstrim`
  per node returned it to 69.17%; a batch loop over four nodes silently did only part of the job, so
  run it one node at a time and read the byte count.

Damage that survives: `corpus.sqlite` (6.05 GB) is unrecoverable from blocks. It is derived data —
oracle-fleet's delta job reads `parsed/` plus the step manifests, never the corpus file, and the
file also exists as a member inside the intact `corpus-image.oci.tar`.

## Residual

- **FU-093** — pve thin-pool metering (the third sum) + periodic guest fstrim.
- **FU-137** — offsite/backup gap; now carries the #884 restore decision and backup cadence.

## Addendum (2026-08-31): the restore left oracle-specs frozen for a week

The Aug-4 backup restored `oracle-specs` at 1.07 GB — already **over its 1 Gi quota** — so every
PUT after the restore was rejected `403 Bucket size quota is reached` while oracle-fleet's publish
CI stayed green (mc mirror swallows per-object 403s, oracle-fleet#318). The specs web surface
served the exact restore state until the oracle jail noticed on 08-31 (handoff → diagnosed from
garage-0 logs). Fix: quota 1Gi→5Gi in oracle-iac (`allure-workspace.yaml`, PR #446); the general
lesson is that a restore can silently violate ADR-089 quotas-as-contract — the restored size never
got checked against the claims.
