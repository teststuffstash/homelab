# Storage ledger — who owns the sum of the caps

**Tracked by:** FU-093. **Decision:** ADR-089 (storage tiers with quota-as-contract).
**Style sibling:** [`ip-plan.md`](ip-plan.md) — same idea, different resource.

ADR-089 says every claim states its cap. It does **not** say who owns the **sum**. That gap is this
document: without one authority per tier, two honest accountings can both fit their own budget and
jointly blow the tier — which is exactly what happened.

## The one hard rule

> **A tier's committed capacity is the sum of every cap charged against it, across every repo, and
> exactly one ledger owns that sum.** A claim that doesn't appear in the ledger doesn't exist.

## Current shape (2026-08-25)

| tier | zones | raw | allocatable | committed | physically used |
|---|---|---|---|---|---|
| `std` | hp-01 **×2 disks**, thinkcentre, **wk-02** | 581.7G | 501.6G | 305.0G (61%) | 243.3G (42%) |
| `bulk` | wk-metal-01, **wk-metal-04** | 908.1G | 658.1G | 580.0G (88%) | 619.9G (68%) |
| `fast` | thinkcentre Optane ×2 | 26.7G | 26.7G | 5.0G | 1.4G |

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
> extend, four fstrims, ci-runner-01 destroyed → 64 %. Thin volumes now 408 GB on 353 GB. Record:
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
and 08-24 manual trims. **The trim is automated since 2026-08-25** — a daily privileged CronJob
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
So growth means **replacing the 500G NVMe with a larger one**, or freeing the x1 slot by swapping
the GPU for a single-slot card.

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
  A daily CronJob per pool VM (`zone: proxmox`), staggered, privileged, `/var` hostPath'd; the
  runbook recipe made a schedule. It pushes `node_fstrim_bytes_trimmed` / `_success` /
  `_last_run_timestamp` per node, and `NodeFstrimFailed` + `NodeFstrimStale` alert on the belt —
  because the historical failure was not a trim that broke, it was a reclaim path with no owner.
  ⚠ What this does NOT do: watch the pool. There is still no pve exporter, so if the trim keeps up
  nobody learns the pool's level; the alerts prove the mechanism runs, not that it is sufficient.
  ⚠ Nor does it reach **ci-runner-01** — same pool, not a k8s node; it is an ordinary Linux guest
  and its own `fstrim.timer` is the cover. Unverified, and worth a look.
  ⚠ Second layer, not built: a Longhorn `filesystem-trim` RecurringJob. A node-level fstrim cannot
  reclaim space *inside* a replica's sparse file, so volume-level churn needs its own trim before
  the node one can see it.
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
  `scratch: 60Gi` = 20Gi × 3 concurrent rides.

## Consumer

The ledger is not only bookkeeping — it is the **guardrail that defines "mechanical"** for the
infra-fixer lane: a wrapper change is auto-mergeable only if it is schema-valid *and* within the
tier quota ([`agents/iac-lane.md`](agents/iac-lane.md) §rollout matrix). Until the ledger exists,
that predicate is aspirational.

Related: oracle-iac#40 closing comment, oracle-iac#95, TICK-LOG §scratch-pool, FU-116 (the PVC
leak that feeds the Longhorn side).
