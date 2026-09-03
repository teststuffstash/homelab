# Spike — kata guests can't reach cluster-service VIPs

**Tracked by:** FU-072. **Status:** symptom GONE on re-probe (2026-09-03, §Re-probe below) — never
root-caused; the workaround is now the only thing still causing harm (the stale-endpoint class).
**Environment:** Cilium 1.19, `kubeProxyReplacement`, `bpf-lb-sock=false`. First seen 2026-07-13 on
wk-metal-03.

## Symptom

From inside a **kata** pod:

| Traffic | Result |
|---|---|
| pod-to-pod, including cross-node coredns **POD IP** (UDP + TCP) | ✅ works |
| external, by IP | ✅ works |
| **ANY `10.96.x` service VIP** (UDP *and* TCP) | ❌ black-holes |

Per-packet service translation isn't happening for kata-veth traffic — even though it works for
**runc** pods on the same node. That last clause is the whole puzzle: same node, same Cilium agent,
different result by runtime.

## Ruled out

- `socketLB.hostNamespaceOnly=true` applied (`tofu/cilium.tf`) — **no effect**. Socket LB was
  already off, so this was never the mechanism.

## Next probes

- Hubble verdicts on the kata endpoint for `10.96/16` traffic — is it dropped, or never translated?
- `cilium-dbg bpf lb list` from the node agent, compared between a kata and a runc endpoint.
- Upstream cilium + kata issues; this smells like a known interaction.

## Workaround (in place)

Kata CI-gate pods run `dnsPolicy: None` with the LAN resolver (192.168.2.1). Fine for k3d/registry
work. **Blocks in-cluster consumers** — notably Garage transcript upload from kata pods.

## Re-probe (2026-09-03): VIPs reachable from kata on every kata node

Operator ask after two rides (`oracle-fleet` issue-355-r5, issue-387-r3) were black-holed by the
endpoint rewrite when `openrouter-proxy` rolled at 12:26 (PR#1351 → ArgoCD sync). Matched
kata + runc `busybox` pods per node (namespace `fu072-probe`, no CNP, default `dnsPolicy`),
plus the two LIVE kata rides (egress CNP, `dnsPolicy: None`):

| Node | Runtime | `10.98.187.234:8080` TCP (proxy VIP) | `10.96.0.10:53` UDP (kube-dns) | `10.96.0.1:443` TCP |
|---|---|---|---|---|
| wk-metal-01 | kata / runc | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ |
| wk-metal-02 | kata / runc | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ |
| wk-metal-03 | kata (live ride 387-r3) / runc | ✅ / ✅ | — / ✅ | — / ✅ |
| wk-metal-04 | kata (probe + live ride 355-r5) / runc | ✅ / ✅ | ✅ / ✅ | ✅ / ✅ |

(A fresh kata probe on wk-metal-03 stayed Pending — `Insufficient memory`: one laptop = one
~4 GiB kata ride, by design.) Same Cilium 1.19.1 and the same `cilium-config` LB keys as at first
sighting; what changed is not recoverable from git (history re-rooted 2026-08-19). Candidate:
the 2026-07-28 Cilium agent rollout on all four metal nodes (DS generation 8 — the
[kata OOM-cascade incident](../incidents/2026-07-27-kata-ride-oom-cascade.md)'s fix raised
`cilium-agent` from BestEffort to Burstable, re-creating every agent; the first sighting was on the
same laptop that had been OOM-killing its agent) — VIPs were never re-tested after it; the 2026-08-26 collateral finding only documented the rewrite's stale-IP cost.
**Consequence:** the workaround (endpoint-IP rewrite + `dnsPolicy: None`) is now pure liability —
FU-072's next action is deleting it, not root-causing the original symptom.

## Collateral finding (2026-08-26): the endpoint IP goes stale when the target rolls

The endpoint-IP rewrite is resolved ONCE at dispatch, so a ride that outlives the target pod
loses the dependency mid-ride — and a dead pod IP is a silent black hole (SYN drop, no RST), not
an error. Seen live on `agent-oracle-fleet-issue-272-r1`: the openrouter-proxy Deployment rolled
~70 min into the ride (it rolls ~4×/day), the baked-in `OPENROUTER_HOST=http://10.244.6.174:8080`
stopped routing, and opencode slept — zero sockets, 0-byte run.log — until the 4h
`activeDeadlineSeconds` reap. Detection half tracked as FU-187 (quiet-stall belt); the structural
fix is this spike's root cause (VIPs reachable ⇒ no rewrite), or a headless-Service DNS name /
re-resolve-and-retry if the root cause stays open.

## Collateral finding (2026-07-18, meta-8)

The launcher's endpoint-IP rewrites additionally need **endpoints-read for IN-CLUSTER
dispatchers** — granted via the `agent-coordinator` + `agentstack-claims-read` ClusterRoles. Before
that grant, coordinator-dispatched kata rides shipped raw service URLs and the claude harness died
`ConnectionRefused` (oracle-fleet#52 r1 strike). Note that this is a *consequence* of the workaround,
not of the bug: rewriting to endpoint IPs is only necessary because VIPs don't work.

Related: FU-116 (archived 2026-08-02 — kata ride storage, separate root cause — see
[the OOM cascade incident](../incidents/2026-07-27-kata-ride-oom-cascade.md)), `docs/spikes/kata-ci-gate.md`.
