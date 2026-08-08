# Cloudflare — remote access (live)

Goal: reach **Home Assistant from the phone, anywhere**, and move `teststuff.net` DNS to
Cloudflare. Status: **LIVE & verified (2026-06-06).** NS cutover done; both tofu roots applied;
tunnel healthy; `https://ha.teststuff.net` returns **403 without a client cert** (mTLS + WAF
enforcing) and serves HA **with** the cert — confirmed from the phone on mobile data. The phone
`.p12` is at `~/.claude/cloudflare/ha-client.p12`; OPNsense ACME has been swapped to Cloudflare
DNS-01 and a real renewal verified. **Only open item:** delete the orphaned Route53 hosted zone
(see "nameserver cutover" below).

This doc is the design + decision/gotcha record; the *why* (options considered) is condensed in
[`adr.md`](adr.md) (ADR-050…054). Two separate roots (own state, like
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
reviewable delete-diff after a read-only audit. See the AWS auth notes.

## The nameserver cutover (one-time, manual) — ✅ DONE

`teststuff.net` now resolves on Cloudflare (zone **active**, Free plan). Historical mechanics:
`teststuff.net` is **registered at AWS Route53 Domains** (as are `eid-demo.com` + `taranortaltest.net`).
So the NS change is done there: **Route53 Domains → Registered domains → teststuff.net → Edit name
servers** → replace the four `awsdns` NS with Cloudflare's two. `eid-demo.com` already shows the
target state (`benedict`/`paris.ns.cloudflare.com`). Keep teststuff.net's **auto-renew ON** (expires
2026-08-16, mid-migration). AWS cruft cleanup (S3/ACM/CloudMap/old zones) was done
2026-06-05 via `scripts/aws-cleanup-legacy.sh`.

### FU-036: delete the orphaned Route53 hosted zone for teststuff.net

After cutover the Route53 **hosted zone** `teststuff.net` (`ZCGRPARGVE3CW`) is orphaned — the
registrar NS point at Cloudflare, so it serves nothing. As of 2026-06-06 it still holds the default
`NS` + `SOA` and a stale `burger.teststuff.net A 192.168.2.3` (a dead internal record — also an
internal-IP leak; it was on the delete list). Route53 only deletes a zone once it contains *just*
the apex NS+SOA, so remove `burger` first. Needs your admin SSO (the jail key is read-only):

```bash
aws sso login --profile rasmus
ZID=ZCGRPARGVE3CW
# 1. delete the stale burger A record
aws route53 change-resource-record-sets --hosted-zone-id $ZID --change-batch '{"Changes":[{"Action":"DELETE","ResourceRecordSet":{"Name":"burger.teststuff.net.","Type":"A","TTL":300,"ResourceRecords":[{"Value":"192.168.2.3"}]}}]}'
# 2. delete the zone (apex NS+SOA go automatically)
aws route53 delete-hosted-zone --id $ZID
```

NB: this is the **hosted zone** (DNS records), not the **registered domain** — leave the domain
registration (Route53 Domains, auto-renew ON) alone; only its NS were repointed to Cloudflare.

## Migration side effect: ACME — ✅ swapped & verified

Certs were issued **DNS-01 via Route53**; the NS move breaks that (LE queries the authoritative
NS = now Cloudflare). The swap is **done and a real renewal verified** (2026-06-06):
`tofu/cloudflare-token/acme-dns.tf` mints the scoped `homelab-acme-dns` token (Zone:Read + DNS:Edit
on teststuff.net only, output `acme_dns_token`, stashed at `~/.claude/cloudflare/acme-token`), and
`ansible/opnsense-acme.yml` uses `dns_service: dns_cf` (token via the `ACME_CF_TOKEN` env — the
`opnsense-playbook.sh` runs need it exported when touching ACME). It repointed the existing
`aws-acme` validation in place, so the certs bound to that name needed no change.

## Cloudflare MCP

`github.com/cloudflare/mcp-server-cloudflare` — 13 Cloudflare-hosted remote servers, mostly
read-only. The **Docs** server (`https://docs.mcp.cloudflare.com/mcp`) is wired into this project
(local scope) and fixes "model too old / UI hides IaC options". No token-management server exists
(define tokens in tofu). The read servers (GraphQL, Audit Logs, CASB, DNS Analytics) aren't
self-hostable → a future headless in-cluster agent uses the scoped `agent-read` token directly.

## Public ingress as a platform capability — design direction (operator, 2026-08-08; FU-039 leg)

The tunnel plumbing (`ha.teststuff.net`) is proven, but that was never the hard part: **open
traffic to a functional backend** is, and it must land as the same mechanism/policy split as
every other platform capability (ADR-076 provider-terraform, ADR-085 XRD doctrine, ADR-092's LAN
precedent — the stack adds routes freely once the platform wired the namespace ONCE). The stack's
`-iac` repo must NOT hold Cloudflare admin rights, and should not hold ANY Cloudflare credential:
**the XRD is the privilege boundary** — exactly the Garage-bucket pattern.

- **Claim (stack-owned, safe knobs only):** hostnames/routes under the delegated namespace →
  in-cluster backend; per-path cache behavior (Cache Rules); `api: true` paths — an API endpoint
  must NEVER hit a challenge/captcha, rendered as a WAF custom rule with the **Skip** action
  (Rulesets API — the current primitive; Page Rules are the cautionary deprecated ancestor).
- **Composition (platform-owned):** sane defaults (TLS posture, WAF baseline, security level),
  tunnel + zone + DNS wiring, the scoped least-privilege token (minted via `tofu/cloudflare-token`
  outside the jail; claims never see it), and the DEPRECATION LIFECYCLE — when Cloudflare
  retires a primitive or changes how HTTP traffic flows, the composition absorbs it once and
  every claim re-renders; no stack ever migrates a Cloudflare feature.
