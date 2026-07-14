---
name: opnsense-as-code
description: >
  Apply an OPNsense configuration change as code (the router @ 192.168.2.1). Use whenever the
  user wants to modify OPNsense declaratively — add/repoint a DNS host override (Unbound), add an
  HTTPS reverse-proxy entry (HAProxy), issue/renew a Let's Encrypt cert (ACME), change FRR/BGP
  peering, or edit LAN DHCP. Triggers: "add a DNS record", "expose <service> over HTTPS",
  "point <name>.teststuff.net at ...", "issue a cert for ...", "change the firewall/router".
---

# OPNsense as code

OPNsense is managed with the `oxlorg.opnsense` Ansible collection, in a **roles layout**: edit the
**config value in `ansible/group_vars/opnsense.yml`** (the logic lives in `ansible/roles/opnsense-*`),
then apply the matching playbook with the wrapper. Never click-ops it.

## Pick the value to edit (in `ansible/group_vars/opnsense.yml`) + playbook to run

| Want to... | Edit (group_vars/opnsense.yml) | Run |
|---|---|---|
| Add/repoint a LAN DNS name | `unbound_hosts` | `ansible/opnsense-unbound.yml` |
| Expose an in-cluster service as `<name>.teststuff.net` (HTTPS) | `haproxy_proxied_services` — ⚠️ acme play only CREATES the cert spec; **SIGN it before the haproxy play** (`POST /api/acmeclient/certificates/sign/<uuid>`, poll `statusCode==200`) or the frontend binds an empty cert and serves the opnsense CN (recovery = delFrontend + re-run; full order: `docs/runbook.md` §HTTPS name — bit twice, forgejo 2026-06-11 + oracle-specs 2026-07-14) | `ansible/opnsense-haproxy.yml` |
| Issue/renew a cert | `acme_cert_specs` | `ansible/opnsense-acme.yml` |
| BGP/FRR peering with Cilium | `bgp_node_ips` / ASNs | `ansible/opnsense-bgp.yml` |
| LAN DHCP (reservations, range) | — | `opnsense/dnsmasq-dhcp.py` (run `python3 opnsense/dnsmasq-dhcp.py` with OPN creds) |

To change *behaviour* (not just values), edit the role's `roles/opnsense-<x>/tasks/main.yml`.

## Apply

```bash
bash scripts/opnsense-playbook.sh ansible/opnsense-<play>.yml         # + any extra ansible args
```

The wrapper sources creds from `~/.claude/homelab-opnsense/{key,secret}`, builds the `httpx`
interpreter from `ansible/controller-env`, installs the collection if missing, and passes the
interpreter as `-e` (required — `devbox run` strips the env var).

## Gotchas (also in docs/runbook.md)

- The generic `raw` module needs `action: post` for any mutation (defaults to `get` → silent no-op).
- `unbound_host` saves but does NOT apply — the `opnsense-unbound` role's reconfigure handler flushes Unbound.
  Match on `[hostname, domain, record_type]` (exclude `value`) so a repoint updates in place.
- Verify DNS bypassing the jail's stale cache: `devbox run -- dig +short <name> @192.168.2.1`.
- HAProxy frontends must have HTTP/2 disabled (WebSocket upgrade). Each needs its own LAN IP-alias
  VIP (`.5`–`.8`) since OPNsense owns `.1:443`.
- Never iterate `/firmware/reboot` or `/poweroff` to probe endpoints — they execute.
