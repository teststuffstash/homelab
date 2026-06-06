# Cloudflare — remote access design (in progress)

Goal: reach **Home Assistant from the phone, anywhere**, and move `teststuff.net` DNS to
Cloudflare. Status: **LIVE (applied + verified 2026-06-06).** NS cutover done; both tofu roots
applied; tunnel healthy; `https://ha.teststuff.net` returns **403 without a client cert** (mTLS +
WAF enforcing) and tunnels to HA with the cert. Phone `.p12` built at `~/.claude/cloudflare/
ha-client.p12` (password in the sibling `.password` file). Remaining: install the `.p12` on the
phone + swap OPNsense ACME Route53→Cloudflare (LAN cert renewals break until then). This doc is the decision record. Two separate roots (own state, like
`tofu/provisioning/`): `tofu/cloudflare-token/` (mints the scoped write token, applied once with
an admin token) and `tofu/cloudflare/` (the infra, applied with that scoped token). See each
root's `README.md` for the apply runbook.

Live IDs: account `07b08646b26bb43cd3073826f43b73da`, zone `teststuff.net` =
`6b63f95592a9e036f8b8f6934511d321` (Free plan, **active**).

## Decisions

- **Transport: Cloudflare Tunnel** (`cloudflared`, outbound-only) → in-cluster HA. No WAN
  port-forward, hides the home IP, works behind CGNAT.
- **Auth: mTLS via Application-Security / SSL Client Certificates** (NOT Cloudflare Access).
  The phone gets a client `.p12` installed (Android: *Settings → Install a certificate → VPN & app
  user certificate*); it's presented at the TLS handshake, so the **HA companion app works** (no
  interactive login to choke on). HA's own login + TOTP stays on as a second factor.
- **IaC: OpenTofu + the official `cloudflare/cloudflare` provider** — NOT Crossplane (those CF
  providers are community/Upbound-generated, lag the TF provider on Zero-Trust/Tunnel). Pin the
  provider — v5 was rewritten from the OpenAPI spec and renamed Zero-Trust resources.

## Why mTLS-at-the-WAF, not Access (the key correction)

Cloudflare has **two** mTLS mechanisms:
1. **Cloudflare Access mTLS** — part of Zero Trust, **Enterprise-only**. Not available on this
   account (Zero Trust = "Teams Free Base"; the Pro zone plan is on a *different* domain).
2. **Application-Security / SSL Client-Certificate mTLS** — validated at the **TLS handshake + WAF**
   layer, independent of Access, **available on the Free zone plan** (Cloudflare-managed CA is
   account-level; only *BYO-CA* needs Enterprise; WAF custom rules exist on Free).

We use **(2)**. So `teststuff.net` on the **Free** zone plan is fine — don't buy Pro for it.

## Request chain for the tunneled app

For a proxied hostname `ha.teststuff.net` served via Tunnel:

1. L3/L4 DDoS drop.
2. **TLS termination** — mTLS enabled for the host → Cloudflare requests the client cert, validates
   it against the uploaded CA, and *records* the result in `cf.tls_client_auth.*` (it does **not**
   block here).
3. **Rules pipeline** (account rulesets before zone): Config/Transform → IP Access → **WAF Custom
   Rules = mTLS ENFORCEMENT** (`(http.host in {"ha.teststuff.net"} and not
   cf.tls_client_auth.cert_verified)` → Block) → rate-limiting → managed rules (Pro+).
4. Cache (HA is dynamic, passes through).
5. **Cloudflare Access** — only if an Access app exists; we create none → skipped.
6. **Tunnel egress** via `cloudflared` → in-cluster HA.
7. HA applies its own login + TOTP.

mTLS lives at steps 2 (validate) + 3 (enforce). CNAME gotcha: enable mTLS on the **specific
hostname**, not the CNAME target.

## What `tofu/cloudflare/` actually contains (built 2026-06-06, v5)

