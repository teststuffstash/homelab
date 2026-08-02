# 2026-07-27/28 — Kata ride OOM cascade: agents killed platform daemons on three nodes

**Residual:** FU-112 (platform-pod OOM posture), FU-116 (PVC janitor widening).
**Related:** FU-082 (archived 2026-07-25 — same class, earlier trigger), FU-081, FU-072, FU-093,
TICK-LOG §scratch-pool. Operator timeline on sleep-tracking#48.

An agent ride's memory overcommit let the **kernel** global-OOM a worker node, killing
`cilium-agent` and Longhorn daemons as collateral. The Longhorn breakage then produced a second,
initially-unrelated-looking failure — kata rides that could not attach a *healthy* block volume —
which cost a day of debugging as a suspected kata storage bug before being traced back to the same
root. Both are one incident.

## Timeline

| When (UTC) | What |
|---|---|
| 07-27 18:39 | wk-metal-03: the sleep-tracking#48 docker ride (k3d-in-dind integration gate) triggers a **kernel global OOM**. `longhorn-manager` + `cilium-agent` SIGKILLed as collateral. Three alerts fire; they are one incident. |
| 07-27 (same day) | Fix (a) shipped — `agents/agent-session.sh`: memory **requests = limits** for both ride modes + dind. |
| 07-28 13:03 | wk-metal-03 again, r4: the ride pushes the 8GB laptop into memory pressure. Talos OOMController kills the **BestEffort** `longhorn-csi-plugin` / `longhorn-manager` / `engine-image` (+ `cilium-agent`). Alerts homelab#63–66. |
| 07-28 13:03 | r4's dind CrashLoops `StartError exit=128` on the initial block-device hotplug: `"The disk could not be added to the VM… Cannot open disk path… No such file or directory"` — while Longhorn reports that very volume `state=attached robustness=healthy` and every Longhorn node condition True. |
| 07-28 13:42 | wk-metal-01, r5: `virtiofsd invoked oom-killer` — a **global** OOM whose trigger is the kata microVM's own filesystem daemon. |
| 07-28 13:45 | wk-metal-01: the k3d container exits 137; `/var/lib/docker` (an ephemeral `longhorn-scratch` Block PVC) goes **read-only** because its engine backend died in the OOM. Ride exits 255. |
| 07-28 13:53 | wk-metal-01: a second global OOM (`kubelet invoked oom-killer`) kills `longhorn-instance-manager` again. |
| 07-28 | `kubectl cordon wk-metal-03`; r5 re-dispatched to wk-metal-01 came up clean earlier, confirming node-specificity at the time. |
| 07-28 | Fix (b) shipped (4a9e9a9), wk-metal-03 uncordoned, validation ride passed (below). |

## Root cause

**Memory requests did not describe the real footprint, and the platform daemons were BestEffort.**

The ride carried correct *limits* (agent 2Gi + dind 2560Mi, kata) but memory **requests** of only
2Gi total. A kata VM grows toward limits + overhead (~5.1Gi), so the scheduler — which places on
requests — put a ~5.1Gi workload onto ~2Gi of free memory. The "one docker ride per node" envelope
existed only as a **comment in the launcher, not as a request**, so nothing enforced it.

When the kernel then had to choose victims, the platform daemons were the cheapest to kill:
`cilium-agent`, `longhorn-manager`, `longhorn-csi-plugin` and `engine-image` were BestEffort, so
their `oom_score_adj` sat above the overcommitted tenant's.

**The storage failures were symptoms, not a separate bug.** Both the "healthy volume won't attach"
(wk-metal-03) and the "`/var/lib/docker` read-only" (wk-metal-01) are the same cascade with the
collateral landing on the storage path instead of on networking: Longhorn's CSI/engine components
died in the OOM, so the block device could not be served. `talosctl dmesg` on wk-metal-01 shows the
identical sequence. **Kata block-device support is not inherently broken** — ruled out by the
validation ride below.

## Fixes

- **(a) Launcher requests — DONE 07-27** (`agents/agent-session.sh`): memory requests = limits for
  both ride modes and for dind. CPU stays overcommitted deliberately — CPU throttling is safe.
  The kata `RuntimeClass` `podFixed 512Mi` makes scheduler accounting match the real VM.
- **(b) Platform-pod OOM posture — DONE 07-28** (4a9e9a9, `tofu/metal.tf`). The operator's ruling
  was "agents must not be able to kill cilium". Raising the daemons to Burstable requests was
  **not enough** (measured `oom_score` still ~934), so the chosen route was a **Talos kubelet
  reservation on the kata nodes only** (wk-metal-01/02/03):
  `systemReserved.memory` 384→512Mi, `kubeReserved.memory` 0→256Mi,
  `evictionHard.memory.available` 100→512Mi.
  ⚠ The maps must be written **in full** — Talos's `extraConfig` merge otherwise drops
  cpu/pid/ephemeral and the disk-pressure thresholds.
  Effect: the kubelet now **evicts** the non-critical ride ~½GiB before the kernel global-OOMs;
  `cilium` (`system-node-critical`) and Longhorn (`longhorn-critical`) are eviction-exempt.
  Verified live on all three nodes. Allocatable ~7.4 → 6.2–6.36GiB; a ~5.1Gi ride still fits.

## Validation

A deliberately hostile re-run on wk-metal-03 (meta-15, 07-28): a faithful ~5Gi kata+dind ride
(exact 2Gi + 2560Mi + 512Mi footprint, `longhorn-scratch` block PVC) that **overloaded dind with
escalating k3d clusters**. Result: dind mounted the block volume cleanly (no read-only), the k3d
creates failed **contained** by the dind cgroup cap, and the host survived — `global_oom` count
unchanged, `MemoryPressure=False`, Longhorn 0 restarts.

This is the correct residual failure mode: **the pod fails, the node survives.**

## Probe lesson

- **A kata-*guest* cgroup OOM is invisible to host `dmesg`.** Watch the host oom-killer *count*,
  not the guest. A quiet guest log is not evidence of no OOM.
- **"Healthy" from the storage controller is not evidence the data path works.** Longhorn reported
  `state=attached robustness=healthy` on a volume that could not be opened, because the reporting
  component and the serving component died separately.
- Alerts arriving from three subsystems within minutes are usually **one** incident. Triaging them
  as three (and burning the responder's daily cap, see
  [the responder incident](2026-07-27-responder-silent-defer.md)) is a predictable second failure.

## Residual work

- **FU-112** — `engine-image` DaemonSet still has no `priorityClass` (BestEffort), against the
  "nothing platform-critical BestEffort" sub-goal. Trivially restartable and non-cascading, so it
  was left as a minor note rather than fixed.
- **FU-116** — the ephemeral `docker-lib` PVC of a terminal **Error/Failed** ride pod leaks: the
  scan janitor deletes only `Succeeded` ride pods >2h. One r1 PVC was still Bound 18h later. This
  regresses the #41/#63 `longhorn-scratch` pool-exhaustion class fix. Widen the janitor to
  Error/Failed.
- Capacity residual: the 16GB **wk-metal-04** desktop (onboarding) is the real headroom answer for
  docker rides.

## Bookkeeping

Stale OOM-cascade alerts homelab#68/#69 fired 13:03/13:42Z **during** the ride — their evidence is
the pre-apply BestEffort state — dispositioned and closed. Clearing #48's `agent/error` breaker was
the re-dispatch that exercised fix (a). An in-VM dind cgroup OOM (gate too fat for 2560Mi) remains
the *correct* failure mode, not a regression.
