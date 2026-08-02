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

## Collateral finding (2026-07-18, meta-8)

The launcher's endpoint-IP rewrites additionally need **endpoints-read for IN-CLUSTER
dispatchers** — granted via the `agent-coordinator` + `agentstack-claims-read` ClusterRoles. Before
that grant, coordinator-dispatched kata rides shipped raw service URLs and the claude harness died
`ConnectionRefused` (oracle-fleet#52 r1 strike). Note that this is a *consequence* of the workaround,
not of the bug: rewriting to endpoint IPs is only necessary because VIPs don't work.

Related: FU-116 (kata ride storage, separate root cause — see
[the OOM cascade incident](../incidents/2026-07-27-kata-ride-oom-cascade.md)), `docs/spikes/kata-ci-gate.md`.
