# Storage ledger — who owns the sum of the caps

**Tracked by:** FU-093. **Decision:** ADR-089 (storage tiers with quota-as-contract).
**Style sibling:** [`ip-plan.md`](ip-plan.md) — same idea, different resource.

ADR-089 says every claim states its cap. It does **not** say who owns the **sum**. That gap is this
document: without one authority per tier, two honest accountings can both fit their own budget and
jointly blow the tier — which is exactly what happened.

## The one hard rule

> **A tier's committed capacity is the sum of every cap charged against it, across every repo, and
> exactly one ledger owns that sum.** A claim that doesn't appear in the ledger doesn't exist.

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
2. **2026-07-25** — Garage LMDB-full at 03:42 surfaced only as a failed sleep-ingester Job (meta
   volume has been 10Gi since).
3. **2026-07-25** — the **Longhorn** side of the bulk tier: 9 retro rides' 20Gi scratch allocations
   pushed both bulk disks past `storageScheduled` cap → new scratch PVCs faulted
   (`ReplicaSchedulingFailure`) → every ride/worker Init wedged. Immediate mitigations: scan
   janitor grace 2h→30min, launcher-side pod self-clean in the retro orchestrator.
4. **2026-07-27** — homelab#56 (responder-filed): `NodeDiskIOSaturation` on wk-02 sdl, `aqu-sz`
   ~15–17 sustained 2h+, no rebuilds or degraded volumes — plain workload IO grinding a near-full
   bulk disk. The alert was, again, the only visibility.

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

### Where the physical bytes actually are (measured 2026-08-04, post-raise)

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
- **Garage metering** — enable the admin-API metrics (`:3903`) + a ServiceMonitor; per-bucket
  usage-vs-cap panels; a **>80% alert**.
- **Longhorn metering — now the PREREQUISITE, not a nice-to-have** (see the over-provisioning
  section above; raising the percentage to 200 removed the scheduler's own refusal). Two alerts,
  not one: per-disk `storageScheduled` vs `(max − reserved) × pct` (the provisioning sum, the one
  homelab#94 hit twice) **and** per-disk physical used vs max (the byte sum, which now has nothing
  bounding it). The kubelet metrics already exist (`longhorn_disk_*`).

## Consumer

The ledger is not only bookkeeping — it is the **guardrail that defines "mechanical"** for the
infra-fixer lane: a wrapper change is auto-mergeable only if it is schema-valid *and* within the
tier quota ([`agents/iac-lane.md`](agents/iac-lane.md) §rollout matrix). Until the ledger exists,
that predicate is aspirational.

Related: oracle-iac#40 closing comment, oracle-iac#95, TICK-LOG §scratch-pool, FU-116 (the PVC
leak that feeds the Longhorn side).