The zone imported **zero** records (clean slate) — so we build all records, no `cf-terraforming`.
v5 resource names (verified against the provider's GitHub docs, then `tofu validate`d):

- `cloudflare_zero_trust_tunnel_cloudflared` (`config_src = "cloudflare"`, remotely-managed) +
  `cloudflare_zero_trust_tunnel_cloudflared_config` (config is an **object**: `config = { ingress
  = [...] }`, not v4 `ingress_rule {}` blocks) + `data.…_cloudflared_token` (`.token`).
- **The tunnel resource has no `.cname` in v5** — the DNS target is
  `${tunnel.id}.cfargotunnel.com`. `cloudflare_dns_record` uses `content` (not `value`):
  `ha` CNAME → tunnel (proxied), `*.local` A → 127.0.0.1 (DNS-only).
- mTLS: `tls_private_key` + `tls_cert_request` → `cloudflare_client_certificate` (zone managed-CA
  signs the CSR) + `cloudflare_certificate_authorities_hostname_associations` (no
  `mtls_certificate_id` ⇒ managed CA; **per-zone singleton**) + `cloudflare_ruleset` (zone,
  `http_request_firewall_custom`, **list** `rules = [{…}]`) enforcing
  `(http.host eq "ha.teststuff.net" and not cf.tls_client_auth.cert_verified)` → block.
- k8s: `cloudflared` namespace/secret/Deployment (2 replicas, image **digest-pinned** 2026.5.2,
  `TUNNEL_TOKEN` from the secret).
- `.p12` for the phone is produced from two sensitive outputs via the `make_p12_command` output.

> Lesson confirmed: don't trust stale model memory for CF v5 — the GitHub provider docs + a
> credential-free `tofu validate` caught every renamed resource/attribute before any apply.

## Rollout gotchas (hit + fixed 2026-06-06)

Two stacked bugs after the first apply, worth remembering:

1. **502, cloudflared dialing `127.0.0.1`.** The connector pod's `resolv.conf` has
   `search … teststuff.net` + `ndots:5`, so the Go resolver appended search domains to the
   origin FQDN `home-assistant.home-assistant.svc.cluster.local` → tried
   `…svc.cluster.local.teststuff.net`, which **matches the `*.local.teststuff.net → 127.0.0.1`
   wildcard** (the name ends in `.local.teststuff.net`). cloudflared took that first answer and
   dialed loopback. Fix: a **trailing dot** on the origin host (`…svc.cluster.local.:8123`) →
   absolute name, no search expansion. ⚠️ This is a cluster-wide landmine: any client using a
   full `.cluster.local` name *without* a trailing dot can hit the wildcard.
2. **400, "reverse proxy not configured".** HA rejects requests carrying `X-Forwarded-For`
   unless trust is configured. cloudflared sends XFF; the LAN HAProxy path does **not**, which
   is why HAProxy worked with no `http:` block. Fix: `http.use_x_forwarded_for: true` +
   `trusted_proxies: [10.244.0.0/16]` (cluster pod CIDR) in `homeassistant/ha-config/
   configuration.yaml`. `http` only loads at startup → needs a full HA restart, not a reload.
3. **Client-side: `ERR_NAME_NOT_RESOLVED` on mobile after the record was created.** The phone
   had cached the pre-existence NXDOMAIN for the mobile network; Chrome masked it (it uses DoH),
   but the HA app's WebView uses the system resolver and kept failing. Force-stopping the app
   doesn't clear the *system* DNS cache — **toggle airplane mode** (or reboot) to flush it. Not
   an infra issue. (Persistent carrier-DNS failures: set Private DNS to `dns.google`.)
4. **The HA companion app has two URLs.** Internal (used on the home WiFi SSID) should stay
   `homeassistant.teststuff.net` (LAN HAProxy, no tunnel hop); External must be
   `https://ha.teststuff.net` (the tunnel). `homeassistant.teststuff.net` is LAN-only (NXDOMAIN
   off-LAN), so an External URL pointed at it works on WiFi and dies on mobile.

## RBAC / scoped tokens

Least-privilege, per-job, never one god-token; manage tokens as IaC (`cloudflare_api_token`) with
TTL + IP filtering (pin agent/metrics tokens to the cluster egress IP):

| Token | Scope | Status |
|---|---|---|
| `homelab-tofu-apply` | zone policy: `DNS Write` + `SSL and Certificates Write` + `Zone WAF Write` (scoped to the teststuff.net zone); account policy: `Cloudflare Tunnel Write`. Minted by `tofu/cloudflare-token/`. | **built** |
| `read-key` | account-wide read-only (created in dashboard) — used to inventory the zone during the build; lives at `~/.claude/cloudflare/read-key`. | live |
| `agent-read` | read-only (DNS/Analytics/Zero Trust Read) — for the MCP / a future in-cluster agent | planned |
| `metrics-read` | Analytics:Read — for `cloudflare-prometheus-exporter` (later, into the monitoring stack) | planned |

Note: mTLS here is **API-Shield / SSL Client-Certificate** (managed CA), so the write token needs
`SSL and Certificates Write` — **not** the `Access: Mutual TLS …` groups (those are the Enterprise
Access path we deliberately avoided). The earlier draft of this table was wrong on that point.

## Route53 → Cloudflare: record decisions (2026-06-05)

Don't import the old Route53 zone — start clean on Cloudflare with only what's live:

| Record | Decision |
|---|---|
| `*.local.teststuff.net` A → 127.0.0.1 | **KEEP** — used at work for local envs with self-signed TLS; recreate on CF. |
| `ha.teststuff.net` (new) | **ADD** — CNAME → the Cloudflare Tunnel. |
| `burger` / `rancher` (→ internal .2.3) | DELETE — dead, and internal-IP leak. |
| `sdg-playwright-traces` + its `_*` validation CNAMEs | DELETE — old work project; its 1-yr paid cert can lapse. |
| `folderit` (37.0.31.4) + ACM validation | DELETE — project retired. |
| `vis-csp` ACM validation | DELETE. |
| NS / SOA | N/A — Cloudflare provides its own once the registrar NS point at CF. |

Cleanup of the Route53 zone + the associated **ACM/Sectigo certs** (the `_*` validation CNAMEs
imply leftover ACM certificates) is the first job for the AWS-IaC track (`tofu/aws/`), done as a
reviewable delete-diff after a read-only audit. See [[cloudflare-direction]] and the AWS auth notes.

## The nameserver cutover (one-time, manual) — ✅ DONE

`teststuff.net` now resolves on Cloudflare (zone **active**, Free plan). Historical mechanics:
`teststuff.net` is **registered at AWS Route53 Domains** (as are `eid-demo.com` + `taranortaltest.net`).
So the NS change is done there: **Route53 Domains → Registered domains → teststuff.net → Edit name
servers** → replace the four `awsdns` NS with Cloudflare's two. `eid-demo.com` already shows the
target state (`benedict`/`paris.ns.cloudflare.com`). Keep teststuff.net's **auto-renew ON** (expires
2026-08-16, mid-migration). After cutover the Route53 hosted zone for teststuff.net is orphaned
(like eid-demo.com's) and can be deleted. AWS cruft cleanup (S3/ACM/CloudMap/old zones) was done
2026-06-05 via `scripts/aws-cleanup-legacy.sh`.

## ⚠️ Migration side effect: ACME — swap coded, apply pending

Certs were issued **DNS-01 via Route53**; the NS move **breaks that** (LE queries the
authoritative NS = now Cloudflare). The swap is now **in code**, pending apply:

- **Token:** `tofu/cloudflare-token/acme-dns.tf` mints `homelab-acme-dns` (Zone:Read + DNS:Edit
  on teststuff.net only) → output `acme_dns_token`.
- **OPNsense:** `ansible/opnsense-acme.yml` now uses `dns_service: dns_cf` — it **repoints the
  existing `aws-acme` validation in place** (backend `dns_aws → dns_cf`), so the 5 certs that
  bind to that name need no change. Token via `ACME_CF_TOKEN` env; account/zone IDs are vars.

Apply order:
```bash
# 1. (outside jail, admin token) mint + save the scoped ACME token
export CLOUDFLARE_API_TOKEN=$(cat ~/.claude/cloudflare/admin-key)
tofu -chdir=tofu/cloudflare-token apply
tofu -chdir=tofu/cloudflare-token output -raw acme_dns_token \
  > ~/Projects/.claude-data/cloudflare/acme-token && chmod 600 $_
# 2. (jail) swap the validation backend
export ACME_CF_TOKEN=$(cat ~/.claude/cloudflare/acme-token)
bash scripts/opnsense-playbook.sh ansible/opnsense-acme.yml
# 3. force one re-issue in the OPNsense GUI (or acmeclient) to confirm DNS-01 via Cloudflare,
#    then the rest renew on schedule.
```

## Cloudflare MCP

`github.com/cloudflare/mcp-server-cloudflare` — 13 Cloudflare-hosted remote servers, mostly
read-only. The **Docs** server (`https://docs.mcp.cloudflare.com/mcp`) is wired into this project
(local scope) and fixes "model too old / UI hides IaC options". No token-management server exists
(define tokens in tofu). The read servers (GraphQL, Audit Logs, CASB, DNS Analytics) aren't
self-hostable → a future headless in-cluster agent uses the scoped `agent-read` token directly.
