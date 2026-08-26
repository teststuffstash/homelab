# Spike — kata guests can't reach cluster-service VIPs

**Tracked by:** FU-072. **Status:** diagnosed, not root-caused. Workaround in place.
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

Related: FU-116 (kata ride storage, separate root cause — see
[the OOM cascade incident](../incidents/2026-07-27-kata-ride-oom-cascade.md)), `docs/spikes/kata-ci-gate.md`.
