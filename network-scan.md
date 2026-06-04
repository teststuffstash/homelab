# Home network — discovered state

**Scan date:** 2026-05-22 ~19:25 UTC
**Performed by:** Claude Code, autonomously, from inside the Docker jail.

> This documents what was **observed on the wire**, not what *should* exist.
> Where I'm inferring a device's role rather than confirming it, it's marked
> _(inferred)_. Compare against [`README.md`](README.md) / [`CLAUDE.md`](CLAUDE.md)
> for intended layout — discrepancies are listed at the bottom.

## How this was gathered (and its limits)

- Vantage point: the Claude container (`172.18.0.5/16`), reaching the LAN through
  the Docker bridge → host → `192.168.2.0/24`. So everything is seen at **layer 3
  through NAT**.
- **No MAC addresses / OUI vendor IDs** — ARP doesn't cross the NAT boundary, so
  device identification relies on reverse-DNS, open ports, and service banners.
- Discovery used ICMP + TCP SYN/ACK probes (`nmap -sn`), then `nmap -sS -sV` on a
  curated port set, plus `curl`/`openssl`/`nc` banner grabs.
- "Offline" below means *unreachable at scan time* — a host could simply be
  powered off (this is a homelab; the 3D printer etc. aren't always on).
- DNS resolver in use: OPNsense **Unbound 1.22.0** at `192.168.2.1`, search
  domain `teststuff.net`.

## Topology at a glance

```
Internet ── WAN 176.46.101.184 ──┐
                                  │  (exposes 53/80/443 — see Security notes)
                          ┌───────┴────────┐
                          │  OPNsense .1    │  router / firewall / DNS / web GUI
                          └───────┬────────┘
                                  │  LAN 192.168.2.0/24
   ┌──────────────┬──────────────┼───────────────┬──────────────────────┐
   │              │              │               │                       │
 Pop!_OS host   ESPHome node   5× embedded     (T61 .2  ──┐         (OctoPi ──┐
 .10 / .57      .245           Dropbear devices  offline) │          offline) │
 HA+ESPHome+    (ESP32)        .11 .12 .14       ─────────┘         ──────────┘
 jail :8000                    .63 .93 (likely UniFi)
```

## Host inventory

| IP | Hostname (PTR) | Role | Open ports (observed) | Confidence |
|---|---|---|---|---|
| `192.168.2.1` | OPNsense.teststuff.net | **Router / firewall / DNS / web GUI** | 53 (Unbound 1.22.0), 80→301 https (Server: OPNsense), 443 (OPNsense GUI) | Confirmed |
| `192.168.2.10` & `.57` | pop-os | **Main Pop!_OS host** — runs this Docker jail + homelab services | 6052 (ESPHome dashboard, Tornado), 8000 (jail upload server, Python BaseHTTPServer), 8123 (Home Assistant, aiohttp) | Confirmed |
| `192.168.2.245` | — | **ESPHome device** (ESP32 — the `droplet`?) | 6053 (ESPHome native API) | High |
| `192.168.2.11` | — | Embedded Linux _(likely UniFi AP)_ | 22 (Dropbear 2022.83) | Inferred |
| `192.168.2.12` | — | Embedded Linux _(likely UniFi AP)_ | 22 (Dropbear 2024.86), 8080 (TLS, self-signed CN=localhost, 404) | Inferred |
| `192.168.2.14` | — | Embedded Linux _(likely UniFi AP)_ | 22 (Dropbear 2022.83) | Inferred |
| `192.168.2.63` | — | Embedded Linux _(likely UniFi AP)_ | 22 (Dropbear 2024.86), 8080 (TLS, self-signed, 404) | Inferred |
| `192.168.2.93` | — | Embedded Linux _(likely UniFi AP, older fw)_ | 22 (Dropbear 2019.78) | Inferred |
| `192.168.2.16/.17/.26/.70/.80/.84/.87` | — | Live but no scanned TCP port open — **client devices** (phones/laptops/IoT) | — | Low |
| `192.168.2.2` | ubiquiti.teststuff.net | **T61 — appears OFFLINE** (no ICMP, no open port in top-1000) | none reachable | — |

## Notable per-host detail

### `192.168.2.1` — OPNsense router
- Web GUI confirmed: `Server: OPNsense`, `<title>Login | OPNsense</title>`, HTTP/2,
  CSP + HSTS headers present. HTTP/80 301-redirects to HTTPS.
- Runs **Unbound 1.22.0** as the LAN DNS resolver.
- This is the HP desktop per `CLAUDE.md`.

### `192.168.2.10` / `192.168.2.57` — the Pop!_OS host (one machine, two IPs)
- Both addresses show **identical** services and ~0 ms latency → almost certainly
  the **same dual-homed machine** (wired + Wi-Fi), and it's the box running this
  scan's host.
- It is **the homelab Docker host**: port `8000` is the jail's own upload server
  (`tools/upload/upload.py`, Python `BaseHTTPServer`), and it runs the repo's
  compose services — **Home Assistant** (`:8123`) and the **ESPHome dashboard**
  (`:6052`).
- Note: **two reachable Home Assistant instances exist** (`:8123` on both IPs) —
  this is the one HA bound to both interfaces, not two installs.

### `192.168.2.245` — ESPHome node
- Port `6053` open = ESPHome **native API** (what Home Assistant connects to).
  Consistent with the `droplet` ESP32 in `esphome/config/`.

### The five Dropbear devices (`.11 .12 .14 .63 .93`)
- All expose only Dropbear SSH (versions 2019.78 → 2024.86 — a spread of firmware
  ages). `.12` and `.63` additionally serve TLS on `8080` with a self-signed
  `CN=localhost` cert returning HTTP 404.
- This fingerprint (Dropbear + minimal/localhost TLS) is typical of **Ubiquiti
  UniFi access points / switches**, which matches the homelab having UniFi gear.
  Marked _inferred_ because I can't read MAC OUIs across NAT to confirm.

## Security observations

1. **WAN exposure on `176.46.101.184`** (the public IP `opnsense.teststuff.net`
   resolves to). External top-200 scan found **open**:
   - `53/tcp` — **Unbound DNS exposed to the internet.** If it answers recursive
     queries from outside, it's an **open resolver** (DNS-amplification abuse risk).
     Worth verifying the ACL and closing 53 on WAN if not intentional.
   - `80/tcp` and `443/tcp` — web exposed to the internet. If this is the OPNsense
     GUI, it should not be WAN-reachable; if it's a reverse proxy, fine, but
     confirm what's behind it.
2. **Split-horizon DNS** is in play: `opnsense.teststuff.net` returns both the LAN
   IP (`192.168.2.1`) and the public IP — expected, just noting it.
3. Internal services (HA `:8123`, ESPHome `:6052/:6053`, jail upload `:8000`) are
   plain HTTP on the LAN. Fine for a trusted LAN; relevant only if the LAN isn't trusted.

## Discrepancies vs the documented layout

- **`README.md` Telia/WAN row is stale** — confirmed earlier; the WAN is now the
  `176.46.101.184` block via OPNsense.
- **T61 (`192.168.2.2`, `ubiquiti.teststuff.net`) is unreachable** — no ICMP and
  no open port in the top-1000. Either powered off or fully firewalled.
- **No UniFi controller found anywhere** — nothing on the LAN serves `:8443`
  (scanned the whole `/24`). The `ansible/ubiquiti-appliance` role deploys the
  controller, but it isn't currently running/reachable. The UniFi APs (the Dropbear
  devices) appear to be operating on last-known config without an active controller.
  - **Update 2026-06-04:** controller migrated to the in-cluster UniFi Network
    Application (`tofu/unifi.tf`) on the BGP VIP `192.168.40.12`; all APs + the
    USW-Lite re-adopted there. `ubiquiti.teststuff.net` was a legacy, *untracked*
    OPNsense Unbound host override pointing at the dead T61 — now captured as IaC in
    `ansible/opnsense-unbound-hosts.yml` and repointed to `192.168.40.12`. T61 retired.
- **OctoPi / Raspberry Pi 3B not seen** — no host exposes OctoPrint (`:80/:5000`).
  Consistent with the 3D printer being off.
- The dual-homed Pop!_OS host (`.10/.57`) running the homelab stack isn't described
  in the docs' host tables at all.

## Appendix — methodology

```bash
# host discovery
sudo nmap -sn -n -PE -PS22,80,443,8443,3000 -PA80,443 192.168.2.0/24
# service/version scan (curated ports)
sudo nmap -sS -sV --version-light -n -Pn -T4 -p 22,53,80,443,3000,6052,6053,8000,8080,8123,8443,... --open <hosts>
# WAN exposure
sudo nmap -sS -sV -Pn -T4 --top-ports 200 --open 176.46.101.184
# banners / certs
nc -w3 <ip> 22 ; curl -sk https://<ip>:8080/ ; openssl s_client -connect <ip>:8080
```

Tools (`nmap`, `dnsutils`, `iproute2`, `netcat`, `arp-scan`, `avahi-utils`) were
installed in-session via `sudo apt-get` — they do **not** persist across a
container rebuild.
