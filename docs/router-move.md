# The router move — Big Data → a from-git VM on nx-02

_Sub-steps 1–3 of [ROADMAP](../ROADMAP.md) §HA model step 2 (the CARP sequence); tracked on
FU-297 ([`follow-ups.md`](follow-ups.md)) — part of that item, not a new one. The proving ground
is the test VM + rebuild drill, [`opnsense-test-vm.md`](opnsense-test-vm.md); the rehearsal of THIS
move is that drill's router shape (§The router rehearsal there). Addresses: [`ip-plan.md`](ip-plan.md)._

**The move:** the router stops being the HP desktop "Big Data" (`em0` WAN, an Intel 4-port card
as LAN) and becomes a VM on `nx-02`, built from git: WAN = nx-02's `eno2` by PCI passthrough,
LAN = a virtio NIC on `vmbr0`. It keeps **`192.168.2.1`** — so the move changes no consumer's
address, and the only things that must come across are the router's **identity**. Big Data stays
cabled and powered off as the fallback for 1–2 weeks, then retires. **Since ADR-144 (2026-09-30)
the move is to a CARP PAIR built beside Big Data** — the nx-02 VM and a `pve` VM (which gets a
single-port x1 NIC for its WAN; Big Data's card never moves), each standing at its own LAN IP
before the window; the identity below is carried onto both.

## What the consumers need — the single-router inventory (2026-09-29)

Every git-tracked reference to the router, sorted by what the move needs from it. Grep method:
`192\.168\.2\.1([^0-9]|$)`, `opnsense-fw`, `opnsense.teststuff.net`, `OPN_HOST`, `OPN_API_*`,
ASN 64512, `wg.teststuff.net`, ddclient — history prose (TICK-LOG, archive, incidents, ADR text)
excluded.

**(A) the service address — nothing to do while the router keeps `.1`.** Gateway + DNS + NTP
everywhere: tofu `var.gateway`/`var.nameservers` (`tofu/variables.tf`; its own copy in
`tofu/provisioning/variables.tf`), DHCP options 3/6 (`opnsense/dnsmasq-dhcp.py`), the box's
networkd + timesyncd (`mgmt/nixos/hosts/mgmt/default.nix`), ESPHome SNTP, the WireGuard clients'
DNS (`group_vars/opnsense.yml`), tuya-egress's NTP redirect, the `unbound-github` probe + its
alert (`argocd/resources/blackbox/blackbox.yaml`), stack-lint's `dig`, the agentstack CNP's
dead `:53` leg. Cilium's BGP peer (`tofu/cilium-bgp.tf` `opnsense_ip`) and the router-id
(`group_vars` `bgp_router_id`, duplicated in the bgp role's defaults) are `.1` too — same
address, same ASN, so the sessions re-form against the new box with no config change.

**(B) the management/API address — nothing to do for this move; everything for CARP.** Its one
home is `ansible/inventory.yml` (`opnsense-fw`'s `ansible_host`): the plays, the FU-013 user
mint, the test VM, the drill's `PROD` and `scripts/wireguard-client.sh` all read it (the last
two since 2026-09-30). Literals that stay, each for a reason: the `OPN_HOST` defaults of
`opnsense/dnsmasq-dhcp.py` + `opnsense/tuya-egress.py` (stdlib-only scripts — the toolchain's
python has no YAML; `OPN_HOST` overrides them); the backup CronJob's `OPNSENSE_ADDR` + its
NetworkPolicy `toCIDR` (`argocd/resources/opnsense-config-backup/` — cluster manifests cannot
read the inventory); and the second guards (`guard.yml`, `opnsense-test-vm.sh`, the drill's own
host check, dnsmasq-dhcp's remap refusal), which are deliberately independent of the inventory
so a wrong inventory cannot aim a harness at prod. While the router is one box at `.1` all of
them stay right. CARP gives each node its own address and makes `.1` a VIP: then these must
become per-node (the inventory grows a host per node; everything else derives from it), the
Cilium peer list gets one entry per node (BGP to a VIP breaks on failover), each node gets its
own router-id, and `CiliumBGPAllSessionsDown` changes meaning with two peers. Since ADR-144 the
inventory half starts at sub-step 2 (each standing node is its own host from day one); the Cilium
peers, router-ids and the alert's meaning land with the CARP trial and the window (sub-steps 2–3).

**(C) identity — must come across, or a consumer breaks.** The next section.

Also physical, not code: `sensor.plug_opnsense_power` (HA `power.yaml`, the dashboard,
`machines.yaml` `plug`/`idle_w`) measures Big Data — meaningless for a VM; retire at sub-step 3.

## The identity the new router carries

| Identity | Consumer that breaks without it | Mechanism | State |
|---|---|---|---|
| Certificates + CAs (17 LE certs, refids intact) + the web GUI's `ssl-certref` | every HAProxy frontend (binds by refid), the GUI name | **carried from the newest FU-013 backup** at seed time (`opnsense/test-vm/seed-shape.py` `trust`) | operator ruling 2026-09-29; rehearsal-proven (below) |
| The registered ACME account + its certificate rows | renewal; a fresh account would re-register (FU-298's 404) and re-issue 17 certs against LE's weekly limit | carried (`acme`) — acme.sh renews on its 60-day clock from there | same |
| API users `backup-puller`, `automation` + their keys; root's API key | the backup CronJob's ESO secret, the box's `OPN_API_*` belts, every playbook | carried (`api-users`: the users with their hashed keys; root's prod key lines appended to the seed's own) — no key is re-minted, so nothing in the wallet/Infisical flips | rehearsal-proven (below); the users role then finds each user WITH a key and mints nothing |
| WAN MAC (`em0`, `machines.yaml` `opnsense.wan_mac`) | the ISP lease (and the public IP ddclient publishes) | `spoofmac` on `igb0` | rehearsal-proven (below) |
| WireGuard server keypair | the two client configs | **carried** (`wireguard`: the whole section — operator 2026-09-30 chose (a) over (b) export to the wallet + an import path and (c) re-issue both clients: the key already rides every encrypted backup, and no client is touched; (c) stays the lost-everything fallback, (b) returns with CARP's shared-key question) | rehearsal-proven (below): `wg_handshake` |
| root password | the console / GUI login (the VM's break-glass: nx-02's console) | **the router's own wallet entry `opnsense-root-password`** (operator 2026-09-30 chose it over carrying prod's hash: root becomes rebuildable from the wallet like every other secret) — the seed renders its hash; Big Data keeps its own, so the fallback's login is unchanged | rehearsal-proven (below): `root_password` |
| hostname | the GUI title, syslog | prod reads `OPNsense`; the seed writes one — the cutover seed must write prod's | trivial, at the cutover build |

The carry takes **only identity** — never anything a play owns: the plays converge the rest from
git, and the drill's score says how much of prod that is.

## The cutover — a config flip plus one window

**The standing nodes** (ADR-144 — this replaces the management-path fork: a temporary
management NIC, a tunnel into an isolated bridge, a permanent management segment). Each node is
built in its final shape and **stands on the real LAN at its own address before the window**:
nx-02's at `192.168.2.70`, pve's at `192.168.2.71` (`/22`, prod's LAN mask — the `/22`-vs-ADR-088
question stays the CARP ruling's). That address is the node's `ansible_host` for good, so the jail
manages it like any host and nothing is re-addressed later. Until the window a standing node must
be **inert** — every address and every outbound act prod owns stays prod's:

- no `.1`, and **none of prod's HAProxy VIP aliases** (`192.168.3.0/24`): a second holder on the
  same LAN is an ARP collision that breaks prod's services. Not even as CARP VIPs — with no other
  CARP speaker a node promotes itself to master and answers ARP;
- DHCP off (dnsmasq), BGP neighbours silent (FRR off or no neighbours), ddclient off;
- **ACME renewal off**: the carried certs would otherwise renew FROM the node — a real LE order and
  a Cloudflare TXT write with prod's token, racing prod's own renewal (the drill refuses at 58 days
  for the same reason; a standing node lives past that);
- its WAN uncabled (it wears `em0`'s MAC — the bootstrap refuses carrier).

**The standby profile** is one knob, `opnsense_standby` (`ansible/group_vars/opnsense.yml`,
default false; a standing node's host_vars set it true, the cutover converges it false), plus
`OPN_DHCP_ENABLE=0` for `opnsense/dnsmasq-dhcp.py`. Per rule: the BGP neighbours stay configured
but **disabled**; the ACME client's global **auto-renewal off**; ddclient **disabled**; dnsmasq
converged but **off**; the HAProxy service VIPs on **`lo0`** instead of `lan`
(`haproxy_vip_interface`), so HAProxy binds and serves but no LAN ARP answers for them (the real
LAN is a `/22`, so `192.168.3.0/24` is on-link). The role clears each address from the other
interface, so the flip never leaves two holders. `.1` is the node's seed (its own LAN address), not
the plays. Proof: `scripts/opnsense-drill.sh --router --standby` has one probe per rule (`standby_*`
in the report). CARP is learned on the pair meanwhile with a trial VIP from `192.168.3.0/24` that
prod does not hold. The WAN: pve's is a Realtek x1 card (TP-LINK TG-3468, in hand 2026-09-30) —
Linux drives it, bridged on the host (virtio into the VM, never passthrough: FreeBSD's Realtek
driver and the X99 chipset slot's IOMMU grouping both argue against it). **nx-02's `eno2` moves to
the same bridged shape** (operator, 2026-09-30: *"bridged if there is no performance penalty"*), so
the two nodes are identical. Both WANs are 1 GbE (I350, RTL8168), so the bar is NAT'd line rate
through virtio. **Measured 2026-09-30 — no penalty, so nx-02 is bridged:**
`opnsense-drill.sh --router --wan bridged` (2 vCPU, `queues=2`, offloads off as converged) pushed
2988–3256 Mbit/s through NAT → `vtnet2` → the host bridge, 1 and 4 streams both ways — about 3× line
rate — and leased on the spoofed MAC through the bridge (`wan_lease`). Score 0. Web reports agree:
1 Gbit/s over virtio is routine on this CPU class, and passthrough buys CPU headroom, not throughput
(the numbers + sources: [`opnsense-test-vm.md`](opnsense-test-vm.md) §The router rehearsal). Two knobs
that matter: the WAN NIC stays `firewall=0` (Proxmox's `macfilter` would drop the spoofed source
MAC), and OPNsense 26.7's pf SYN cookies must not be `always` on vtnet (opnsense/src#326). pve's
RTL8168 is the part to watch (the r8169 "transmit queue timed out" class on PVE 8). The dark-WAN
guard has the bridged variant (host port carrier 0, enslaved, bridge without an address).

**Building a standing node** (nx-02's first, pve's the same shape). tofu owns the hardware
(`tofu/opnsense-router.tf`: the WAN bridge `vmbr3` = `eno2` alone with no address, and the VM, net0 =
`vmbr0` LAN with a fixed MAC, net1 = `vmbr3` WAN, created stopped) — applied through the box in a
window, since a bridge is a host network change. Then `bash scripts/opnsense-router-node.sh build nx02`:

1. **kill switch** armed on the hypervisor before anything boots — tcpdump on the node's LAN tap,
   inbound only (every frame the VM emits, whatever the source MAC — a CARP address speaks from
   its virtual MAC), waits for one frame that would mean it is not inert (an ARP claiming `.1` or
   a `3.0/24` VIP, a DHCP server reply, a BGP SYN, anything sourced from `.1`/`3.0/24`, an IPv6
   RA; the CARP trial VIPs exempt — `ansible/router-nodes/group_vars/opnsense.yml`) and
   `qm stop`s the VM, then latches `onboot 0` so a host reboot does not bring it back (drift
   against tofu's `on_boot = true` — re-enabling is a reviewed apply); proven by injecting an ARP
   claim for `.1` from the node's MAC (tripped in <1 s). It is the hypervisor's
   `router-killswitch@<vmid>` unit (`ansible/pve-router-killswitch.yml`, the vmid in the host's
   `host_vars`), enabled at every host boot and ordered before `pve-guests`, so it keeps working
   when the LAN does not and stays armed while the node stands; tofu's `on_boot = true` lands in
   the change that lists the vmid;
2. **seed + first boot** — the config importer with the `standing` seed shape (LAN `.70/22`, WAN
   DHCP on `em0`'s MAC, DHCP off, ACME auto-renewal off, a LAN gateway to prod's `.1` for its own
   egress, no interface gateway on LAN so pf adds no `reply-to`) and the identity carried from the
   newest FU-013 backup (`scripts/opnsense-backup-fetch.sh`); root's API keys are exactly prod's;
3. **converge** every router play against `ansible/router-nodes/inventory.yml` with
   `opnsense_standby: true` from the first write (not `opnsense-users`: the users are carried),
   then `dnsmasq-dhcp.py` with `OPN_DHCP_ENABLE=0` and `tuya-egress.py`;
4. **check** (also its own read-only verb) — the inert rules read back over the API (LAN address,
   every HAProxy VIP on `lo0`, BGP neighbours disabled, DHCP/ddclient/ACME renewal off, the switch
   armed and never tripped) and prod unharmed (`.1` at Big Data's MAC, Unbound answering, a
   HAProxy name serving).

The window (Big Data still cabled, powered off at its start):

1. `maint open`; Big Data powered off (its LAN link drops; `.1` is free).
2. `.1` onto the pair (the CARP VIP, or a plain address on one node if the trial says the first
   step should be smaller), DHCP on; ONT → the WAN switch → the `.1` holder's WAN (only that one
   cabled — the single-lease rule).
3. Checks: WAN lease on the spoofed MAC (same public IP → ddclient no-op), BGP 13/13
   Established, a LAN DHCP lease, Unbound answering, every HAProxy name over TLS, the
   WireGuard handshake probe, the backup CronJob run by hand, the box's belts green.
4. Fallback at any failed check: `.1` off the pair, Big Data on — it never lost its config.

## Status

- 2026-09-29 night: the inventory above. Prod, the test VM baseline and the drill all on 26.7.4_1
  (#2128), plain drill score 12 → SystemHealth pinned (#2129). The rehearsal
  (`scripts/opnsense-drill.sh --router`) PASSES with every identity probe green; the numbers are in
  [`opnsense-test-vm.md`](opnsense-test-vm.md) §The router rehearsal.
- 2026-09-30: the WireGuard key carried (`wg_handshake` green), the (B) address read from the
  inventory by every jail-side shell consumer, and the rehearsal's **score 0** — the cutover
  gate's number for this shape.
- 2026-09-30: root = the wallet's `opnsense-root-password` (operator), rehearsal-proven (#2136).
- 2026-09-30: ADR-144 — the CARP pair built beside Big Data, each node standing at its own LAN IP
  (`.70` nx-02, `.71` pve), which closes the management-path fork. **Next:** the standing nx-02
  node, then pve's NIC + node, then the CARP trial.
- 2026-09-30 afternoon: the standby profile, rehearsal-proven (`--router --standby`, every inert
  rule probed). pve's WAN card FITTED: TG-3468 at `06:00.0` (`enp6s0`, `ac:a7:f1:b3:25:95`, x1
  2.5 GT/s, its own IOMMU group), unconfigured. It is the onboard port's chip too, and it took the
  onboard's bus slot; the onboard is pinned `nic0` by MAC (`pve-network-interface-pinning`), so
  `vmbr0` never follows a renumber. **Next:** the standing nx-02 node, the bridged-WAN throughput
  read, then pve's node.
- 2026-09-30 evening: bridged WAN measured (~3 Gbit/s NAT'd, #2140) → nx-02 bridged. **The nx-02
  node STANDS** (#2141): `vmbr3` + VM 9170 applied through the box in a window, `router-node.sh build
  nx02` — seeded, 26.7.5, every play converged standby, `check` green (inert rules + prod unharmed),
  kill switch armed and never tripped. **Next:** `on_boot` + a kill switch that survives an nx-02
  reboot (today: a nohup process, and the VM does not autostart — consistent, but manual after a
  host reboot), then pve's node the same way, then the CARP trial.
- 2026-09-30 night: **the nx-02 node survives a host reboot** — tofu `on_boot = true`, and the kill
  switch is a systemd unit on nx-02 (`router-killswitch@9170`, `ansible/pve-router-killswitch.yml`)
  instead of a nohup process. Trip-tested live: an injected `.1` ARP claim on the tap → tripped
  in <1 s, `onboot` latched 0, VM stopped; restored, re-booted armed without a trip, `check` 11/11
  (a new line reads the reboot survival). **Next:** pve's node (`.71`), then the CARP trial.
- 2026-09-30 night: **pve's node** coded the same shape (`tofu/opnsense-router.tf`: `vmbr3` over
  `enp6s0`, VM 9171 at `.71`, MAC `02:00:C0:A8:02:47`; `router-node.sh … pve`); pve is booked
  ~61 of 62.7 GiB with balloon off (resident ~26 GiB) — 2 GiB more is FU-289's class, accepted for
  a 2 GiB router. The kill switch now captures inbound on the tap (CARP's virtual MAC) with the
  trial VIPs exempt.
