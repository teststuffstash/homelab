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
| Who speaks | every **non-control-plane** node's cilium-agent (`CiliumBGPClusterConfig` `nodeSelector`: `node-role.kubernetes.io/control-plane` DoesNotExist — §Which node a VIP's traffic enters) | FRR's `bgpd` on each router node, router-id = the node's own address (§With the router pair) |
| Peers | each router node's own address, `.70` and `.71` (`opnsense_peers`) — never the `.1` CARP VIP | one neighbour per peering node, listed by hand in `bgp_node_ips` (no control planes) |
| Sends | the LB IPs of Services labelled **`bgp=advertise`** only (`CiliumBGPAdvertisement`) | nothing — it originates no routes |
| Receives | nothing it uses (Cilium installs no received routes) | every advertised `/32`, accepted by the permit-all inbound route-map `CILIUM-ALLOW-ALL` (FRR's `ebgp-requires-policy` drops everything without one) |
| Code | [`tofu/cilium-bgp.tf`](../tofu/cilium-bgp.tf) (main root, applied via [the management box](management-box.md)); `bgpControlPlane.enabled` in [`tofu/cilium.tf`](../tofu/cilium.tf) | [`ansible/roles/opnsense-bgp/`](../ansible/roles/opnsense-bgp/), values in [`group_vars/opnsense.yml`](../ansible/group_vars/opnsense.yml); `bash scripts/opnsense-playbook.sh ansible/opnsense-bgp.yml` |

The packet path: a LAN (or WireGuard) client sends to `192.168.40.16` → its default gateway
`.1` → the router's kernel route (installed by FRR's `zebra`) forwards to ONE announcing node
(§Which node a VIP's traffic enters) → Cilium's eBPF datapath delivers to a backing pod, on that
node or across the vxlan tunnel (Services are `externalTrafficPolicy: Cluster`; a remote backend
sees the ingress node's address, SNAT). LAN HTTPS names add one hop in front: the HAProxy VIP on
`192.168.3.0/24` proxies to the `40.x` backend ([`runbook.md`](runbook.md)) — that hop is a
connection the ROUTER originates.

## Which node a VIP's traffic enters

FRR learns every VIP from every peering node and selects them all as equal-cost paths
(`show ip route 192.168.40.33/32` lists each), but the router's **kernel** holds one: OPNsense pins
`net.route.multipath=0` as a platform default (`system_sysctl_defaults()` in
`/usr/local/etc/inc/system.inc`, written to `/boot/loader.conf`). `zebra` writes one `RTM_ADD` per
nexthop; with multipath off the first succeeds and the rest fail `EEXIST`, which zebra ignores
by design (`zebra/rt_socket.c`). So every VIP rides the first nexthop zebra writes — in practice
the lowest-addressed peer. Measured 2026-10-13 on both router nodes: all 26 VIP routes via
`192.168.2.51`, **cp-01** — every LAN request to the cluster entered through a control plane.

The fix (2026-10-13): **control planes do not peer.** The `CiliumBGPClusterConfig` selects nodes
without the `node-role.kubernetes.io/control-plane` label (cp-01, cp-02, wk-metal-02 carry it,
set by Talos), and `bgp_node_ips` lists no control plane. A CP still runs backends — traffic just
never enters there. Applied 2026-10-13 16:37Z: all 26 VIP routes moved to the lowest-addressed
peering worker, hp-01 `.54` — a Longhorn storage node, by accident of address order.

**The ingress node is a choice, not an address order** (operator, 2026-10-13): the router side
sets FRR `weight` per neighbour (`bgp_neighbor_weight` in `ansible/group_vars/opnsense.yml`, the
`opnsense-bgp` role). FRR's best path is the highest weight, and with the kernel single-path that
is the one nexthop it holds; the others stay in FRR's table as failover, in weight order, then
address order. Today: wk-04 `.64` (VM on nx-02, beside the primary router node, no Longhorn) at
200, wk-02 `.62` (VM on pve) at 100, everyone else unweighted. Ingress moves — resetting the flows
it carried — only when the current node stops announcing.

### Kernel ECMP — not enabled (2026-10-13); #2534 CLOSED on the operator's ruling the same evening

**Ruling (operator, 2026-10-13):** not worth its reset class. Forwarded traffic would spread over
at most two nodes (below), every peer-set change — any worker reboot, every step of a Talos
rollout — would reset most HAProxy backend connections where today only the single ingress node's
own reboot does, and the one bulk workload (registry pulls) is disk-bound at 8–10 MB/s (FU-280),
so there is no throughput to win. The Tunables-as-code role change in #2534 returns when something
needs a tunable. Ingress is one worker (hp-01 since #2533's apply, 2026-10-13 16:37Z).

`net.route.multipath=1` (runtime-writable; OPNsense System > Tunables, `core/tunables` API) would
let the kernel hold every nexthop, after a real FRR stop + start so zebra re-writes the routes it
was refused. What it would buy on these routers, read from the FreeBSD 15 source they run:

- **Forwarded traffic** (LAN/WireGuard clients straight to a `40.x`) picks
  `nhops[flowid % size]`, with `flowid` from the RECEIVING NIC (`ip_fastfwd.c`). The router nodes'
  NICs are `vtnet`, which stamps `flowid` = the RX queue number (`if_vtnet.c`), and they run 2
  queue pairs: at most **two** nexthops ever carry forwarded traffic, not all of them.
  `net.inet.rss.enabled` (0 here) is the knob that would replace it with a software 4-tuple hash —
  untested, reboot-time.
- **Router-originated traffic** — HAProxy's connections to the `40.x` backends, i.e. every LAN
  HTTPS name — is hashed on (source, destination, destination port) once the first multipath
  route exists (`net.route.hash_outbound` is read-only and flips to 1 by itself, `route_ctl.c`):
  per backend VIP, spread over all nexthops.
- **The cost:** a nexthop-set change (a node reboots, joins, leaves) re-indexes the group, and
  `hash % size` moves flows to another node. Cilium there has no conntrack entry; with SNAT
  (vxlan tunnel, `etp=Cluster`) the backend would see a new source address anyway, so the
  connection resets. **Maglev does not fix this here**: it makes every node pick the same backend
  for a 5-tuple, which only preserves a connection when the backend sees the client's address —
  DSR, and DSR in tunnel mode needs Geneve (`loadBalancer.dsrDispatch=geneve`,
  `tunnelProtocol=geneve`; vxlan supports no DSR dispatch) — a datapath change, not a values
  line ([Cilium kube-proxy-free docs](https://docs.cilium.io/en/v1.19/network/kubernetes/kubeproxy-free/)).

## Failure modes worth knowing

- **A node missing from `bgp_node_ips`.** The cluster side is a label selector (every non-CP
  node), the router side is an explicit list, so a new node peers with nobody until it is added and the play run. Missed
  repeatedly at onboarding (each miss is annotated in the list itself);
  `CiliumBGPNodeSessionDown` is what catches it. A
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

- `CiliumBGPAllSessionsDown` (critical, 5 m) — a router peer with no established session from any
  node (per `neighbor`, plus the metric vanishing altogether): that router holds no VIP routes.
- `CiliumBGPNodeSessionDown` (15 m) — one node × peer down: that node advertises nothing.

## With the router pair

After the cutover `.1` is a CARP VIP over two router nodes (nx-02 `.70`, pve `.71`; ADR-144,
[`router-move.md`](router-move.md)). A BGP session is a TCP connection to ONE `bgpd`, and pfsync
replicates firewall state, not `bgpd`'s sessions — so a cluster peering the VIP would lose every
session and every route on each failover, and the new MASTER would start with an empty table.
The pair shape instead:

- **Cilium peers each node's own address** (`.70` and `.71`), so both routers hold every route
  all the time and whichever is MASTER forwards from a warm table.
- **Each node has its own router-id** (its LAN address) — `bgp_router_id` is a host var in
  `ansible/router-nodes/inventory.yml`.
- **The alerts are per peer** (done 2026-10-01): with two peers a "sum of sessions = 0" would
  stay silent while one router has none — and if that router is MASTER every VIP is down.
- **Standing nodes are inert until the window** (router-move §The standing nodes): neighbours
  configured but disabled, and the hypervisor kill switch stops a node that sends a BGP SYN or
  SYN-ACK. Peering the standing nodes ahead of the window therefore needs that rule settled
  first — FU-297.
