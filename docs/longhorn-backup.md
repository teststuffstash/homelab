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
| the daily job | RecurringJob `daily-backup` (02:00Z, retain 14, concurrency 2) — same dir; a volume joins via labels on its PVC (below) |
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

Read live on 2026-10-03 (43 volumes). The class is per PVC: a **daily** PVC carries
`recurring-job.longhorn.io/source: enabled` + `recurring-job-group.longhorn.io/daily-backup:
enabled`, set where the PVC is declared (`local.longhorn_daily_backup_labels` in `tofu/longhorn.tf`
for the tofu-owned ones, `persistence.labels` in `argocd/platform/forgejo.yaml`). Every other
volume carries no recurring-job label and is backed up by nothing.

| Class | Volumes | Why | Actual size |
|---|---|---|---|
| **daily** | `home-assistant-config`, `unifi-config` (with the UniFi `.unf`, §UniFi), `forgejo/gitea-shared-storage` | irreplaceable state | ≈ 2 G |
| **none — the .unf covers it** | `unifi-mongo` | the settings-only `.unf` on `unifi-config` restores the controller; what Mongo adds is statistics (§UniFi) | — |
| **none — the record is Garage** | `coordinator-transcripts` (×5) | a working mirror: the session exit trap uploads every file to `s3://agent-transcripts` (`agents/coordinator/transcripts-pvc.yaml`) | — |
| **none — CNPG backs itself up** | the CNPG instance volumes (`infisical-pg-*`, `forgejo-pg-*`, `grafana-pg-*`, `oracle-pg-*`) | the Barman Cloud plugin into `cnpg-<ns>` buckets on this same Garage: WAL + daily base backups, consistent, one copy per database instead of two (ADR-147, [`postgres.md`](postgres.md) §Backups). A block backup of these is ~full every day (2 MiB amplification) | — |
| **none — rebuildable** | the registry/pypi/npm/nix/uv caches, `mirror-*`, `arc-uv-cache`, `registry-data` (CI rebuilds it), `devbox-search-data`, eventbus JetStream, `redis` | a cache re-warms. A day of slow builds is the cost, not data loss | — |
| **none — accepted loss** | `prometheus-*`, `data-loki-0`, `alertmanager`, `pushgateway` | telemetry history. Losing it is acceptable | — |
| **none — own replication** | `data-garage-*`, `meta-garage-*` | Garage rf=3 across three zones. 340 G does not fit here, and backing up Garage means bucket-level copies off-site, not block backups | — |

## Restore — the recipe the drill proved

**Drill PASSED 2026-10-03** (FU-299; window `seat-1791016796-9107`). A 1 Gi PVC was filled with
50 MB of random data plus its `sha256sum`, backed up, deleted, restored, and the checksum
re-verified `OK` (verify pod on wk-04). The backup took under a minute and landed 36 objects / 50.1 MB
in the bucket. The drill's residue was deleted afterwards, and the bucket was back to 0 objects.
The steps, as run:

1. **Snapshot**: a `longhorn.io/v1beta2` `Snapshot` named for the drill, with `spec: {volume: <pv
   name>, createSnapshot: true}`. A detached volume works: Longhorn attaches it itself. Wait for
   `status.readyToUse: true`.
2. **Backup**: a `Backup` with `spec.snapshotName` set and the label `backup-volume: <pv name>`.
   Wait for `status.state: Completed`; `status.url` is the restore handle
   (`s3://longhorn-backup@garage/?backup=<name>&volume=<pv name>`). A `BackupVolume` appears.
3. Delete the PVC. The volume goes with it, but the backup stays on the target.
4. **Restore**: a `Volume` with `spec.fromBackup: <status.url>`, `size` in bytes,
   `numberOfReplicas: 2`, **`diskSelector: [std]`**, `frontend: blockdev`, `accessMode: rwo`,
   `dataEngine: v1`. A raw Volume CR does NOT inherit the StorageClass's `std` fence (ADR-089), so
   it must be stated, or the replicas can land on the bulk disks. It is done when
   `status.restoreRequired: false` (state `detached`).
5. **Bind**: a PV with `csi: {driver: driver.longhorn.io, volumeHandle: <volume name>, fsType:
   ext4}` and `storageClassName: longhorn`, plus a PVC that names it via `volumeName`. Mount it and
   compare.

Cleanup: delete the namespace (the PV's `Delete` reclaim takes the volume), then the `Backup` and
the `BackupVolume`. Deleting those also removes the objects from the target.

## UniFi — a settings-only export, not the database

The controller writes a **settings-only autobackup** (`autobackup_<version>_<date>.unf`, ~45 KB,
7 kept) to `/config/data/backup/autobackup/` on `unifi-config` **daily at 01:00Z**; the Longhorn
job at 02:00Z carries it off the cluster. Restore = a fresh controller (empty Mongo) → the setup
wizard's "restore from backup" with that file. Client/traffic history is not kept, by choice.

The schedule is controller state, not code: `unifi.scheduletask` (`action: backup`, `cron_expr`)
is what the scheduler reads at startup — `setting.super_mgmt.autobackup_cron_expr` is only the
UI's copy, and changing it alone does nothing. Settings-only is `super_mgmt.autobackup_days: 0`.
A change takes a controller restart. A restored `.unf` brings the schedule back with it.

**Why the autobackup had never worked (found 2026-10-03).** It was monthly, and its one run in
range (10-01 00:30Z) failed with `MongoSocketReadException`: the backup's read of
`unifi.network_heartbeat` hit a WiredTiger checksum error and panicked `mongod` (`potential
hardware corruption … WT_PANIC`) — the cause of the pod's restarts. Every other collection
validated clean; the corrupt one held a single heartbeat document and was dropped (a Longhorn
snapshot `pre-fu299-unifi-mongo` was taken first). The first daily-schedule `.unf` was written
the same evening.

⚠ **`LonghornBackupStale`'s unit is unverified.** The drill volume was deleted before
`longhorn_volume_last_backup_at` left 0, so the metric never showed a real value. The rule
assumes epoch seconds. Read the metric after the first RecurringJob run, and fix the rule if it is
not seconds.

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

- the off-site second copy
- a belt for a failing or stale UniFi `.unf` (no metric sees the file today)
- a periodic restore drill
