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

OPNsense is managed with the `oxlorg.opnsense` Ansible collection. Never click-ops it — find the
right playbook, edit it, and apply with the wrapper.

## Pick the playbook

| Want to... | Edit | 
|---|---|
| Add/repoint a LAN DNS name | `ansible/opnsense-unbound-hosts.yml` (`unbound_hosts` list) |
| Expose an in-cluster service as `<name>.teststuff.net` (HTTPS) | `ansible/opnsense-haproxy.yml` (`proxied_services`) — and add the cert in `opnsense-acme.yml` first |
| Issue/renew a cert | `ansible/opnsense-acme.yml` (`cert_specs`) |
| BGP/FRR peering with Cilium | `ansible/opnsense-bgp.yml` |
| LAN DHCP (reservations, range) | `opnsense/dnsmasq-dhcp.py` (run `python3 opnsense/dnsmasq-dhcp.py` with OPN creds) |

## Apply

```bash
bash scripts/opnsense-playbook.sh ansible/opnsense-<play>.yml         # + any extra ansible args
```

The wrapper sources creds from `~/.claude/homelab-opnsense/{key,secret}`, builds the `httpx`
interpreter from `ansible/controller-env`, installs the collection if missing, and passes the
interpreter as `-e` (required — `devbox run` strips the env var).

## Gotchas (also in docs/runbook.md)

- The generic `raw` module needs `action: post` for any mutation (defaults to `get` → silent no-op).
- `unbound_host` saves but does NOT apply — the playbook's reconfigure handler flushes Unbound.
  Match on `[hostname, domain, record_type]` (exclude `value`) so a repoint updates in place.
- Verify DNS bypassing the jail's stale cache: `devbox run -- dig +short <name> @192.168.2.1`.
- HAProxy frontends must have HTTP/2 disabled (WebSocket upgrade). Each needs its own LAN IP-alias
  VIP (`.5`–`.8`) since OPNsense owns `.1:443`.
- Never iterate `/firmware/reboot` or `/poweroff` to probe endpoints — they execute.
