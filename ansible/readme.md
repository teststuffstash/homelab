# `ansible/` — OPNsense as code (+ Matchbox setup)

OPNsense (router @ `192.168.2.1`) is managed with the `oxlorg.opnsense` collection. The Matchbox
PXE host is set up by `matchbox*.yml`. There is no `site.yml`-style "apply everything" — each
concern is its own playbook.

## OPNsense playbooks

| Playbook | Manages |
|---|---|
| `opnsense-bgp.yml` | FRR/BGP peering Cilium (AS 64512 ↔ 64513), LB VIPs `192.168.40.0/24` |
| `opnsense-acme.yml` | Let's Encrypt certs (DNS-01 via Route53) for the `*.teststuff.net` names |
| `opnsense-haproxy.yml` | HTTPS reverse proxy → in-cluster service VIPs |
| `opnsense-unbound-hosts.yml` | static Unbound host overrides (e.g. `ubiquiti.teststuff.net`) |

Run them through the wrapper (handles the httpx interpreter + API creds — see `../docs/runbook.md`):

```bash
bash ../scripts/opnsense-playbook.sh ansible/opnsense-haproxy.yml
```

LAN DHCP is **not** Ansible — it's `../opnsense/dnsmasq-dhcp.py` (dnsmasq via the OPNsense API).

## Matchbox

`matchbox.yml`, `matchbox-ipxe-tftp.yml`, `matchbox-proxydhcp.yml`, `matchbox-talos-assets.yml`
set up the PXE provisioning LXC. See `../docs/provisioning.md`.

## Legacy

`roles/ubiquiti-appliance/` and the old `homelab` inventory / `sudoers.yml` target the **retired**
T61-based setup (Docker UniFi controller, netboot.xyz). The UniFi controller now runs in-cluster
(`../tofu/unifi.tf`); these are kept for reference only.
