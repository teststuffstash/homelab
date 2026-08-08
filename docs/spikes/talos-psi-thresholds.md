# Spike — Talos 1.13 OOMController/PSI: what is tunable, and why the kills come in bursts

**Tracked by:** FU-155 (research half dispatched as homelab#157). **Status:** researched, **no
decision** — the tune-vs-accept call is the operator's (⚖ below). **Nothing was applied**; this
document is findings only.
**Environment:** Talos **v1.13.2** (pinned, `tofu/variables.tf:57`) / Kubernetes v1.36.1; the
ephemeral/kata tier (`wk-metal-01/02/03` 8GB, `wk-metal-04` 16GB), hardened 2026-07-28 by the
FU-112(b) kubelet reservations (`tofu/metal.tf:116-141`).
**Symptom being explained:** one PSI fire SIGKILLs 4–5 unrelated pods within a second, repeating
several times an afternoon on `wk-metal-03` (homelab#63/#65/#100/#101; incident
`docs/incidents/2026-07-27-kata-ride-oom-cascade.md`).

**Sources.** Everything below is read from `siderolabs/talos` **at tag `v1.13.2`** unless a
different tag is named; paths are repo-relative to that checkout, fetched via
`raw.githubusercontent.com`. Cluster reads were **RBAC-denied** for this ride (see §6), so live
state is taken from this repo's authoritative-as-code patches.

## 1. What Talos v1.13.2 actually exposes

### 1.1 The mechanism

`OOMController` (`internal/app/machined/pkg/controllers/runtime/oom.go`) is a **userspace**
OOM killer, added 2025-09-01 and independent of the kernel's own OOM killer and of kubelet
eviction. It runs on a ticker — `defaultSampleInterval = 500 * time.Millisecond` (same file) — and
on each tick:

1. **Reads PSI from cgroupfs, not `/proc/pressure/memory`.** `oom.PopulatePsiToCtx()`
   (`internal/app/machined/pkg/controllers/runtime/internal/oom/oom.go`) reads the
   **`memory.pressure`** file of seven cgroups under `/sys/fs/cgroup` (`constants.CgroupMountPath`):
   the root (`""`), `init`, `system`, `podruntime`, `kubepods/besteffort`, `kubepods/burstable`,
   `kubepods/guaranteed`. For each it extracts `some`/`full` × `avg10`/`avg60`/`avg300`/`total`,
   plus a **rate of change** (`d_…`) computed as `(value - previous) / sampleInterval_seconds`.
   Root-cgroup values land as `memory_full_avg10` etc.; the rest are summed into per-QoS-class maps
   (`qos_memory_full_avg10[System]`, …). `total` is the kernel's stall counter in **microseconds**,
   so a `d_…_total` is *µs of stall per second*.
2. **Evaluates a CEL boolean trigger** over that context (`oom.EvaluateTrigger`).
3. **If it fires:** ranks candidate cgroups with a second CEL expression, picks the single highest
   score, and kills **that whole cgroup** — `reapCg()` opens a pidfd per PID, writes `1` to the
   cgroup's `cgroup.kill`, then calls `process_mrelease(2)` on each. One trigger = **one cgroup**,
   killed atomically, no SIGTERM, no grace period.
4. **Records the kill** as an `OOMActions.talos.dev` resource
   (`pkg/machinery/resources/runtime/oom_action.go`): `triggerContext` (the whole evaluation
   context, as JSON), `score`, `processes` (victim cmdlines). Last **50** are kept
   (`constants.OOMActionLogKeep`). Marked `Sensitivity: Sensitive` → needs an `os:admin` talosconfig.

### 1.2 The two thresholds that are actually shipped

`pkg/machinery/constants/constants.go:1311-1319` (v1.13.2):

```cel
// DefaultOOMTriggerExpression
(multiply_qos_vectors(d_qos_memory_full_total, {System: 8.0, Podruntime: 4.0}) > 3000.0 &&
 multiply_qos_vectors(qos_memory_full_avg10,  {System: 1.0, Podruntime: 1.0}) > 5.0) ||
(memory_full_avg10 > 75.0 && time_since_trigger > duration("10s"))

// DefaultOOMCgroupRankingExpression
memory_max.hasValue() ? 0.0 :
  {Besteffort: 1.0, Burstable: 0.5, Guaranteed: 0.0, Podruntime: 0.0, System: 0.0}[class] *
    double(memory_current.orValue(0u))
```

Read it carefully — three properties matter here:

- **Branch A has no rate limit.** The `System`/`Podruntime` branch carries **no
  `time_since_trigger` term** in v1.13.2, so while Talos's own services + the CRI/kubelet are
  stalling it can fire on **every 500 ms tick**. Only branch B (root cgroup `full` stall > 75%) is
  debounced, at 10 s. **This is the burst signature**: 4–5 pods gone "in a second" is 4–5
  consecutive branch-A fires, one victim each, ~500 ms apart.
- **The trigger keys on the PLATFORM's stall, not the workload's.** Branch A ignores
  `kubepods/*` entirely (weights are `System: 8.0`, `Podruntime: 4.0`). It says "Talos services and
  the container runtime are stalling ≥5% avg10 and stall is accumulating" — then it kills a
  *workload* cgroup to relieve that.
- **Anything with a memory limit scores 0.0.** `memory_max.hasValue() ? 0.0 : …` — a pod cgroup
  with `memory.max` set (i.e. **any pod whose containers all carry a memory limit**) is scored
  zero. Guaranteed additionally weighs `0.0`. So the ranking deliberately prefers
  **unlimited BestEffort** (weight 1.0 × current usage) then **unlimited Burstable** (0.5 ×).

### 1.3 What gets ranked (and what silently doesn't)

`oom.RankCgroups()` enumerates the **immediate child directories** of exactly five paths:
`kubepods/besteffort`, `kubepods/burstable`, `kubepods/guaranteed`, `/podruntime`
(`constants.CgroupPodRuntimeRoot`), `/system` (`constants.CgroupSystem`). Victim classes are
ordered `Besteffort < Burstable < Guaranteed < Podruntime < System`
(`pkg/machinery/resources/runtime/oom.go`, "higher value = more important").

⚠ **Unverified-on-node, and it changes the whole picture (see §6 for the check):** with the
cgroupfs driver the kubelet places **Guaranteed** pods at `kubepods/pod<uid>` — *not* under a
`kubepods/guaranteed/` directory. If that is what the kata nodes look like, `RankCgroups` never
enumerates a Guaranteed pod at all, and the `Guaranteed: 0.0` weight is moot because those pods are
not candidates in the first place.

### 1.4 The victim-selection bug in v1.13.2

```go
maxScore := math.Inf(-1)
for cgroup, score := range ranking { if score > maxScore { maxScore, cgroupToKill = score, cgroup } }
```

(`oom.go`, `OomAction`). There is **no `score > 0` floor**, and Go randomises map iteration order.
So when every ranked cgroup scores **0.0** — every candidate has a memory limit — the controller
kills an **arbitrary** one and reports `score: 0`. Fixed upstream in v1.13.8 by
`oom.SelectVictim()`, which requires `score > 0` and otherwise logs *"no eligible cgroup to kill"*.

### 1.5 Every knob, and where it lives

| Knob | Where | Live-appliable? |
|---|---|---|
| `triggerExpression` | `OOMConfig` doc (`apiVersion: v1alpha1`, `kind: OOMConfig`), `pkg/machinery/config/types/runtime/oom.go`; reference `website/content/v1.13/reference/configuration/runtime/oomconfig.md` | yes — the controller re-reads on config change |
| `cgroupRankingExpression` | same doc | yes |
| `sampleInterval` | same doc (default 500 ms) | yes — `ticker.Reset()` |
| `strictCgroupClassOrdering` | same doc, **v1.13.8+ only** (absent in v1.13.2) | yes |
| kubelet `systemReserved`/`kubeReserved`/`evictionHard` | `machine.kubelet.extraConfig` — already set for the kata tier, `tofu/metal.tf:116-141` | yes |
| swap device | `SwapVolumeConfig` doc (`website/content/v1.13/reference/configuration/block/swapvolumeconfig.md`) | provisions a partition |
| zswap | `ZswapConfig` doc (`maxPoolPercent`, `shrinkerEnabled`) | yes, but see §4 |
| kubelet `failSwapOn` | Talos already defaults it to **false** (`internal/app/machined/pkg/controllers/k8s/kubelet_spec.go:365`) | n/a |

There is **no** knob for "kill fewer pods per fire", "cool-down", or "protect namespace X" other
than by writing it into the two CEL expressions.

⚠ **Trap in v1.13.2 — set BOTH expressions or neither.** `OOMV1Alpha1.TriggerExpression()`
(`pkg/machinery/config/types/runtime/oom.go`) tests **`s.OOMCgroupRankingExpression.IsZero()`**, not
its own field. An `OOMConfig` that sets only `triggerExpression` therefore returns `None` and the
custom trigger is **silently ignored** — a tuning change that appears applied and does nothing.
Fixed in v1.13.8 (each getter falls back to `config.DefaultOOMConfig{}`).

## 2. Why this produces *shared-fate* kills on our kata tier

Composing §1 with what this repo declares for those nodes:

| Pod on a kata node | QoS / `memory.max` | Rank score under the default expression |
|---|---|---|
| the agent ride + dind (`agents/agent-session.sh:944-1001`, requests **=** limits) | Guaranteed, limit set | **0.0** (and likely not even enumerated, §1.3) |
| `cilium-agent` (`tofu/cilium.tf:88`, 512Mi req=limit) | Guaranteed, limit set | **0.0** |
| `longhorn-manager` / `longhorn-driver` (`tofu/longhorn.tf:161-162`) | Guaranteed, limit set | **0.0** |
| `cilium-envoy` (`tofu/cilium.tf:79`, requests only) | **Burstable, no limit** | 0.5 × ~20Mi |
| `hubble-relay` (`tofu/cilium.tf:75`), `node-exporter` (`kube-prometheus-stack.yaml:345`) | **Burstable, no limit** | 0.5 × ~30Mi |
| `longhorn` `instance-manager` / `engine-image` — Longhorn-managed, the chart's resource keys don't reach them (`tofu/longhorn.tf:155-160`) | **BestEffort, no limit** | 1.0 × current — the **top-ranked victim on any node they run on** |

So on the hardened tier the **only** selectable victims are small, limit-less platform daemons —
tens of MiB each. The ~5Gi kata ride that *causes* the stall is structurally unselectable. Each
fire frees ~20–30Mi, memory pressure does not drop, and branch A (no debounce) fires again on the
next 500 ms tick, walking down the list of small daemons. **That is the shared-fate signature**: it
is not one event killing five pods, it is five events in 2.5 s, each killing the wrong thing.

If instead *every* candidate carries a limit, §1.4 applies and the victim is **random** with
`score: 0` — same burst, arbitrary targets.

**Our own fleet already recorded exactly this.** The FU-139 archive entry (2026-08-05) quotes a
real `OOMAction` from wk-02, 2026-08-04 18:34:28: it fired at **`memory_full_avg10: 6.04`** with
~9.3G of 12G in use — i.e. nowhere near branch B's 75%, so that was **branch A**, on a node that
was not short of memory — and it "scored the **Longhorn** cgroup highest, the worst victim on a
storage VM". That is §1.2 and §1.3 confirmed on our hardware: the ranker picked the biggest
*limit-less* cgroup (Longhorn's BestEffort instance-manager), not the memory consumer.

Two corollaries worth stating plainly:

- **FU-112(b) worked as designed and made this worse.** Giving the platform daemons
  `requests == limits` moved them out of the *kernel's* victim list (`oom_score_adj -997`) — which
  was the goal — but under Talos's *userspace* ranker a limit means score 0.0, so the hardening
  moved the target onto whichever daemons were left un-limited. "Reservations don't tune PSI"
  (FU-139) is true and understates it: the ranker doesn't look at reservations *or* at who is
  consuming the memory, only at `memory.max` presence, class weight, and `memory.current`.
- **The kubelet's `evictionHard: memory.available=512Mi` cannot win this race.** Kubelet eviction
  polls on `housekeeping` (10 s order) and then evicts gracefully; the OOMController samples at
  500 ms and SIGKILLs a cgroup. On a fast allocator (a kata VM ballooning toward its limit) Talos
  gets there first.

## 3. Per-node tunability — yes, cleanly

`OOMConfig` is a **machine-config document**, and `data "talos_machine_configuration" "metal"` is
`for_each`-ed over `var.metal_nodes` (`tofu/metal.tf:74-79`), with `config_patches` already
composed per node (that is how `homelab.io/kata`, the kubelet reservations and the `HostnameConfig`
doc are applied to *only* some nodes). A patch gated on `each.value.kata` — or on an explicit node
list — therefore reaches the ephemeral tier and **cannot** touch `cp-01`/`wk-01`/`wk-02`/
`thinkcentre`/`hp-01`, which are configured through separate roots/patch sets.

Shape (illustrative — **not applied by this PR**, and note the both-fields rule from §1.5):

```hcl
each.value.kata ? [yamlencode({
  apiVersion              = "v1alpha1"
  kind                    = "OOMConfig"
  triggerExpression       = <<-EOT
    (multiply_qos_vectors(d_qos_memory_full_total, {System: 8.0, Podruntime: 4.0}) > 3000.0 &&
     multiply_qos_vectors(qos_memory_full_avg10,  {System: 1.0, Podruntime: 1.0}) > 5.0 &&
     time_since_trigger > duration("5s")) ||
    (memory_full_avg10 > 75.0 && time_since_trigger > duration("10s"))
  EOT
  cgroupRankingExpression = "…"   # MUST be set, else the trigger above is ignored (§1.5)
})] : []
```

It is a plain config apply (no reboot, no reinstall): the controller holds `MachineConfig` as a
weak input and re-reads on change (`oom.go`, `getConfig`). This is **unlike** `install.image` /
`HostnameConfig`, which are install-time only — so this class of change does not carry the
ghost-a-running-node hazard called out in `tofu/metal.tf` and `docs/runbook.md`.

## 4. Options

Blast radius is stated for the **ephemeral/kata tier only** in every row; none of these need to
touch the service tier.

| # | Option | Concrete change | Blast radius | Evidence that would validate it |
|---|---|---|---|---|
| **A** | **Upgrade the ephemeral tier to Talos ≥ v1.13.6** | `var.talos_version` (or a tier-local pin) → `v1.13.8`; metal nodes upgrade via `talosctl upgrade` — safe on metal, **never** on the nocloud VMs (`docs/runbook.md:173`) | Node reboots, one at a time. v1.13.6 adds `time_since_trigger > duration("5s")` to branch A; v1.13.8 adds `SelectVictim` (`score > 0` floor, no more random zero-score victim) + `strictCgroupClassOrdering`. Kubernetes stays 1.36.1. **Not** the 1.14 jump FU-033 gates | `talosctl -n <ip> get oomactions` shows fires ≥5 s apart and never `score: 0`; PodSigkilled bursts collapse from 4–5 to ≤1 per event |
| **B** | **Tune the CEL expressions per node** (§3) | Backport the 5 s debounce into `triggerExpression`; optionally a ranking expression that can select the hog (e.g. drop the `memory_max.hasValue() → 0.0` short-circuit and rank on `memory_current` within `kubepods/*`) | Config-only, live, reversible, tier-scoped. **Risk:** hand-written CEL that Talos will *silently ignore* if only one field is set (§1.5); and a ranking change that makes the ride selectable means the ride gets SIGKILLed with no grace — an agent round dies hard instead of a daemon | Same `oomactions` check; plus a deliberately hostile ride (the 07-28 meta-15 recipe in the incident doc) where the *victim is the ride*, `cilium`/`longhorn` untouched, node survives |
| **C** | **Swap and/or zswap** | `SwapVolumeConfig` (partition on the install SSD) ± `ZswapConfig{maxPoolPercent, shrinkerEnabled}` | ⚠ **zswap alone does nothing** — it is a compressed cache *in front of* a swap device; no swap volume, no effect. And Kubernetes `LimitedSwap` is **Burstable-only**, so our Guaranteed rides can never use it. What swap *would* buy is headroom for the **`System`/`podruntime` cgroups** — which is exactly what branch A keys on. Costs SSD write endurance on 128–500GB consumer SATA disks; swapping a kata microVM's RSS is latency-catastrophic if it ever happens | `node_pressure_memory_*` (node-exporter) for the System side falling below the 5% avg10 bar during a ride; `oomactions` empty across a full ride |
| **D** | **Tighten the rides / stop overcommitting the node** | Lower `AGENT_LIMITS`/dind (`agents/agent-session.sh:944-1001`), or enforce one ride per 8GB node and send docker rides to the 16GB `wk-metal-04` | Fewer/slower concurrent rides; no platform change; addresses the *cause* (the node is genuinely at its limit) rather than the killer's behaviour | A ride that never drives System-cgroup `full` avg10 over 5% — visible in node-exporter PSI without any Talos change |
| **E** | **Accept + teach the responder the signature** | Leave Talos alone; aggregate N PodSigkilled within one window into a single issue and name the mechanism in the `PodSigkilled` description (`argocd/platform/values/kube-prometheus-stack.yaml:130-137` already documents the two-causes split) | No infra risk. Kills keep happening: `cilium-envoy`/`hubble-relay`/`node-exporter` restart, which is survivable, but it is *chance* that the un-limited pods on that tier are all restartable | One issue per burst instead of 4–5; comment-rate audit (FU-155) stops needing hand-reconstruction |

Note that **B, C, D and E are all reachable after A**, and A changes the numbers every one of them
would be tuned against. A is also the only option that fixes §1.4 (the random zero-score victim),
which no CEL expression can work around.

## 5. ⚖ Recommendation — the operator rules

**Do A first, alone, on the ephemeral tier: pin those nodes to Talos v1.13.8 and re-measure.**

Reasoning: the burst behaviour we are paying for is a **known upstream defect that upstream already
fixed on our own minor line** — the missing debounce (v1.13.6) and the missing `score > 0` floor
(v1.13.8). Hand-writing a CEL expression to reproduce a fix that ships in a patch release is
strictly worse: more surface, a silent-ignore trap (§1.5), and a divergence we would carry forever.
The upgrade is also the cheapest thing to *undo* and the only option whose correctness we do not
have to argue about.

Then re-measure before choosing among B/C/D/E, because A alone probably does **not** stop the kills
— it makes them **one per ≥5 s instead of a burst**, still aimed at the un-limited daemons. My
expectation is that the residual then wants **D** (the 8GB nodes are genuinely too small for a
~5.1Gi ride plus platform, and `wk-metal-04` exists precisely for this) with **E** as the always-on
hygiene, and **B** held in reserve for a ranking expression only if we decide the ride *should* be
the victim. **C is the one I would not do**: zswap without a swap volume is a no-op, swap is
Burstable-only for workloads, and it trades a fast honest failure for slow disk-thrashing on
consumer SSDs.

Two things that are cheap and orthogonal to the decision, if the operator wants them anyway: give
`cilium-envoy` and `hubble-relay` memory **limits** so they stop being default victims (the
Longhorn `instance-manager`/`engine-image` pair can't be fixed that way — the chart's resource keys
don't reach Longhorn-managed pods, `tofu/longhorn.tf:155-160`, which is why they outrank everything
else on any node they run on), and fix the `PodSigkilled` alert text — it tells the
responder to confirm via `talosctl dmesg | grep 'OOM controller'`, when `talosctl get oomactions
-o yaml` gives the score, the trigger context and the victim cmdlines directly.

## 6. What this ride could NOT verify (and the exact commands that would)

Cluster reads were denied — `kubectl get nodes` returns
`nodes is forbidden: User "system:serviceaccount:homelab:agentstack-worker" cannot list resource
"nodes"` — and no `talosconfig` exists in this pod, so **every live-state claim above comes from
this repo's as-code patches**, per the issue's degrade instruction. Three checks remain open; all
are jail-session one-liners:

```sh
# 1. Does kubepods/guaranteed exist on a kata node, or are Guaranteed pods at kubepods/pod<uid>?
#    (§1.3 — decides whether Guaranteed pods are candidates at all)
devbox run -- talosctl -n 192.168.2.184 ls /sys/fs/cgroup/kubepods

# 2. The kill log: score, trigger context, victim cmdlines. score==0 ⇒ the §1.4 random-victim path.
#    Known to work from the jail — this is how FU-139 got wk-02's record on 2026-08-04.
devbox run -- talosctl -n 192.168.2.184 get oomactions -o yaml   # needs an os:admin talosconfig

# 3. Confirm the running version really is v1.13.2 on the tier before/after any upgrade
devbox run -- talosctl -n 192.168.2.184 version
```

Check 2 in particular converts this whole document from "mechanism that fits the evidence" to
"mechanism confirmed", and it is worth running **before** the upgrade so there is a before/after.

## Related

FU-155 (tracker), FU-139 / FU-112 / FU-082 (archived — the reservation hardening this builds on),
FU-033 (a *1.14* precondition; option A stays inside 1.13), ADR-044 (the ephemeral tier),
`docs/incidents/2026-07-27-kata-ride-oom-cascade.md`, homelab#63/#65/#100/#101.
