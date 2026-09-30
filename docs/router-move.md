# The router move — Big Data → a from-git VM on nx-02

_Sub-steps 1–2 of [ROADMAP](../ROADMAP.md) §HA model step 2 (the CARP sequence); tracked on
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

The converge of a standing node therefore needs a standby profile of the plays (group_vars
overrides, like the drill's), and a probe per bullet before it joins the LAN. CARP is learned on
the pair meanwhile with a trial VIP from `192.168.3.0/24` that prod does not hold. The WAN: pve's is a Realtek x1 card — Linux drives it, bridged on the
host (virtio into the VM, never passthrough: FreeBSD's Realtek driver and the X99 chipset slot's
IOMMU grouping both argue against it). Proposed (seat, 2026-09-30 — not yet ruled): nx-02's `eno2`
moves to the same bridged shape so the two nodes are identical; the rehearsal proves passthrough
today. The dark-WAN guard would gain the bridged variant (carrier, no host address).

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
