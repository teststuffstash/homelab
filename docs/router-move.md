# The router move — Big Data → a from-git VM on nx-02

_Sub-steps 1–2 of [ROADMAP](../ROADMAP.md) §HA model step 2 (the CARP sequence); tracked on
FU-297 ([`follow-ups.md`](follow-ups.md)) — part of that item, not a new one. The proving ground
is the test VM + rebuild drill, [`opnsense-test-vm.md`](opnsense-test-vm.md); the rehearsal of THIS
move is that drill's router shape (§The router rehearsal there). Addresses: [`ip-plan.md`](ip-plan.md)._

**The move:** the router stops being the HP desktop "Big Data" (`em0` WAN, an Intel 4-port card
as LAN) and becomes a VM on `nx-02`, built from git: WAN = nx-02's `eno2` by PCI passthrough,
LAN = a virtio NIC on `vmbr0`. It keeps **`192.168.2.1`** — so the move changes no consumer's
address, and the only things that must come across are the router's **identity**. Big Data stays
cabled and powered off as the fallback for 1–2 weeks, then its card goes to `pve` (sub-step 3).
No hardware changes until the switches arrive (TL-SG1016D, hardware `purchases.md`).

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
own router-id, and `CiliumBGPAllSessionsDown` changes meaning with two peers. That is the CARP
design's work (sub-step 4), not this move's.

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

Built BEFORE the window, in isolation: the VM exactly as the rehearsal builds it, but in the
cutover shape — prod's LAN addressing (`192.168.2.1/22` — the `/22`-vs-ADR-088 question is still
the CARP ruling's, the move copies prod as it is) on the port-less bridge, no `opt9`, prod's
hostname. **Open fork — the management path of that build:** a vmbr0 management NIC cannot sit
beside a LAN that is `/22` over the same addresses (the rehearsal remaps its LAN to `1.0/24` for
exactly this reason). Options: (1) build in the rehearsal shape and change the LAN address +
drop `opt9` as the window's first act, through the API over `opt9` (one more changed thing
inside the window); (2) reach the isolated LAN through a transport on nx-02 (a veth into the
bridge in a network namespace, `socat` over ssh) and never give the VM a management NIC;
(3) give the router a permanent management interface on its own segment — the management
network ROADMAP §HA step 2 already lists (NX BMCs + the box's second NIC). **Recommendation: (3)
if the management switch lands with the WAN switch** (it is the CARP pair's need anyway, and it
removes the special case); (1) otherwise.

The window (Big Data still cabled, powered off at its start):

1. `maint open`; Big Data powered off (its LAN link drops; `.1` is free).
2. `qm set <vmid> --net0 virtio,bridge=vmbr0` — the VM's LAN onto the real LAN; ONT → the WAN
   switch → `eno2`.
3. Checks: WAN lease on the spoofed MAC (same public IP → ddclient no-op), BGP 13/13
   Established, a LAN DHCP lease, Unbound answering, every HAProxy name over TLS, the
   WireGuard handshake probe, the backup CronJob run by hand, the box's belts green.
4. Fallback at any failed check: VM off, Big Data on — it never lost its config.

## Status

- 2026-09-29 night: the inventory above. Prod, the test VM baseline and the drill all on 26.7.4_1
  (#2128), plain drill score 12 → SystemHealth pinned (#2129). The rehearsal
  (`scripts/opnsense-drill.sh --router`) PASSES with every identity probe green; the numbers are in
  [`opnsense-test-vm.md`](opnsense-test-vm.md) §The router rehearsal.
- 2026-09-30: the WireGuard key carried (`wg_handshake` green), the (B) address read from the
  inventory by every jail-side shell consumer, and the rehearsal's **score 0** — the cutover
  gate's number for this shape.
- 2026-09-30: root = the wallet's `opnsense-root-password` (operator), rehearsal-proven.
- **Operator calls still open:** the
  cutover build's management path (§The cutover).
