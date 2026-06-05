# Cloudflare — remote access design (in progress)

Goal: reach **Home Assistant from the phone, anywhere**, and move `teststuff.net` DNS to
Cloudflare. Status: **design agreed, not yet built.** This doc is the decision record; build it as
a separate tofu root `tofu/cloudflare/` (own state, like `tofu/provisioning/`).

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

## Planned `tofu/cloudflare/` contents

- Free zone for `teststuff.net`; `cf-terraforming` to import existing records after the NS cutover.
- `cloudflare_zero_trust_tunnel_cloudflared` + config (ingress `ha.teststuff.net` → in-cluster HA),
  DNS CNAME → tunnel, tunnel token → k8s secret → a `cloudflared` Deployment.
- Client-cert mTLS: Cloudflare-managed CA client cert (BYO-CA is the Enterprise gate) + per-host
  mTLS enable + the WAF custom rule (`cloudflare_ruleset`, phase `http_request_firewall_custom`).
- Confirm exact resource/permission-group names against the **Docs MCP** at build time (don't trust
  stale model memory — this initiative already produced one wrong call that the MCP caught).

## RBAC / scoped tokens

Least-privilege, per-job, never one god-token; manage tokens as IaC (`cloudflare_api_token`) with
TTL + IP filtering (pin agent/metrics tokens to the cluster egress IP):

| Token | Scope |
|---|---|
| `tofu-apply` | DNS:Edit (zone), Tunnel:Edit, + for mTLS: `Access: Mutual TLS Certificates Write`, `Access: Apps and Policies Write` |
| `agent-read` | read-only (DNS/Analytics/Zero Trust Read) — for the MCP / a future in-cluster agent |
| `metrics-read` | Analytics:Read — for `cloudflare-prometheus-exporter` (later, into the monitoring stack) |

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

## ⚠️ Migration side effect: ACME

Certs are currently issued **DNS-01 via Route53** (`ansible/opnsense-acme.yml`,
`ACME_AWS_KEY/SECRET`). Moving the zone to Cloudflare **breaks that** — swap the OPNsense
os-acme-client to the Cloudflare DNS provider (scoped CF token) or renewals silently fail.

## Cloudflare MCP

`github.com/cloudflare/mcp-server-cloudflare` — 13 Cloudflare-hosted remote servers, mostly
read-only. The **Docs** server (`https://docs.mcp.cloudflare.com/mcp`) is wired into this project
(local scope) and fixes "model too old / UI hides IaC options". No token-management server exists
(define tokens in tofu). The read servers (GraphQL, Audit Logs, CASB, DNS Analytics) aren't
self-hostable → a future headless in-cluster agent uses the scoped `agent-read` token directly.
