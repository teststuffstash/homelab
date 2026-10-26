# tofu/cloudflare

The **credential half** of Home Assistant's mTLS remote access, the platform zone's non-route DNS
records, and the **minutark.ee product-zone bootstrap** — as code. Separate root + encrypted remote
state in Garage since 2026-08-04 (`backend.tf`; creds/runbook:
[`docs/tofu-state.md`](../../docs/tofu-state.md)). Design record:
[`docs/cloudflare.md`](../../docs/cloudflare.md).

**This root carries no dependency pin a running thing consumes** (since 2026-10-26). The
`ha.teststuff.net` tunnel, connector (`cloudflared`), CNAME and mTLS enforcement rule are the
PublicRoute claim `home-assistant/ha` (`argocd/resources/ha-publicroute/`, FU-039 consumer #2) —
reconciled by ArgoCD + Crossplane, so a Renovate cloudflared bump deploys on merge. They left this
root because its pin sat 11 days behind a Cloudflare security notice: an applied-by-hand root is
no deploy edge (docs/dependency-upgrades.md, G16 resight). What stays is credential/singleton
class that the composition's token cannot write (SSL/Certificates).

Provider: `cloudflare/cloudflare` **v5** (`~> 5.0`; the exact version is `.terraform.lock.hcl`'s). The v5 rewrite renamed/restructured
most resources — everything here was validated against the v5 schema.

## What it builds

```
              phone (.p12 client cert — the key/CSR here, signed by the zone's managed CA)
                     │  https://ha.teststuff.net
                     ▼
      Cloudflare edge ── TLS+mTLS validate (hostname association: HERE)
                     │   WAF: block if !cert_verified        (the ha PublicRoute claim)
                     ▼
   tunnel + cloudflared (ns home-assistant, 2 replicas)     (the ha PublicRoute claim)
                     ▼
              Home Assistant
```

| File | Resources |
|---|---|
| `mtls.tf` | client key+CSR (`tls`), CF managed-CA signs it, the zone's managed-CA hostname association (per-zone singleton) — the credential half |
| `dns.tf` | `*.local` A → 127.0.0.1 (DNS-only, work envs); `wg` A (WireGuard endpoint — tofu owns existence, ddclient the content) |
| `removed.tf` | the `ha` CNAME + mTLS ruleset FORGOTTEN (not destroyed) at the retrofit — the claim adopted them |
| `outputs.tf` | `ha_url`, client cert/key (sensitive), `make_p12_command` |
| `minutark.tf` | minutark.ee product-zone bootstrap — hygiene records, TLS 1.2 floor, always-HTTPS, DNSSEC (oracle-iac#351) |

The `kubernetes` provider is still configured (`providers.tf`): the retrofit's apply needed it to
destroy the old connector, and after that it manages nothing (dropping it is a `providers.tf` /
`versions.tf` edit — a denied path for the [management box](../../docs/management-box.md)'s PR lane, so operator-direct).

## Prereqs

1. `teststuff.net` is on Cloudflare and **Active** (NS cutover done — it is).
2. The scoped write token exists (`tofu/cloudflare-token/`) and is saved at
   `~/.claude/cloudflare/write-key`.
3. `tofu/kubeconfig` exists (the main root writes it) — the configured kubernetes provider reads it.

## Apply

```bash
source scripts/keepass-env.sh   # exports CLOUDFLARE_API_TOKEN (wallet: cloudflare-write-key)
TOFU_STATE_ROOT_DIR=$PWD/tofu/cloudflare . scripts/tofu-state-env.sh   # Garage backend creds
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

## The ACME side effect (done)

Moving the zone to Cloudflare broke the OPNsense DNS-01 (Route53) cert renewals; OPNsense ACME
is DNS-01 via Cloudflare now (scoped token — `ansible/opnsense-acme.yml`, `docs/cloudflare.md`).
**Not handled by this root.**

## Notes

- `*.local` is DNS-only (grey cloud); the mTLS/WAF only touch the proxied `ha` host.
- The hostname-association resource is a per-zone singleton — it manages the managed-CA host
  list for the whole zone (currently just `ha`). It must exist for the claim's mTLS rule to admit
  anyone: without it the edge never requests a certificate and every request is blocked.
- HA's own login + TOTP stays on as a second factor behind the client cert.