- **Observability (platform-owned):** a Cloudflare Prometheus exporter as an
  `argocd/resources/` app (per-hostname traffic/errors/cache panels + symptom alerts), beside
  the backend's own gateway metrics — the platform is responsible for seeing the edge, the
  stack for its backend contract.

Backend HTTP requirements (streaming/SSE for MCP, no buffering surprises, header passthrough)
are claim inputs, not platform guesses. Build order when this lands: XRD+composition for routes
+ cache + skip rules first (the knobs a stack needs on day one), exporter second, wider settings
only on demand. Prior art to extend, never duplicate: ADR-092's `stack_gateways` opt-in seam.

**Requirements come from four live artifacts, not from design sessions:**

1. **Diff-the-existing**: [`tofu/cloudflare/`](../tofu/cloudflare/) — the hand-built
   `ha.teststuff.net` instance (tunnel, DNS, mTLS client-cert WAF rule, ingress rules) is the
   floor: the claim schema must be able to express everything this one-off already does, or the
   XRD can't absorb it. The diff between that root and the draft schema IS the gap list.
2. **The first consumer's backend contract**: the oracle stack's gateway — streamable-HTTP/SSE
   (no buffering, long-lived connections), never-challenge on the MCP path, health endpoint for
   LB probes, auth-header passthrough. Owned by that stack's repo/specs; arrives as claim
   fields, not platform assumptions.
3. **ADR-092 parity**: whatever a stack does freely on the LAN leg (add HTTPRoutes in its own
   `-iac` with zero homelab change) must have a public-leg equivalent — the LAN claim is the
   ergonomics benchmark.
4. **The ≥2-projects rule** (the G05 lesson): do NOT freeze the schema from the oracle alone —
   **retrofit `ha.teststuff.net` itself as consumer #2** (it becomes a claim of the same XRD),
   which both de-product-shapes the schema and deletes the one-off. The retrofit converging is
   the acceptance test that the XRD generalizes.

Current Cloudflare primitives are checked against the Docs MCP at build time (rulesets engine:
cache rules, configuration rules, custom rules w/ Skip — not the deprecated Page Rules). When
the schema settles: ≤20-line ADR (the ADR-076→085→092 chain's next link) pointing here; the
composition lands in `argocd/resources/` on provider-terraform (the Garage-bucket donor shape),
token minted by `tofu/cloudflare-token` host-side, delivered via ESO; `SERVICES.md` row when LIVE.

### Zone division: two zone classes + a delegation verb (operator design, 2026-08-08)

**The Cloudflare zone is the real tenancy boundary** (tokens, WAF baseline, rulesets, cache
config are zone-scoped; Free/Pro has no finer grain), so a zone has exactly ONE owner:

- **Product zones** — one stack's claim owns the whole zone (full-domain scope, zone-scoped
  token bound in the composition). No co-owners.
- **Platform zones** — the platform composition owns the zone; stacks are TENANTS of delegated
  subtrees (`<stack>.<domain>` — ADR-092's LAN model at the WAN). teststuff.net is this class.

A new stack wanting to live UNDER an existing domain is a **consent record, not a modeling
problem**: platform zone → ordinary subtree claim, self-service; product zone → the owning
stack's `-iac` claim grows a `delegations:` entry granting the named subtree — consent is a
reviewable line in the OWNER's IaC, and the tenant claims routes only within the grant. The
XRD invariant that holds it all: **a claim may create routes only in zones it owns ∪ subtrees
delegated to it.** Cloudflare cannot enforce subtrees (zone tokens are its finest grain below
Enterprise) — and that costs nothing, because the privilege boundary is the XRD: claims never
touch tokens, the composition validates the grant. Promotion (tenant outgrows the subtree →
own domain) is a claim migration, not Cloudflare surgery.

### Token matrix (who holds what, 2026-08-08)

| Token | Scope | Canonical + delivery | Consumer / applier |
|---|---|---|---|
| **Account admin** | everything | **KeePass ONLY**, host | the operator, solely to apply `tofu/cloudflare-token` (the mint). Never jail, never cluster. |
| `homelab-tofu-apply` (existing) | teststuff.net DNS/SSL/WAF + account Tunnel, write | KeePass; jail copy `~/.claude/cloudflare/` | jail applies `tofu/cloudflare/` (the ha one-off). **Retires** when the XRD absorbs that root (consumer #2 retrofit). |
| `homelab-acme-dns` (existing) | one zone, DNS write | KeePass; OPNsense env | acme.sh DNS-01 |
| **`homelab-observability-read` (NEW, `observability-read.tf`)** | ALL zones read (analytics/zone/WAF-config) + account read (analytics, tunnel, audit logs) | KeePass → `~/.claude/cloudflare/observability-read` (jail) + Infisical `CLOUDFLARE_OBSERVABILITY_READ` (→ ESO) | jail LLM sessions (GraphQL, no more UI-clicking), the CF Prometheus exporter, later responder triage |
| platform-ingress write (FUTURE) | managed zones: DNS/rulesets/tunnel write | KeePass → Infisical → ESO → crossplane ProviderConfig; never in claims, never jail | the public-ingress composition |

**Operator-applied tofu = exactly one root**: `tofu/cloudflare-token/` (it needs the admin
token). Everything else consumes minted tokens. **Observability ships first**: apply the mint →
store the read token (KeePass canonical, jail file, Infisical key) → the exporter lands as an
`argocd/resources/` app on the ESO copy. Free-plan honesty: per-request logs are Enterprise
(Logpush/Logpull) — the GraphQL Analytics API (aggregated series + security/firewall events) is
what the jail and exporter actually query, and it covers the logs/errors-hunting use case.
