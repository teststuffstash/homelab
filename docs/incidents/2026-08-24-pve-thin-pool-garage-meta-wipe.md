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

## Residual

- **FU-093** — pve thin-pool metering (the third sum) + periodic guest fstrim.
- **FU-137** — offsite/backup gap; now carries the #884 restore decision and backup cadence.
