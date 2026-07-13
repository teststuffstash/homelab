# IP plan — partitioning 192.168.0.0/16

_Decision: [`adr.md`](adr.md) ADR-088 (2026-07-13). Physical topology:
[`network-physical.md`](network-physical.md). Per-service VIP/hostname assignments:
[`/SERVICES.md`](../SERVICES.md). Machine inventory: [`/machines/`](../machines/)._

The whole `192.168.0.0/16` is ours to partition. The historical pattern — one `/24`, first ten
addresses static, everything ad hoc — produced two live ARP collisions (a HAProxy VIP on the
Matchbox LXC's address, another on the Docker host; 2026-07-13). The plan below gives every
address class its own room to grow and one hard rule to prevent that bug class forever.

## The one hard rule

**A virtual IP never lives inside a real-host range, and a real host never lives inside a VIP
range.** Real machines get an inventory entry (`machines/machines.yaml` or a
`opnsense/dnsmasq-dhcp.py` static) *before* they get an address; VIPs come only from the two VIP
blocks below. Before any assignment: `git grep <ip>` + `nmap -sn <candidates>`.

## The partition

| Block | CIDR | Size | Purpose |
|---|---|---|---|
| `192.168.0.0/24` | /24 | 254 | **Never use** — consumer-router default, collision bait on double-NAT/guest gear. |
| `192.168.1.0/24` | /24 | 254 | **Reserved, legacy** — the old Telia-router subnet; upstream kit may still assume it. |
| `192.168.2.0/24` | /24 | 254 | **Infra LAN (live, frozen map)** — `.1` OPNsense · `.2–.49` legacy static/VIP mix (no NEW VIPs here) · `.51–.99` cluster nodes & servers · `.100–.245` DHCP pool. |
| `192.168.3.0/24` | /24 | 254 | **Router-owned service VIPs** (OPNsense HAProxy IP aliases). Never a real host, so ARP collision is impossible by construction. Convention: **last octet mirrors the backend's cluster VIP** (`.3.19` → `.40.19`). |
| `192.168.4.0/22` | /22 | 1022 | **IoT VLAN** — the ESP32-per-radiator/valve endgame (“couple hundred, definitely < 1000”). |
| `192.168.8.0/24` | /24 | 254 | **Guest VLAN** (wifi-password → VLAN steering; firewalled off `2.0/24`, `3.0/24`, `32.0/19`). |
| `192.168.9.0/24` | /24 | 254 | **Lab / DMZ VLAN.** |
| `192.168.10.0/24`–`15.0/24` | 6×/24 | — | Future VLANs (one subnet per SSID/segment as the wifi-VLAN plan lands). |
| `192.168.16.0/20` | /20 | 4094 | **Physical expansion** — new machine subnets when `2.0/24` fills; carve /24s from the bottom. |
| `192.168.32.0/19` | /19 | 8190 | **Cluster BGP service VIPs** (Cilium LBIPAM, routed — this is where “no upper bound” growth belongs). Contains the live `192.168.40.0/24` pool. Per-stack isolation later = one /24 pool per stack carved from here (composable via the agentstack claim); **not yet** — the single shared `40.0/24` stays until a stack actually needs its own pool/policy. |
| `192.168.64.0/18` | /18 | 16382 | **Routed-virtual overflow** — more BGP pools, VPN client ranges, whatever routes rather than ARPs. |
| `192.168.128.0/17` | /17 | 32766 | **Unallocated** — half the /16 untouched on purpose. |

## Why the shape

- **Physical vs virtual scale differently.** Physical tops out ~1000 (house fully sensored) and
  each device ARPs on an L2 segment → per-VLAN /24–/22 subnets. Virtual/service IPs are
  *routed* (BGP) or router-owned aliases — no ARP, no L2 constraint → give them the big blocks
  (`/19` + `/18` ≈ 24k addresses) where "thousands of statics" costs nothing.
- **Router-owned VIPs outside the host subnet** (`3.0/24`): OPNsense carries the alias, LAN
  clients reach it via their default gateway — one extra hop through the router that HAProxy
  traffic takes anyway. Validated live with the transcripts VIP (2026-07-13).
- **VLAN plan fits without touching this table:** each new SSID/VLAN takes the next subnet from
  the VLAN blocks; DHCP pool top-half, statics bottom-half, same as `2.0/24` today.
- **Existing `2.0/24` VIPs** (`.2`–`.29`: ha, grafana, prometheus, alertmanager, forgejo,
  garage-s3, argocd, infisical) migrate to `3.0/24` opportunistically (FU-071) — new exposures
  land in `3.0/24` from day one. The haproxy role rebinds on VIP change; stale aliases + Unbound
  overrides need the API cleanup (see `ansible/group_vars/opnsense.yml` header).
