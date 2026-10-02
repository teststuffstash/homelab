# 2026-09-28 — wk-03 NotReady: an ARC runner job thrashed the 8 GB VM past its kubelet

**First symptom:** 13:10:04Z `wk-03` (Proxmox VM, 6 vCPU / 8 GiB, the ephemeral CI-runner tier)
goes `Ready=Unknown`; `KubeNodeNotReady` + `KubeNodeUnreachable` fire. **Class:** the third
memory-pressure loss of a runner node (07-27 wk-metal-03, 07-28 wk-metal-01 —
[kata-ride-oom-cascade](2026-07-27-kata-ride-oom-cascade.md); now wk-03) — and the first on a node
that already carried the FU-112(b) kubelet reservations, which did not act. **No data at risk:**
wk-03 holds no Longhorn disks; the only casualty was the job. Recovered by a hard reset at
13:16:34Z; `Ready` 13:17:54Z.

## Timeline (UTC)

| when | what |
|---|---|
| 12:58:33 | ARC ephemeral runner `homelab-ephemeral-jbtdz-runner-phvws` lands on wk-03 (request 1536Mi, no limit — by design, FU-082) beside the forgejo runner's DinD and the usual daemons: node requests 78 %, limits 114 %. |
| ~13:05 | node-exporter's last good scrape; the runner's working set was 3.9 GiB and rising (the last Prometheus sample). |
| 13:07 | The management sentinel's merged-onto-master plans of #2047/#2037 both show `kubernetes_node_taint.ephemeral["wk-03"]` — the first outside sign: the node's taint set had already changed (`node.cilium.io/agent-not-ready` re-added — the kubelet was re-registering). |
| 13:10:04 | `Ready=Unknown`; `node.kubernetes.io/unreachable` taints; `KubeNodeNotReady` fires (detector held — no issue report involved). |
| 13:11–13:14 | Seat reads from the hypervisor: VM `running`, ping 0.18 ms, guest agent answers, the kvm process at **700 % CPU** with 8.0 G resident; pve at load 10. Console (`qm monitor screendump`): Talos dashboard `KUBELET ✗ Unhealthy`, a storm of `__filemap_get_folio` / `exc_page_fault` backtraces — file-backed pages being evicted and refaulted with no swap. No OOM kill of any kind in the guest's kernel log. |
| 13:16:34 | Seat opens a declared window (`wk-03-1790601393-193`) and issues `qm reset 8113`. Talos boots 13:16:44; `Ready` 13:17:54. ARC runners now land on nx-01. |

## Root cause

A job whose real footprint exceeds an 8 GiB node ran on an 8 GiB node. Over 7 days the ARC
runner container's working set peaked at **20–23.5 GiB** on eight rides (all on nx-01); the
scale set requests 1536Mi and — correctly — sets no limit, so which node a job lands on is the
topology spread's luck. On wk-03 the job pushed the node into thrash faster than either belt could
act: the kubelet's `evictionHard memory.available=768Mi` needs a running kubelet sync loop, which
was itself being paged out; Talos's PSI-driven OOMController never fired (no kill was logged).
**Ruled out:** a VM/hypervisor fault (guest answered, host had 3 GiB free, no kernel or qm
events); a node reboot before 13:16 (guest uptime continuous); Longhorn/Cilium collateral (none
scheduled there beyond the daemons, all back after the reset).

## What held, what did not

- Held: `KubeNodeNotReady`/`KubeNodeUnreachable` (the detector), the reset path for an ephemeral
  node (no drain needed: no volumes, tainted, removable), the window record.
- Did not: the kubelet reservation as the "who acts first" belt on a **page-cache thrash** (it was
  designed against anon-memory OOM, FU-112); the OOMController's trigger on this shape — new
  evidence for the FU-155 tune-vs-accept ruling: a full-node stall with **no** kill at all.
- Probe lesson: `qm status` `uptime` is the qemu PROCESS age, not the guest's — it kept counting
  through the reset; the guest's `/proc/uptime` and the pve task log (`qmreset … OK`) are the proof.

## Residuals

FU-218 (the runner pool's envelope: an 8 GiB node in a pool whose jobs peak above 20 GiB — the
request should say what the heavy jobs need, or the small nodes leave the pool) and FU-155 (this
event as evidence). No new item.
