# Storage ledger — who owns the sum of the caps

**Tracked by:** FU-093. **Decision:** ADR-089 (storage tiers with quota-as-contract).
**Style sibling:** [`ip-plan.md`](ip-plan.md) — same idea, different resource.

ADR-089 says every claim states its cap. It does **not** say who owns the **sum**. That gap is this
document: without one authority per tier, two honest accountings can both fit their own budget and
jointly blow the tier — which is exactly what happened.

## The one hard rule

> **A tier's committed capacity is the sum of every cap charged against it, across every repo, and
> exactly one ledger owns that sum.** A claim that doesn't appear in the ledger doesn't exist.

## Current shape (2026-09-06; the 2026-08-25 read in parentheses)

| tier | zones | raw | allocatable | committed | physically used |
|---|---|---|---|---|---|
| `std` | hp-01 **×2 disks**, thinkcentre, **wk-02** | 624G | 538G | 385G (71%) *(was 305G, 61%)* | 388G (62%) *(was 243G, 42%)* |
| `bulk` | wk-metal-01, **wk-metal-04** | 975G | 706G | 816G (115%) ⚠ *rebuild-day figure — see below (was 580G, 88%)* | 498G (51%) *(was 620G, 68%)* |
| `fast` | thinkcentre Optane ×2 | 28G | 28G | 5G | 1G |

Read from the Longhorn node CRs (`storageMaximum`/`storageReserved`/`storageScheduled`/
`storageAvailable` summed per tag; allocatable = max − reserved, committed = scheduled). The
**bulk 115 %** is the wk-metal-04 maintenance window's transient: the mirror volumes rebuilt a
second replica onto wk-metal-01 while the node was down and Longhorn is now placing a third on the
returned disk before trimming — re-read after the rebuilds settle. **std grew 80 G committed in 12
days** — 40 G of it is the PyPI cache's 2 × 20Gi (below), the rest platform volumes; `wk-02`'s std
disk is UNSCHEDULABLE for new replicas (47 G free < its 25 % floor of 63 G), so new std placements
have three disks, two of them in the hp-01 zone.

**`fast` eligibility (operator ruling 2026-08-11, FU-159):** SCRATCH for disk-write-heavy pods
(CI builds and the like) — single-node replica-1 Optane of modest speed; NEVER load-bearing
data/metadata (Garage-meta migration onto it was proposed and REJECTED).

