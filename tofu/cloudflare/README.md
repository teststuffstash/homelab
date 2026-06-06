# tofu/cloudflare

Remote access to **Home Assistant** over a Cloudflare Tunnel, gated by **mTLS** (client
certificate), all as code. Separate root + state (like `tofu/provisioning/`). Design record:
[`docs/cloudflare.md`](../../docs/cloudflare.md).

Provider: `cloudflare/cloudflare` **v5** (pinned 5.19.x). The v5 rewrite renamed/restructured
most resources — everything here was validated against the v5 schema.

## What it builds

```
              phone (.p12 client cert)
                     │  https://ha.teststuff.net
                     ▼
      Cloudflare edge ── TLS+mTLS validate ── WAF: block if !cert_verified
                     │  (proxied CNAME -> <tunnel>.cfargotunnel.com)
                     ▼
   cloudflared Deployment (ns cloudflared, 2 replicas, outbound-only)
                     │  http://home-assistant.home-assistant.svc:8123
                     ▼
              Home Assistant
```

| File | Resources |
|---|---|
| `tunnel.tf` | remotely-managed tunnel + ingress config + connector token (data source) |
| `cloudflared.tf` | k8s namespace/secret/deployment running the connector in-cluster |
| `dns.tf` | `ha` CNAME → tunnel (proxied); `*.local` A → 127.0.0.1 (DNS-only, work envs) |
| `mtls.tf` | client key+CSR (`tls`), CF managed-CA signs it, per-host mTLS enable, WAF enforce rule |
| `outputs.tf` | tunnel id, `ha_url`, client cert/key (sensitive), `make_p12_command` |

## Prereqs

1. `teststuff.net` is on Cloudflare and **Active** (NS cutover done — it is).
2. The scoped write token exists (`tofu/cloudflare-token/`) and is saved at
   `~/.claude/cloudflare/write-key`.
3. `tofu/kubeconfig` exists (the main root writes it) — the connector Deployment needs it.

## Apply

```bash
export CLOUDFLARE_API_TOKEN=$(cat ~/.claude/cloudflare/write-key)
devbox run -- tofu -chdir=tofu/cloudflare init
devbox run -- tofu -chdir=tofu/cloudflare plan      # review first — always
devbox run -- tofu -chdir=tofu/cloudflare apply
```

Then build the phone certificate (pinned openssl, explicit algorithms, non-interactive):

```bash
bash scripts/make-client-p12.sh
# -> ~/.claude/cloudflare/ha-client.p12 (+ .password, .cert.{pem,der,txt})
# install the .p12 on the phone, then open https://ha.teststuff.net
```

The key + CSR are from the pinned `hashicorp/tls` provider and the leaf is signed by
Cloudflare's managed CA — **openssl never generates the cert**, it only wraps the PKCS#12,
with explicit AES-256-CBC/SHA256 (not openssl defaults, which drift and have broken mTLS
imports). The `.p12` isn't byte-reproducible (random salt); diff the cert via the `.der` on
<https://lapo.it/asn1js>.

## After apply — the ACME side effect

Moving the zone to Cloudflare breaks the OPNsense DNS-01 (Route53) cert renewals. Swap the
OPNsense ACME provider to Cloudflare (scoped token) or LAN certs silently lapse — see
`docs/cloudflare.md` and `ansible/opnsense-acme.yml`. **Not handled by this root.**

## Notes

- `*.local` is DNS-only (grey cloud); the mTLS/WAF only touch the proxied `ha` host.
- The hostname-association resource is a per-zone singleton — it manages the managed-CA host
  list for the whole zone (currently just `ha`).
- HA's own login + TOTP stays on as a second factor behind the client cert.
