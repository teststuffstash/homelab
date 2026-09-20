# Spike — Cilium drops the `kubernetes` Service backend when the apiserver restarts

**Tracked by:** FU-258. **Status:** reproduced twice, not root-caused; PARKED behind the upgrade
debt (§Why this is parked). **Environment:** Cilium 1.19.1, `kubeProxyReplacement=true`,
`bpf-lb-sock=false`, `k8sServiceHost=localhost` / `k8sServicePort=7445` (Talos KubePrism),
Kubernetes v1.36.1, **one** control plane. First seen 2026-09-20.

## Symptom

An apiserver restart leaves the in-cluster Kubernetes Service with **no backend** in Cilium, on
most or all nodes, and Cilium does not re-sync it. Pods then get:

```
dial tcp 10.96.0.1:443: connect: connection refused
```

while the API itself is healthy, every node reads `Ready`, and `kubectl` from outside works fine.
`cilium-dbg service list` shows the frontend with an empty backend column:

```
ID    Frontend                  Service Type   Backend
10    10.96.0.1:443/TCP         ClusterIP                      ← empty
218   10.96.0.10:53/TCP         ClusterIP      1 => 10.244.1.134:53/TCP (active)
```

The `Endpoints` object is correct throughout (`192.168.2.51 port=6443`) — this is Cilium's view,
not Kubernetes'.

**Blast radius.** Everything that reaches the API through the ClusterIP crashloops:
cilium-operator, crossplane, cnpg-operator, longhorn's csi-provisioner, kube-state-metrics; ARC
runners wedge at `Init:0/2` so CI stops. The data plane is untouched — running pods keep running,
which is why `kubectl get nodes` is a useless check for it.

**Recovery.** `kubectl -n kube-system rollout restart ds/cilium`. Backends return immediately on
the new agents. Nothing else was needed either time.

## Evidence (2026-09-20)

Both occurrences followed an apiserver restart caused by a control-plane machine-config change.

| | Occurrence 1 (~11:35Z) | Occurrence 2 (~12:41Z) |
|---|---|---|
| Trigger | `cluster_endpoint` cutover (apiserver restart ×2) | `apiServer.extraArgs` probe (apiserver restart) |
| Agents holding the backend | **2 of 12** (`cp-01`, `wk-03`) | **0 of 12** |
| Prometheus `sum(up)` | 48 → 0 | 150 → 99 |
| Fix | `rollout restart ds/cilium` | `rollout restart ds/cilium` |

## What we do NOT know — and the fact that breaks the obvious story

The tempting explanation is that at **one** control plane an apiserver restart empties the
`default/kubernetes` endpoint set, Cilium removes the backend, and it fails to re-add when the
address returns. If that were the whole story, three control planes would remove the condition
(the set never empties during a one-at-a-time roll) and this would be self-limiting.

**But occurrence 1 had two survivors.** `cp-01` and `wk-03` kept their backend while the other ten
lost it. Every agent watches the same object, so a pure "the endpoint set emptied" story predicts
they all behave alike. Two candidate explanations, neither verified:

- `cp-01` is the apiserver's own node; `wk-03` had just had two machine-config applies of its own
  (a `--mode=try` patch and its revert), which may have restarted or re-synced something.
- The loss is not in the agent's k8s state at all but in its LB reflector / eBPF programming, and
  what differed was timing rather than node role.

**The distinguishing measurement was never taken**: `cilium-dbg service list` (agent view) versus
`cilium-dbg bpf lb list` (the eBPF maps). If the maps hold the backend while `service list` does
not, this is the documented agent-state-vs-datapath divergence family; if both are empty, the
agent genuinely lost the resource. We only ever captured `service list`.

## Prior art

Not unique to us in *class*, but no upstream issue was found matching this symptom:

- [cilium#34653](https://github.com/cilium/cilium/issues/34653) "Cilium breaks after the Kube API
  server is restarted" — **different**: agents cannot connect at all, `socketLB` enabled, hybrid
  kube-proxy, v1.15.x. Our agents stay connected (KubePrism).
- [cilium#28764](https://github.com/cilium/cilium/issues/28764) — pods on new nodes missing
  connectivity until the agent is restarted. Same *remedy*, different trigger.
- The documented triage for agent-state vs eBPF-map divergence is comparing `cilium-dbg service
  list` with `cilium-dbg bpf lb list`
  ([troubleshooting](https://docs.cilium.io/en/stable/operations/troubleshooting/)).
- We are configured the way the docs prescribe for kube-proxy-free (`k8sServiceHost`/`Port` set),
  so the standard "you forgot `k8sServiceHost`" answer does not apply.
- [v1.19.4](https://github.com/cilium/cilium/releases/tag/v1.19.4) carries EndpointSlice
  watch-related fixes, none of which plainly names this symptom.

## Why this is parked

Characterising a bug on **1.19.1** describes a version we should not be running, and upstream's
first question on any report is whether it reproduces on current. Cilium **1.20.2** lists
Kubernetes 1.33–1.36 as e2e tested, so our 1.36.1 is in range and the upgrade is the honest
prerequisite, not 1.19.4 (operator ruling, 2026-09-20).

Reproducing it also means deliberately restarting the apiserver on the live cluster — the same
outage twice over — which is not worth paying to characterise a version we intend to leave.

This sits behind the upgrade debt generally: the fleet drifted because nothing pushed it
(`ROADMAP.md` §G-D ruled 2026-09-18 that the **rollout is automated first**, Renovate on class-6
after). Revisit once Renovate is live and the fleet is current.

## What would settle it

1. On **1.20.2**, restart the apiserver deliberately (in a maintenance window) and capture, on at
   least three nodes including the apiserver's own: `cilium-dbg service list`, `cilium-dbg bpf lb
   list`, and the agent log around the restart (k8s watch errors, reflector resync).
2. If it reproduces: file upstream with that pair of outputs — the divergence question above is
   the first thing a maintainer will ask.
3. If it does not: record the version that fixed it and close, keeping the mitigation as a belt.
4. Either way, re-run at **three** control planes to settle whether the single-CP endpoint-set
   emptying is load-bearing.

## Mitigation in place

`scripts/controlplane-upgrade.sh` checks the backend on every agent after the upgraded node
rejoins and rolls `ds/cilium` only when one is actually missing — the check is shared with
`scripts/maintenance-window.sh` (`have` / `missing` / `unknown`, two attempts, so a flaky
`kubectl exec` is never read as a missing backend). `/maintenance-window` carries the same check
for every other live change.
