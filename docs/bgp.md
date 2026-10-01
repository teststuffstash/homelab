# BGP — how LoadBalancer VIPs reach the LAN

_The mechanism behind [ADR-021](adr.md) (Cilium BGP ↔ OPNsense FRR, not MetalLB). Which VIP a
service holds: [`SERVICES.md`](../SERVICES.md); which range a new one comes from:
[`ip-plan.md`](ip-plan.md). What the router pair changes: §With the router pair below, tracked on
FU-297 ([`router-move.md`](router-move.md))._

## The problem

A `type: LoadBalancer` Service gets an address from Cilium's pool (`192.168.40.0/24`,
`CiliumLoadBalancerIPPool` in [`tofu/cilium-bgp.tf`](../tofu/cilium-bgp.tf)). No machine owns
that address, and the pool is not the LAN's subnet, so ARP cannot find it (ADR-021: L2 discovery
does not cross this boundary). The router has to be **told** which nodes can deliver it. That is
all BGP does here: the cluster announces "`192.168.40.16` is reachable via me", the router
installs a route.

## The two ends

| | Cluster (Cilium) | Router (OPNsense + os-frr) |
|---|---|---|
| ASN | **64513** | **64512** (different ASNs → eBGP) |
| Who speaks | every node's cilium-agent (`CiliumBGPClusterConfig`, empty `nodeSelector` = all nodes) | FRR's `bgpd`, router-id `192.168.2.1` |
| Peers | one: `192.168.2.1` (`opnsense_ip`) | one neighbour per node, listed by hand in `bgp_node_ips` |
| Sends | the LB IPs of Services labelled **`bgp=advertise`** only (`CiliumBGPAdvertisement`) | nothing — it originates no routes |
| Receives | nothing it uses (Cilium installs no received routes) | every advertised `/32`, accepted by the permit-all inbound route-map `CILIUM-ALLOW-ALL` (FRR's `ebgp-requires-policy` drops everything without one) |
| Code | [`tofu/cilium-bgp.tf`](../tofu/cilium-bgp.tf) (main root, applied via [the management box](management-box.md)); `bgpControlPlane.enabled` in [`tofu/cilium.tf`](../tofu/cilium.tf) | [`ansible/roles/opnsense-bgp/`](../ansible/roles/opnsense-bgp/), values in [`group_vars/opnsense.yml`](../ansible/group_vars/opnsense.yml); `bash scripts/opnsense-playbook.sh ansible/opnsense-bgp.yml` |

The packet path: a LAN (or WireGuard) client sends to `192.168.40.16` → its default gateway
`.1` → the router's kernel route (installed by FRR's `zebra`) forwards to an announcing node →
Cilium's eBPF datapath delivers to a backing pod. LAN HTTPS names add one hop in front: the
HAProxy VIP on `192.168.3.0/24` proxies to the `40.x` backend ([`runbook.md`](runbook.md)).

## Failure modes worth knowing

- **A node missing from `bgp_node_ips`.** The cluster side is all-nodes, the router side is an
  explicit list, so a new node peers with nobody until it is added and the play run. Missed four
  times (wk-03, wk-metal-04, nx-01, cp-02); `CiliumBGPNodeSessionDown` is what catches it. A
  retired node's neighbour must be deleted live too — the role is create-if-absent
  ([`runbook.md`](runbook.md) §Retire a node from cluster duty, step 5).
- **A VIP-alias reconfigure on OPNsense flushes the FRR routes from the kernel** while `bgpd`
  still shows Established: every `40.x` black-holes (25-minute outage, 2026-07-13). Recovery is
  a real FRR stop + start — the `restart` endpoint is a no-op. Detail: the `group_vars/opnsense.yml`
  header and [`runbook.md`](runbook.md).
- **A fresh router's `bgpd` never starts** on first enable (FU-298); the role's
  `bgpd-running.yml` detects and cycles it, a no-op on a router where it runs.
- **Saved is not applied:** the O-X-L collection's `reload` default is false since 26.x; the role
  forces `reload: true` for every `frr_*` call (comment in the role's `tasks/main.yml`).

## The alerts

Rule group `cilium-bgp` in
[`kube-prometheus-stack.yaml`](../argocd/platform/values/kube-prometheus-stack.yaml), on
`cilium_bgp_control_plane_session_state` (1 = established, one series per node × peer):

- `CiliumBGPAllSessionsDown` (critical, 5 m) — no session anywhere: every VIP unreachable.
- `CiliumBGPNodeSessionDown` (15 m) — one node × peer down: that node advertises nothing.

## With the router pair

After the cutover `.1` is a CARP VIP over two router nodes (nx-02 `.70`, pve `.71`; ADR-144,
[`router-move.md`](router-move.md)). A BGP session is a TCP connection to ONE `bgpd`, and pfsync
replicates firewall state, not `bgpd`'s sessions — so a cluster peering the VIP would lose every
session and every route on each failover, and the new MASTER would start with an empty table.
The pair shape instead:

- **Cilium peers each node's own address** (`.70` and `.71`), so both routers hold every route
  all the time and whichever is MASTER forwards from a warm table.
- **Each node has its own router-id** (its LAN address) — today's single `bgp_router_id` moves
  per node.
- **The alerts change meaning**: with two peers, "sum of sessions = 0" stays silent while one
  router has none — and if that router is MASTER every VIP is down. The all-down condition
  becomes per peer.
- **Standing nodes are inert until the window** (router-move §The standing nodes): neighbours
  configured but disabled, and the hypervisor kill switch stops a node that sends a BGP SYN or
  SYN-ACK. Peering the standing nodes ahead of the window therefore needs that rule settled
  first — FU-297.