Two things to read off it. **`bulk`'s ~88% committed is deliberate, not drift** — the registry
mirrors were oversized on purpose (see homelab#116 below), which spends nominal headroom to buy
the thing that actually matters, and physical sits at 68% (the 2026-08-25 table above). **`std`'s comfort is new**: it had two zones and
hp-01 at 105% until wk-02 moved into it the same day.

**hp-01 was the tight node and no knob fixed it** — 104% of allocatable, 70% physical, 43.3G of
that the container image store on the smallest disk in the tier, and a reservation that did not
even cover its own images, so lowering it would only have moved the lie. This section said the
honest answer was *buy a disk*; **that happened on 2026-08-25**. A second 128G SATA SSD (a Toshiba
HG5d, `hg5d`, tagged `std`) is mounted at `/var/lib/longhorn/hg5d` and adds **119.2G raw / 116.8G
free** to the tier — declared in `machines/machines.yaml`'s `longhorn_disks`, provisioned by Talos
at boot, registered by `scripts/longhorn-tag-disks.sh`. hp-01's original disk stays at 117G with
its image store; the new one carries Longhorn data only, hence `storageReserved: 0`.

Two things that made it more than a bolt-on. The disk arrived with a **bootable Windows install**
(MBR, a flagged 350M "System Reserved" NTFS + 118.9G NTFS), so it needed `talosctl wipe disk` first
— Talos refuses to partition a device that already carries a partition table. And it is now the
*second* 128G SATA SSD in that box, which makes `/dev/sdX` an unsafe way to name either of them:
the entry is pinned to `/dev/disk/by-id/wwn-0x500080db1007e129` precisely because `longhorn_disks`
*partitions* what it points at. `install_disk: /dev/sda` on the same node is the remaining
name-based selector and should follow (FU-076's neighbourhood).

**The hypervisor is still not where a spare SATA SSD goes**, but the reason is cost, not
impossibility (operator, 2026-08-25): pve's board exposes the ports and they are disabled in
firmware, so enabling them is a BIOS session with the whole cluster down. The direction for
ADR-114's remaining capacity is therefore **cheap boxes with their own storage**, not more disks
in pve — see the hypervisor section for what that firmware state actually looks like.

## The double-booking that started this (2026-07-22, closing oracle-iac#40)

Two accountings against the same ~150Gi bulk tier:

| Source | Charged |
|---|---|
| oracle-iac `infra/garage-workspace.yaml` | loki 40 + agent-transcripts 20 + ert-snapshots 90 = **150Gi** |
| oracle-iac#40's own accounting | allure-reports 20 + snapshots + artifact bucket |
| *Neither* | Phase-1 `argo-artifacts` 10Gi, per-repo `argo-artifacts-oracle-fleet` 2Gi (the AgentStack `argo.artifacts` knob, 2026-07-22) |

Live caps to reconcile: `kubectl get workspaces.tf.upbound.io` (8 garage workspaces).

## The other half: nothing meters it

A ledger that isn't measured is a spreadsheet. Four sightings in six days, all the same class —
**a cap breach is invisible until a workload fails**:

1. **2026-07-22** — Garage exports **no** metrics to Prometheus at all (checked: zero `garage_*`
   series). Breaches surface only as faulted writes.
2. **2026-07-25** — Garage LMDB-full at 03:42 surfaced only as a failed sleep-ingester Job (the meta
   volume was 10Gi from then until the 2026-08-25 rebuild grew it to 30Gi, rf=1 on wk-02 —
   FU-137).
3. **2026-07-25** — the **Longhorn** side of the bulk tier: 9 retro rides' 20Gi scratch allocations
   pushed both bulk disks past `storageScheduled` cap → new scratch PVCs faulted
   (`ReplicaSchedulingFailure`) → every ride/worker Init wedged. Immediate mitigations: scan
   janitor grace 2h→30min, launcher-side pod self-clean in the retro orchestrator.
4. **2026-07-27** — homelab#56 (responder-filed): `NodeDiskIOSaturation` on wk-02 sdl, `aqu-sz`
   ~15–17 sustained 2h+, no rebuilds or degraded volumes — plain workload IO grinding a near-full
   bulk disk. The alert was, again, the only visibility.

> **Fourth fill, 2026-09-03** — the pool hit 100 % again, this time pausing cp-01, wk-01 and wk-02 on
> `io-error` (API down ~8 min, no alert); trigger = a 4.9 GiB image pull onto wk-02. Recovery: +1 GB
> extend, four fstrims, ci-runner-01 destroyed → 64 %. Thin volumes 408 GB on the 353.84 GB pool (488 GB again once ci-runner-01 was recreated, 09-04). Record:
> [incident](incidents/2026-09-03-pve-thin-pool-fourth-fill-prepull.md); the meter is FU-093's blocking act.

## The Longhorn side has a SECOND sum — provisioning, not bytes (2026-08-04)

The rule above meters **bytes committed vs bytes available**. Longhorn enforces a different sum
first, and a tier can pass the byte check while failing this one: `storageOverProvisioningPercentage`
bounds what may be *promised* per disk at `(max − reserved) × pct`, regardless of free space.

homelab#94 fired twice on it. At `pct = 100`, with real free space sitting unused:

| std disk | physically free | provisioning headroom |
|---|---|---|
| hp-01 | 25.2G | 7.9G — and under the 25% minimal-available floor → `DiskPressure` |
| thinkcentre | 87.3G | **0.7G** |
| wk-02 | 99.8G | **−0.1G** |

A 2Gi volume could not place **anywhere**, which stalled the platform coordinator. Note the trap:
Longhorn reports `Schedulable=True` on a disk that cannot accept the volume in question — the
status field answers "is this disk usable at all", not "does what I need fit". **Measure
`max − reserved − scheduled`; do not trust `Schedulable`.**

**Raised to 200 (operator, 2026-08-04, `tofu/longhorn.tf`).** It bought immediate headroom and the
volume scheduled. What it did NOT do is create disk — it converts a loud early failure (cannot
schedule, nothing breaks) into a late destructive one (volume fills mid-write, goes read-only).
That trade is only sound with metering, so the **Longhorn per-disk alert below stops being optional
and becomes the prerequisite it was always described as.**

## A THIRD sum: the hypervisor underneath (2026-08-07)

The two sums above both live inside Kubernetes. wk-02's "disk" is an **LVM thin volume on pve**,
and that layer has its own sum that neither the ledger nor Longhorn can see. It was at **99.14%**:

```
data          337.86g  Data% 99.14   ← 2.9G free
vm-8112-disk-0 240.00g  96.95% allocated   (guest was using ~118G)
LVs promised: 448G on a 337.86G pool;  VG free: 16G
```

At 100% a thin pool stops accepting writes and **every VM on it goes read-only together** —
cp-01, wk-01, wk-02 and ci-runner-01, i.e. the control plane and the CI runner. Nothing watched
it: there is no Proxmox exporter, so no alert could have fired, and Longhorn cheerfully reported a
healthy 253G disk sitting on 2.9G of real headroom.

It also only ratchets **up**: `scsi0` had `discard=ignore`, so blocks freed inside the guest were
never returned to the pool. That is why the guest could use 118G while the pool held 232G for it.

**The lesson that generalises:** *"always-on" is not the same property as "durable".* wk-02 was
treated as the reliable half of the bulk tier precisely because it is a VM that never powers off
— while its bytes sat on a single consumer NVMe, shared with three other VMs, on a pool with 2.9G
to spare. The two laptops/desktops it was trusted over are independent physical disks in
independent boxes. That reasoning is what moved Garage's replicas to them (ADR-089 addendum). (The META volume
moved back to a single wk-02 replica on 2026-08-25 to buy restore headroom — FU-137's trailing
⚠; the ADR-114 build-out is what returns its redundancy.)

**RESOLVED 2026-08-07 — and it did not hold.** The pool refilled to 100% by 2026-08-18 and
again 2026-08-24 (the autoextend belt fired at 80% on 08-17 and failed exactly as the caveat
below predicted — 257 VG extents left), froze wk-01 twice, and wiped Garage's metadata:
[incident](incidents/2026-08-24-pve-thin-pool-garage-meta-wipe.md). `discard=on` returns
nothing on its own — Talos guests never fstrim, so freed blocks only came back with the 08-07
and 08-24 manual trims. **The trim is automated since 2026-08-25** — a privileged CronJob (daily; twice daily since 2026-09-04)
per pool VM, `argocd/resources/node-fstrim/`, with the reclaim pushed to the pushgateway and two
alerts on the belt itself (below). It went in at 78.72% and took the pool to **62.99%** on its
first run: wk-02 returned 236 GiB, wk-01 76 GiB, cp-01 and wk-03 36 GiB each. Metering the *pool*
is still open — nothing outside pve can see it.
Pool extended by 15G from VG free, `thin_pool_autoextend_threshold` set
to 80 (LVM warned it was disabled; it is a belt that can only consume free VG extents, not
capacity), then `discard=on` + `ssd=1` on wk-02's scsi0 and a trim:

| | before | after |
|---|---|---|
| pve thin pool `data` | **99.14%** → 94.92% (post-extend) | **47.69%** |
| `vm-8112-disk-0` (wk-02) | 96.95% | **27.51%** |

253 GB returned. Recipe — including the two ways that do NOT work — in
[`runbook.md`](runbook.md) §"Reclaiming thin-pool space from a Talos VM".

⚠ **pve will not take a SATA SSD without a full-cluster outage.** Checked 2026-08-07: of 90 PCI
devices the NVMe is the *only* mass-storage controller — no AHCI enumerated, `ahci` not loaded,
`/sys/class/ata_port/` empty. The ports are physically present and this is a firmware setting, so
it is *possible* — it just costs a BIOS session with every VM on the box down, which is why the
answer to "where does the next disk go" is a new cheap box, not this one (operator, 2026-08-25).
The
board (`INTEL X99-P4`) exposes SATA ports physically but they are disabled in firmware. The x16
slot is permanently occupied: the box **refuses to POST without the GPU** (a GeForce 9600 GT with
`driver=none`, so it idles at full clocks heating the M.2 beneath it — NVMe sensor 1 reads ~69°C).
**Re-read 2026-09-05 (`lspci -tv` + root-port `LnkSta`), then corrected by a physical count
2026-09-08:** `lspci` shows a second x16 CPU root port (`00:02.0`, "Slot 6") and an x4 CPU root
port (`00:01.0`, "Slot 1") as electrically present and empty (plus one chipset x1), the NVMe riding
`00:01.1` — but **the board has ONE physical x16 slot, and the GPU is in it** (operator, counted
2026-09-08). The second x16 root port is CPU silicon the AliExpress board does not break out.
**The x4 slot IS physical — and the dual-slot 9600 GT sits over it**, so it is blocked until the
card is swapped for a single-slot one (a hardware want, private hardware repo R9 — not tracked
here). So growth has three shapes, cheapest first: **(a) a second NVMe on a passive PCIe→M.2
adapter in the x4 slot → new PV, extend the VG/pool** (no migration, no firmware change — a data
disk needs no boot support — gated on the GPU swap freeing the slot, one shutdown for both);
(b) replace the 500 G NVMe with a larger one (a migration); (c) the SATA BIOS session. Wear is not the constraint: the WD Blue SN580 (DRAM-less
consumer TLC) reads 4 % used at 40 TB written over 2,474 power-on hours — ~390 GB/day, roughly
seven years to its 300 TBW rating at that rate.

### History — where the physical bytes were (2026-08-04, post-raise; SUPERSEDED by the table at the top — kept as the pre-fence record)

| tier | physical used | committed | committed as % of physical |
|---|---|---|---|
| `std` (hp-01 + thinkcentre) | 110.5G / 226.6G (49%) | 135.0G | 60% |
| `bulk,std` (wk-02, one disk in both tiers) | 138.0G / 235.9G (58%) | **246.0G** | **104%** |
| `bulk` (wk-metal-01) | 272.0G / 463.4G (59%) | 230.0G | 50% |
| `fast` (Optane ×2) | 9.7G / 26.7G (36%) | 17.0G | 64% |

Two things this says, and they are not the same thing:

1. **The cluster is not out of disk** — every tier is 36–59% physically used.
2. **wk-02 is committed at 104% of its own physical size**, and hp-01 is 78% full with 26G free.
   So the pressure is *distribution*, not total capacity: one disk carries commitments it cannot
   honour if the volumes on it ever fill, while thinkcentre sits at 18% used. Adding disk is not
   the first lever — rebalancing replicas off wk-02, and reclaiming hp-01, are.

The honest summary: raising the percentage removed a scheduling wall that was blocking work, and in
exchange it removed the mechanism that was refusing to let wk-02 get any more overcommitted. That
refusal was doing real work. Metering is what replaces it.

## The tier fence was only ever half-applied (2026-08-07)

ADR-089 calls the `std` fence "load-bearing" because Longhorn schedules onto the emptiest disk and
**empty-selector volumes match any disk**. The fence was implemented as the chart's
`persistence.defaultDiskSelector`, which stamps `diskSelector: ["std"]` onto **newly created**
PVCs only. Every volume that predated it kept an **empty** selector — 14 of them, i.e. essentially
the entire platform: prometheus, loki, garage-meta, home-assistant, both forgejo and both
infisical Postgres volumes, redis, unifi ×2, nix-cache, uv-cache, gitea-shared.

It was not theoretical. `garage/meta-garage-0` had a replica on wk-metal-01 — Garage's *metadata*,
on the wipe-prone laptop the fence exists to keep platform data off. And it was caught live: the
first replica moved during this session rebuilt onto **wk-metal-04**, the emptiest disk in the
cluster, exactly as the ADR predicted an unfenced volume would.

Fixed by stamping `spec.diskSelector: ["std"]` onto all 14 volumes. Longhorn does not relocate
existing replicas on a selector change — it only constrains the next placement — so misplaced
replicas were deleted individually and allowed to rebuild inside the fence.

**Generalisable trap:** a StorageClass parameter is a *creation-time* default, never a retroactive
invariant. Any fence introduced after volumes exist has to be backfilled onto the existing objects,
and "the setting is in the chart" is not evidence that it applies to anything already running.

## Why the registry mirrors are deliberately oversized (homelab#116)

`--delete-untagged` was the bulk tier's largest single consumer of *reclamation*, and it had to go:
in a pull-through cache it deletes exactly the digest-pinned images we pin, leaving a layer link
whose blob is gone, so the mirror serves `200` with **0 bytes** forever. ⚠ A SECOND path to the
same symptom needs no wipe at all: the registry's in-memory blob-descriptor cache serving a GC'd
blob until restart (homelab#240/#241, 2026-08-11) — the valve below does not cover it. Its replacement valve is a
**full store wipe** at 90% (ADR-080 — a pull-through cache is rebuildable by definition, and a wipe
cannot dangle a link).

A wipe is correct but costs a day of slow builds while the cache re-warms, so the design pushes it
toward *never*: **ghcr 40→100Gi** (19.4G actual) and **docker-io 20→40Gi** (2.3G actual) the same
day. That is what spends `bulk`'s nominal headroom down to 90% — a deliberate purchase of
correctness with capacity, affordable only because wk-metal-04 joined the tier. If wipes ever start
happening, `RegistryMirrorWipedRepeatedly` says the fix is a **bigger PVC, never a lower
threshold**.

### The PyPI cache is in the mirror family but not on the mirror tier (2026-09-06)

`pypi-cache` (homelab#1300 → #1404, consumers wired by #1457) is the fourth pull-through cache,
and its **valve is different**: nginx `proxy_cache_path max_size` (16g packages + 1g index) LRU-
evicts inside the volume, so there is no 90 % wipe threshold and no `RegistryMirrorWiped*` alert
to inherit — the bound is the config, on a 20Gi PVC (19.5 G usable, ~2.5 G above the two zones'
combined cap; `proxy_max_temp_file_size 8192m` with `use_temp_path=off` means a burst of large
wheels can transiently exceed `max_size` before the cache manager trims, and ENOSPC there is a
failed download, not data loss). Empty at wiring time (56 K used).

**Tier:** the seat pinned it to the default `longhorn` (std) class on 2026-09-05, following the
nix-cache shape — but ADR-091 put the registry mirrors' cache PVCs on **`longhorn-bulk`**
("re-warmable"), and the ledger's own reading is that `std` is the tight tier. What a warm cache
costs on `std`: up to ~17 G physical on each of its two replica disks, one of which is
`thinkcentre/default-disk` — **49 G free against a 29 G floor, i.e. 20 G of growth headroom for
every std replica on that node**. A full PyPI cache alone nearly spends it, after which thinkcentre
joins wk-02 as unschedulable and new std volumes can only place on hp-01's two disks (one zone).
On `bulk` the same cache is noise (190 G / 288 G free on the two disks; wk-metal-04's 161 G
reservation already protects its image store). The cheapest moment to move it is while it is empty
— a `storageClassName: longhorn-bulk` PVC recreate (the field is immutable) costs nothing today
and a day of re-warm later. Not done in the PR that wired the consumers (#1457 does not touch the
PVC); operator call, since the 09-05 pin was operator-approved. Requirement-register shape:
*want* — "caches on the re-warmable tier", pointer this section.

## Build

- **The ledger itself — BUILT 2026-08-02 (FU-093a)**: `devbox run storage-ledger`
  (`scripts/storage-ledger-check.sh`) sums every `max_size` across the LIVE
  `workspaces.tf.upbound.io` set (cluster-sourced — covers all repos' claims with no cross-repo
  checkout) against the garage data PVC capacity. >80% warns, >100% exits 1 (the iac-lane
  "mechanical" predicate refusal). Per-tier, because per-repo accounting is what allowed the
  double-book. **First run found the tier LIVE-OVERCOMMITTED: 181Gi committed / 150Gi capacity
  (121%)** — biggest lines: ert-snapshots 90, loki 40, agent-transcripts 20. **Reconciled
  2026-08-03** (operator decision: right-size the oversized caps, no PVC grow): loki 40→8Gi
  (698MiB actual at 30-day retention) and agent-transcripts 20→5Gi (448MiB actual) → **134Gi/150
  (89%)**. ert-snapshots keeps 90Gi — its 2×42GB snapshot pairs need ~78GiB, the one cap that was
  honest. The tier sits in the >80% WARN band deliberately: the next claim is a capacity
  decision, not a rubber stamp. **135Gi/150 (90%) since 2026-08-04** — `tofu-state` took 1Gi
  ([`tofu-state.md`](tofu-state.md)); it was sized against the actual 1.4MB main-root state
  precisely because the tier has no room for a round-number guess.
- **Guest fstrim — BUILT 2026-08-25** (`argocd/resources/node-fstrim/`, FU-093's "periodic trim").
  A CronJob per pool VM (`zone: proxmox`; daily, **twice daily since 2026-09-04** — the fourth
  fill happened 19 h after a run), staggered, privileged, `/var` hostPath'd; the
  runbook recipe made a schedule. It pushes `node_fstrim_bytes_trimmed` / `_success` /
  `_last_run_timestamp` per node, and `NodeFstrimFailed` + `NodeFstrimStale` alert on the belt —
  because the historical failure was not a trim that broke, it was a reclaim path with no owner.
  ⚠ What this does NOT do: watch the pool — that is the pool meter below (built 2026-09-04, after
  the fourth fill); these alerts prove the mechanism runs, the meter says whether it suffices.
  ⚠ Nor does it reach **ci-runner-01** — same pool, not a k8s node; it is an ordinary Linux guest
  and its own `fstrim.timer` is the cover. Unverified, and worth a look.
  ⚠ Second layer, not built: a Longhorn `filesystem-trim` RecurringJob. A node-level fstrim cannot
  reclaim space *inside* a replica's sparse file, so volume-level churn needs its own trim before
  the node one can see it.
- **pve thin-pool metering — BUILT 2026-09-04** (FU-093's blocking act after the
  [fourth fill](incidents/2026-09-03-pve-thin-pool-fourth-fill-prepull.md)). Debian's packaged
  node_exporter on the hypervisor plus a one-minute systemd timer feeding its textfile collector
  (`ansible/pve-node-exporter.yml`, idempotent; re-run after a pve reinstall): `lvs` → the pool's
  `data%`/`metadata%`/size, every thin LV's promise + allocation (the overcommit sum, live), `vgs`
  → VG free extents (what autoextend could consume — 28 MB), and `qm status --verbose` → each
  guest's `qmpstatus` (`io-error` = paused on a failed write, the 09-03 signature). Scraped as a
  static LAN target (`argocd/resources/pve-metrics/`, job `pve-node`) with six belts:
  `PveThinPoolFillingUp` (>80 %, warning), `PveThinPoolAlmostFull` (>90 %, critical),
  `PveThinPoolMetadataHigh`, `PveVmIoError` (critical), and the meter's own liveness
  (`PveMetricsStale` on the textfile mtime, `PveMetricsAbsent`) — promtool-fixtured. Chosen over
  an in-cluster Proxmox-API exporter: no credential to mint/store/rotate (the tofu token's role
  cannot create users anyway), and the host's NVMe/memory series come free. The same series gates
  the runner-image pre-puller's pool-VM pulls at 75 % (FU-208). ⚠ Shared fate stands: at 100 %
  Prometheus is down with the pool — the belt is for the approach, so the 80 % warning is the
  load-bearing one.
- **Garage metering — BUILT 2026-08-25/26** (homelab#934 → #965, `3d5fa082`): the chart flags
  flipped (`monitoring.metrics.enabled` + `serviceMonitor.enabled` in
  `argocd/platform/garage.yaml`), so the already-running exporter's 48 families are scraped, and
  `argocd/resources/garage-alerts/prometheusrule.yaml` ships the two belts this section asked
  for — **`GarageDiskFillingUp`** (`garage_local_disk_avail/total < 0.2`, the usage half) and
  **`GarageTableEmpty`** (`table_size == 0` — the direct detector for the
  [2026-08-24 wipe class](incidents/2026-08-24-pve-thin-pool-garage-meta-wipe.md)), plus
  `GarageAdminMetricsAbsent` as the scrape-coverage belt, promtool-fixtured. ⚠ Shared-fate
  caveat stands: on the day, Prometheus was dark while the wipe happened — the belt is for the
  NEXT one. Defect tail riding the loop: #977/#978 (+ their #1015/#1016 sprouts).
- **Longhorn metering — BUILT 2026-08-04** (`02cf8bb`,
  `argocd/resources/longhorn-alerts/prometheusrule.yaml`). Both sums, as specified:
  `LonghornDiskFillingUp`/`LonghornDiskAlmostFull` on physical bytes (85%/93%) and
  `LonghornNodeOverProvisioned` on the provisioning sum (>150%). ⚠ Metric-shape compromise
  recorded there: Longhorn exports `scheduled` only **per node**, not per disk, so the
  provisioning rule is node-scoped — exact for the one-disk nodes, pessimistic for thinkcentre
  (its two Optanes sum in with its std disk).
- **The quota half of ADR-089 — ARMED 2026-08-07, and it had never been armed before.** The XRD
  carried `spec.repos[].storage` from day one, no claim in any stack ever set it, so the
  Composition's `{{- if $r.storage }}` never fired and `kubectl get resourcequota -A` returned
  **nothing, cluster-wide**. The "over-cap PVC fails fast at CREATE with a legible error instead
  of wedging unschedulable" promise was therefore decorative for the whole life of the ADR — and
  the unbounded version is exactly what produced the 2026-07-25 scratch exhaustion in the list
  above. Now set: platform repos in `agents/fixer/openrouter-operator/agentstack.yaml`; the three
  docker-mode repos (`sleep-tracking`, `oracle-fleet`, `circles`) via their own IaC repos, at
  `scratch: 60Gi` = 20Gi × 3 concurrent rides — **raised to 100Gi = 5 rides on 2026-09-04**
  (oracle-iac#563, sleep-iac#85, circles-iac#78; homelab#1321): a Completed ride keeps its 20Gi
  for 30–60 min until the scan janitor's grace (FU-116) releases it, so ×3 was a per-HOUR cap on
  finished rides, not a concurrency cap. Headroom at the raise: 216 + 237 GiB free on the two
  bulk disks, scratch replica-1.

## Requirements — what is NEEDED, not what exists (2026-09-04)

The tables above say what the tiers hold and what is charged against them. Nothing said what the
platform *needs* — the operator asked (2026-09-04), and the answer was "nowhere": ROADMAP carries
one line ("Compute HA — 3-node Proxmox cluster, Ceph") and ADR-114 a direction ("cheap boxes with
their own storage"). This section is that register. One row per requirement, sized where the
evidence allows; **need** = a failure has already happened without it, **want** = it buys a known
improvement. Status lives with the pointer (FU/issue), not here.

**This register is the DEMAND side only.** Which box, from which seller, for how much — and the
inventory of what the fleet already owns down to drive models and health — live in the private
`teststuff/hardware` repo on the homelab Forgejo (created 2026-09-07), which mirrors the rows
below as spec envelopes and answers them from the second-hand market. Nothing there is load-bearing
for this document: keep stating the need and its evidence here, and let the supply side shop.

| requirement | size | why (evidence) | class | pointer |
|---|---|---|---|---|
| **pve thin pool honest** — promised ≤ pool, or the pool grows | today **488 GB promised on a 353.84 GB pool** (`lvs`: <353.84g after the 09-03 +1 GB extend) (wk-02 240, ci-runner-01 80, wk-01 80, cp-01 40, wk-03 40, LXC 8 — 408 only while ci-runner-01 was destroyed, 09-03/04); a second NVMe on pve's free x4/x16 slot extends the pool (cheapest — see §hypervisor), a 1 TB NVMe replaces the 500 GB, or wk-02's 240 GB disk leaves the pool | four 100 % fills in a month, the fourth took the control plane down 8 min; twice-daily fstrim + the meter are belts, not capacity | need | FU-093, ADR-114 (new box, not more disks in pve) |
| **bulk scratch for 5 concurrent docker rides per stack** | 100Gi × 3 stacks = 300Gi worst case, replica-1 on 453 GiB free | 60Gi wedged the fourth dispatch inside an hour (homelab#1321) | need | #1321 (done 2026-09-04) |
| **a third PHYSICAL zone for Garage rf=3** — **MET 2026-09-07** (`m70s`; all six Garage volumes on `longhorn-local-xfs` across wk-metal-01 / wk-metal-04 / m70s, nothing of Garage on the pool) | residual **want**: a *dedicated* data disk in m70s — garage-1 shares the OEM Micron 2300 with Talos + the image store (kubelet imageGC 60/50 is the belt); supply side = the same NVMe lot as the SA400 demote | ADR-114's redundancy story used to end on a VM that pauses when the pool fills; meta rode rf=1 on wk-02 from 08-25 to 09-07 | need → met | FU-137, ADR-114 |
| **Longhorn in-volume reclaim** | ~41 GiB one-off on wk-02 (Prometheus 12, loki 10, garage-meta 8), then the volumes' own churn | node fstrim cannot reach blocks inside replica sparse files; measured 2026-09-04 | want | FU-093 next act (`filesystem-trim` RecurringJob) |
| **registry mirrors never wipe** | grow the PVC (ghcr 100Gi at ~19 G actual) whenever `RegistryMirrorWipedRepeatedly` fires — never lower the threshold | a wipe costs a day of slow builds (homelab#116) | want | §mirrors above |
| **image store off the Longhorn bulk partition on the kata laptops** | a second partition or disk per laptop, or kubelet imageGC below the Longhorn reserve | <25 % free on the shared partition = no scratch PVC = every docker ride wedged (2026-09-01) | want | PR#1193's floor alert is the belt |
| **`fast` big enough to be the scratch tier** (Optane, replica-1) | 26.7 G fits ONE 20Gi ride today; ≥ 60 G (two rides + headroom) would let the platform repos' scratch leave `bulk` — a larger Optane/NVMe in thinkcentre | FU-159 ruling: `fast` = scratch for disk-write-heavy pods, never load-bearing data; unused at 1.4 G because nothing fits | want | FU-159 |

What is NOT a requirement: total bytes. Every tier is 42–68 % physically used; the pressure is
distribution (one thin pool under four VMs, one shared partition per laptop) — the same reading
as the 2026-08-04 history table.

## Consumer

The ledger is not only bookkeeping — it is the **guardrail that defines "mechanical"** for the
infra-fixer lane: a wrapper change is auto-mergeable only if it is schema-valid *and* within the
tier quota ([`agents/iac-lane.md`](agents/iac-lane.md) §rollout matrix). Until the ledger exists,
that predicate is aspirational.

Related: oracle-iac#40 closing comment, oracle-iac#95, TICK-LOG §scratch-pool, FU-116 (the PVC
leak that feeds the Longhorn side).

## 2026-09-05 — where a 9-hour Garage write job spends its time (the ERT parse, FU-137 sighting)

Measured over the job's 8 h window (Prometheus: Garage's `api_s3_*`, Longhorn volume latencies,
node_exporter per-write latency), when the operator asked whether "meta on the wrong node" was
the cause:

| | value |
|---|---|
| PutObject calls / avg server time | 248,482 / 220 ms (85 % of all S3 server time) |
| parse pod CPU | 0.39 cores avg — the job WAITS on Garage |
| `data-garage-0` (Longhorn rf=2: wk-metal-01 + wk-metal-04) write latency | **150 ms** per write |
| wk-metal-04 `sda` physical write latency | **185 ms** at 33 % util (HDD-class; wk-metal-01: 7.5 ms) |
| `meta-garage-0` (rf=1 on wk-02, attached from wk-01) write latency | 2.9 ms, ~1,750 write IOPS |

Reading: rf=2 means every data write waits for the SLOWEST replica, and that is wk-metal-04's
disk — the 150 ms term dominates a PUT; the metadata network hop is ~15–25 % on top (the
`NodeMemoryMajorPagesFaults` on wk-01 during the job is LMDB's mmap faulting over Longhorn).
Levers, in order of win: (1) the APP writes ~250k tiny objects — batching them is hours→minutes
on any layout (oracle-fleet#466 is the resume half); (2) **ADR-114** (Garage rf=3 on node-local
XFS, Garage's own 2-of-3 write quorum) takes the slowest node off the critical path — FU-137's
overdue build-out; (3) pinning `garage-0` to wk-02 with meta `dataLocality: best-effort` removes
only the meta hop (~1–1.5 h of a 9 h job). Not done: an interim rf=1 data volume (reopens the
2026-08-24 class). **Answered the same evening (SMART + sysfs read via an ephemeral privileged pod):** the disk
is a KINGSTON SA400S37480G (SATA SSD, 5 % endurance used, health PASSED, not near-full) on a
**degraded SATA link — negotiated 3.0 Gb/s of 6.0, 1,867 interface CRC errors, 23 PhyRdy→PhyNRdy
transitions / COMRESETs lifetime, one logged `ICRC, ABRT` on a WRITE DMA EXT** (wk-metal-01's
link: 6.0 Gb/s, flat 0.6–18 ms). Latency over 7 d alternates ~1 ms ↔ 50–215 ms in lockstep with
write size (NCQ retries after CRC errors stall the queue on large transfers). Same signature as
the thinkcentre NIC-cable precedent. ~~**Remedy = replace the SATA data cable / reseat**~~ —
**DONE 2026-09-06, and it was NOT the constraint. See §2026-09-06 below before acting on this
paragraph.**
Fleet gotcha recorded: Kingston SA400's vendor attribute 231 `SSD_Life_Left` reads 6 while the
standardized `Percentage Used Endurance Indicator` reads 5 % — trust the standardized field.
Also confirmed: Talos never trims ANY node (the fstrim CronJob is pve-VM-only by design).

## 2026-09-06 — the cable was a fault, not the constraint: the SA400 is the bottleneck

The cable was swapped (operator at the box, 12:40–14:00Z window, `scripts/node-maintenance.sh`).
**Link confirmed healthy: 6.0 Gbps, 0 ATA errors since boot** — the §2026-09-05 diagnosis above was
correct about the fault and wrong about the ceiling.

The Longhorn replica rebuild that followed is a clean benchmark of the drive on a healthy link:

| | value |
|---|---|
| rebuild window (`data-garage-0` replica onto wk-metal-04) | **13:25Z → ~15:35Z ≈ 2 h 10 min** |
| sustained write throughput, whole window | **24–32 MB/s, flat** (node_exporter `sda`) |
| write latency / util at the time | **486 ms / 76 %** (source disk 7 ms, NIC 22 %) |
| link it had | 6.0 Gbps = 600 MB/s |

**The arithmetic that settles it:** the drive delivers **under 5 % of its healthy link** — and under
10 % of the *degraded* 3.0 Gbps one. A cable was never capable of being the limit. The flat ceiling
across 2 h is the signature of a **DRAM-less** SSD past its SLC cache: no room to hold the FTL
mapping table, so sustained small random writes — Garage's exact shape — collapse.

The fleet's own controlled A/B, same rebuild traffic, same cluster:

| node | drive | cache | sustained write |
|---|---|---|---|
| wk-metal-01 | Crucial MX500 | DRAM | flat **0.6–18 ms** |
| wk-metal-04 | Kingston SA400 | **DRAM-less** | **486 ms @ 26 MB/s** |

**Remedy = replace the DRIVE with a DRAM-equipped one** (the MX500 in wk-metal-01 is the known-good
reference in this fleet). Not the cable, not TRIM alone. ⚠ **Buying criterion for any Garage/Longhorn
data disk from here: DRAM cache, not €/GB** — the cheap DRAM-less tier reproduces this fault exactly.
Interim levers, unchanged: FU-137 rf=3 (2-of-3 quorum takes the slowest node off the write path —
mitigates, does not fix this node) and the never-run TRIM (FU-093 (b)).

Operator reports this as a repeat — hours-long rebuilds on this drive have happened before (the
earlier occurrence is not recorded here; this entry is the first with numbers). Cost is not theoretical — [oracle-fleet#467](https://github.com/teststuffstash/oracle-fleet/issues/467)
measures 248k PUTs × 220 ms ≈ 5.8 h of a single ERT parse run waiting on this path.

## 2026-09-07 — what the Longhorn engine actually costs, and why placement stops being an ADR

**Operator ruling, same day: storage PLACEMENT is not ADR material any more — it lives here.**
ADR-114 decreed one answer for the whole platform ("node-local XFS — Longhorn drops out of the
Garage data path entirely"). That does not survive contact with a fleet that is about to get ~10
more disks: the right backing for a workload is a *measured, per-workload* choice, and the mix will
be genuinely messy (some raw, some Longhorn, decided after profiling). ADRs record forks with
alternatives rejected; this is a rolling measurement register, and it belongs in the ledger. **The
ADR-114 amendment is exactly that: placement moves here.** Nothing supersedes ADR-114's *other*
half — rf=3 across physical zones, engines replicate and storage stores singles — which stands.

**And ADR-114's stated reason was half wrong.** It bundled two claims: *"engines replicate; storage
stores singles"* (true, and satisfied by a **replica-1** Longhorn volume — this cluster already runs
`longhorn-fast`, `longhorn-scratch` and `longhorn-single` at `numberOfReplicas: 1`) and *"not
Longhorn; ext4 inode limits bite"* (an argument against **ext4**, not against Longhorn — a
StorageClass takes `fsType: xfs`; every class here is ext4 **by configuration, not by constraint**).
Only the first claim was ever load-bearing.

### The measurement (m70s, 2026-09-07, N=2)

Same node, same physical Micron 2300, two partitions of it: **A** = raw node-local XFS
(`/var/mnt/garage`, the Talos user volume), **B** = a Longhorn volume, `numberOfReplicas: 1`,
`fsType: xfs`, replica fenced onto m70s by a throwaway `abtest` disk tag. `fio` in a pod pinned to
the node; the rig was torn down after (disk removed, `spec.disks={}`).

| job | metric | A raw XFS | B Longhorn r1 |
|---|---|---|---|
| 4k randwrite, depth 1, **fsync every write** | IOPS | 968 · 970 | 1840 · 1853 |
| | fsync p50 / p99 | 954 / 1761 µs | 514 / 1036 µs |
| 4k randwrite, O_DIRECT, depth 32 | IOPS | 154 985 · 154 584 | 15 026 · 12 855 |
| | bandwidth | 605 · 604 MiB/s | **58.7 · 50.2 MiB/s** |
| | clat p50 / p99 | 152 / 913 µs | 2007 / 4177 µs |
| 1M seq write, O_DIRECT, depth 4 | bandwidth | 2753 · 2622 MiB/s | **354 · 342 MiB/s** |
| | clat p50 | 1286 µs | 10 813 · 11 206 µs |

**The engine costs ~10× on concurrent small writes, ~7.7× on streaming, and 8–14× on latency.** It
also adds variance: the raw arm repeats to within 0.3 %, the Longhorn arm spreads 14 % on IOPS and
86 % on p99.

**But it is not the binding constraint for Garage.** Longhorn replica-1's floor here is 50–59 MiB/s
small-object and 342–354 MiB/s streaming, against a workload measured at ~150–220 ms per PUT
(§2026-09-05) and a LAN registry push that managed 3.4 MB/s end to end. The tax is one to two orders
of magnitude above what this workload pulls, which is why the operator took Longhorn on
maintainability grounds and the numbers agree rather than decide.

⚠ **One number that must not be quoted as a win: Longhorn is NOT 1.9× faster at durable writes.**
Same physical device — a flushed write cannot be twice as fast through an extra layer. The plausible
reading is that the engine acknowledges the flush without pushing it to the device the way raw XFS
does. That is load-bearing here, because ADR-114 set `metadata_fsync = true` precisely because
LMDB's default `MDB_NOSYNC` was the mechanism of the 2026-08-24 wipe. **Whether Longhorn honours
fsync end-to-end must be settled before `metadata_fsync = true` on a Longhorn-backed meta volume is
trusted to mean what it says** — FU-223.

**Caveats, so the ratios are not over-read:** 2 GB working set over 45 s, so the A arm's 2.7 GB/s and
155k IOPS are SLC-cache burst, not sustained — the ratios are the finding, the absolute A figures are
optimistic. Replica-1 on one node means no cross-node traffic, so this is the **floor** of engine
overhead, not what replica-2 costs.

### Consequence for the single-disk nodes

A one-disk box has nowhere to put a *dedicated* Longhorn disk: `machine.disks` partitions a whole
device, and a Talos **user volume mounts at `/var/mnt/<name>`, which longhorn-manager cannot see**
(it host-mounts only `/var/lib/longhorn`). So Longhorn's disk there is the default one, on the Talos
EPHEMERAL partition — **shared with the containerd image store**, which is precisely the collision
that wedged every `docker:true` worker on 2026-09-01 (§the ADR-089 addendum). The existing mitigation
— kubelet `imageGCHighThresholdPercent: 60` / `Low: 50` in `tofu/metal.tf` — is currently gated on
`kata`, so a non-kata storage node does not get it. Any single-disk node that becomes a Longhorn
storage node needs that gate widened.

### The rf=3 build-out as run (2026-09-07 evening) — what a resync costs, and from where

The FU-137 question was "what does a full-table resync cost?", because the rotation loop's cadence
hangs on it. The answer has two halves and the first is a warning: **it depends on where the source
node's metadata lives, by two orders of magnitude.**

| leg | mechanism | source | measured |
|---|---|---|---|
| downtime of the rf 1→3 flip | delete `cluster_layout` → orphan-delete STS → pod → 3 pods → `layout apply` | — | **2 min 34 s** (20:32:42 → 20:35:16Z) |
| table sync, Garage-native | `repair tables`, Merkle walk on garage-0 | garage-0's 26 GB leaked LMDB, **network-attached** (pod wk-metal-04, replica wk-02) | **~3,000 items/min** → 35 h for 3.2M items × 2 peers |
| block push, Garage-native | `repair blocks` on garage-0, 8 workers, tranquility 0 | same node | **0.5–12 blocks/s** (workers Busy on page faults, not on I/O) |
| metadata seed | compacted snapshot streamed pod-to-pod (`nc`) | 4.1 GB finished snapshot | **38 s** (~108 MB/s); delta sync after: seconds |
| block seed (first peer) | `tar \| nc` of the data dir into the running pod's volume | ro same-node mount of `data-garage-0` on wk-metal-04 (SA400) | **68 GB / 558k files in 37 min ≈ 31 MB/s** |
| resync drain on a seeded node | `repair blocks` verifying present files | local XFS | **~255 blocks/s** |
| **block resync, Garage-native, from a HEALTHY peer** | garage-2's `repair blocks` fetching from garage-1 (seeded, local meta + data) | garage-1 on m70s (NVMe) → wk-metal-01 (MX500), 8 workers, tranquility 0 | **~155 blocks/s ≈ 19 MB/s** — the FU-137 number |
| **rotation of a zone, Garage-native (step 8)** | new garage-0 (`repair tables` + `repair blocks`) from two healthy peers, local volumes | onto wk-metal-04's **SA400** (the known write bottleneck), tables and blocks sharing the disk | tables **~27k items/min** (435k in 16 min → ~2 h for 3.2M); blocks **~14/s ≈ 1.7 MB/s** → ~11 h — left running at wind-down |

**Reading:** the Garage-native resync is not slow — a node whose LMDB page faults across the network
is. Every refcount lookup and Merkle descent on garage-0 was a scattered 4 KiB read on a volume
whose replica sat on another box, the exact pathology §Durability already recorded for the forensic
rebuild (~0.3 MB/s scattered vs ~100 MB/s sequential). `resync-worker-count` did not help because
eight workers page-faulting are still page-faulting. So the number the rotation loop needs is the
LAST row: once ONE peer was seeded (local meta, local blocks), the second new node synced from it
natively at ~155 blocks/s — 559k blocks in ~1 h, no helpers — and the step-8 rotation of garage-0 is
the third data point — same shape on the table side (~27k items/min from healthy peers), but the
block side landed at 14/s on the SA400 zone against 155/s on the MX500 zone: the rotation cadence is
set by the slowest zone's disk, and that disk is the one already on the buy list. The block seed was needed exactly once, to break the
network-attached-source pathology; after that the supported path is fast enough on its own.

Also observed while measuring (operator, Grafana "top pods by CPU throttling ratio"): `longhorn-manager`
pods throttle 4–14 % of CFS periods at their 150m req==limit, cilium agents 4–13 %. `instance-manager`
— the I/O path — has no CPU limit, so §The measurement above is not a throttling artefact; the manager
is the attach/rebuild plane and that is FU-224.
