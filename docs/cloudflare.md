# Cloudflare — the public edge (zones, ingress capability, observability)

`teststuff.net` lives on Cloudflare and Cloudflare is the homelab's **public edge**: DNS, the
tunnel transport, the WAF, and the edge-analytics source. What began as "reach Home Assistant
from the phone" (2026-06) is now a platform capability (ADR-101). Status snapshot:

| Leg | Status |
|---|---|
| Zone on Cloudflare (NS cutover, ACME DNS-01 swap) | ✅ LIVE 2026-06-06 (§History) |
| Remote access `ha.teststuff.net` — tunnel + client-cert mTLS | ✅ LIVE, phone-verified (§Remote access) |
| **PublicRoute XRD** (ADR-101) — public ingress as a claim | ✅ **BUILT + ARMED 2026-08-08**; consumer #1 = the minutark placeholder claim (oracle-iac, 2026-08-12 — §Zone classes); the operator-witnessed test claim is still owed (FU-039) (§PublicRoute) |
| Observability — read token, GraphQL, cloudflared metrics | ✅ LIVE (§Observability) |
| Full-LAN remote access | Not Cloudflare — WireGuard on OPNsense (ADR-090) |

The *why* behind the June decisions is condensed in [`adr.md`](adr.md) (ADR-050…054); the
capability decision chain is ADR-101. Live IDs: account `07b08646b26bb43cd3073826f43b73da`;
zones `teststuff.net` = `6b63f95592a9e036f8b8f6934511d321` (**Free** plan),
`eid-demo.com` = `e0f1153fa0a3eb3b1a8ed898f2ec8851` (Pro, currently record-less).

## PublicRoute — public ingress as a platform capability (ADR-101, FU-039)

A stack claims `{hostname, backend}`; the composition renders a **per-claim Cloudflare Tunnel**
(deliberately sidestepping the singleton remote-config contention), the tunnel config, a proxied
CNAME via a provider-terraform `Workspace` (the Garage-bucket donor shape, ADR-076), and the
`cloudflared` Deployment in the claim's namespace (digest-pinned, restricted). **Subtree
enforcement fail-louds in the composition template**: a claim can only create
`*.<its-namespace>.teststuff.net`. The XRD is the privilege boundary — claims never see a
Cloudflare credential.

Files: `argocd/resources/publicroute/{xrd,composition}.yaml` (+ `example-claim.yaml.example` for
the shape), app `argocd/platform/publicroute.yaml`, provider secret
`argocd/resources/crossplane/cloudflare-ingress-externalsecret.yaml`.

**Built mechanism — per-route profile classes (built #1303–#1307, merged into goal/1302-public-edge 2026-09-02):** every shipped public hostname is one of two kinds, and the claim says which via the REQUIRED `.spec.profile` field (`consumer` | `api` — no default on the object, the 2026-07-16 API-server-stamp lesson). The composition fans out class-appropriate edge defaults the way ADR-101's zone classes fan out zone defaults. Glossary rows for the profile names: [`docs/glossary.md`](glossary.md) (FU-163, coining commit).

**Consumer profile** (`consumer`): browser-facing routes. Edge caching defaults on (`respect_origin` via the `http_request_cache_settings` phase ruleset — origin cache-control if present, Cloudflare's default edge TTL if not; the "1h default" the first cut promised is not an API mode: `respect_origin` takes no `default`, error 20107 on the first live apply 2026-09-03); RUM/client telemetry (Web Analytics) auto-installs the JS beacon for the route; challenge-shaped mitigations (captchas, managed challenges) are legal — the zone's `http_request_firewall_managed` phase runs normally for these routes. Rendered by the composition when `.spec.profile = "consumer"` (or absent on v1alpha1 claims, which default to consumer-class rendering for backwards compatibility).

**API profile** (`api`): machine-facing routes. Per-IP rate limiting ON (`http_ratelimit` phase ruleset, `characteristics = ["cf.colo.id", "ip.src"]`, **period 10 s, `mitigation_timeout` 10 s** — the Free plan's only entitled values, and `cf.colo.id` is required by the API (gotcha 6); threshold from `.spec.rateLimit.threshold`, platform default 1200/min, bounds 60–6000, enforced as ⌈threshold/6⌉ requests per 10 s window, so 1200/min means a burst cap of 200 per 10 s from one IP); a limited/rejected request answers a structured 429 JSON body (`{"success":false,"errors":[{"code":10429,"message":"rate limit exceeded"}],"messages":[],"result":null}`) a machine client can parse — accepted at create on the Free zone (Cloudflare's docs list custom responses as Pro+; whether the edge SERVES it there is homelab#1334 check 1). NO challenge-shaped mitigation can reach an api route: a Skip rule in the zone's **`http_request_firewall_custom`** phase (a products/phases Skip is a WAF custom rule — the managed phase refuses it, gotcha 6) skips products `["bic", "securityLevel", "uaBlock"]` and phases `["http_request_sbfm", "http_request_firewall_managed"]` for the route. CORS/preflight edge-owned via claim fields (`.spec.origins`): the edge enforces the allow-list (a preflight from an origin outside it is rejected at `http_request_firewall_custom` with a structured 403 — a rule in the SAME ruleset as the Skip, one entry point per phase) and sets `Access-Control-*` response headers (`http_response_headers_transform`, `action = "rewrite"`). An **allowed** `OPTIONS` reaches the origin, which answers the preflight — the Ruleset Engine cannot synthesize a 2xx, so an edge-terminated 204 would need a Worker/Snippet plus a cf-api-proxy allowlist entry (deliberately not in scope for Goal #1302). ⚠ `cors_headers` reflects `.spec.origins` into `Access-Control-Allow-Origin` with **no `Vary: Origin`** — inert today because the api profile renders no cache rule, but a constraint on whoever ever adds one to the api branch.

The quick-start wizard's zone-wide knobs (Bot Fight Mode, client-side security, leaked-credentials, speed optimizations) were DECLINED 2026-08-12 precisely because they cannot see this split — zone-wide toggles are the wrong altitude; the class default is per-route, in the claim. The OpenAPI schema validation 2.0 path (originally part of the predicted shape) was **not built** — app-side validation stays the real gate, and the free-plan 1 KB body limit makes schema validation a non-starter for the api profile's first consumer (oracle-gateway, streamable-HTTP/SSE).

**Completion state (2026-09-02):**

| Piece | State |
|---|---|
| XRD + Composition deployed (Established/Offered) | ✅ |
| Armed — `CLOUDFLARE_INGRESS_WRITE` minted+stored, ESO synced, provider pod carries it in-process | ✅ (verified by exec) |
| Profile field (`consumer` \| `api`) on XRD v1alpha2 — REQUIRED, no default | ✅ (#1303, merged) |
| Api profile: per-IP rate limit + structured 429 + edge CORS + never-challenge Skip | ✅ (#1304, merged) |
| Consumer profile: edge caching + RUM/client telemetry | ✅ (#1305, merged) |
| Edge observability export: DIY GraphQL poller (per-route series) | ✅ (#1306, merged) |
| cf-api-proxy allowlist extended for RUM account-scoped paths | ✅ (#1322/#1324, merged) |
| First consumer — the minutark placeholder claim (oracle-iac) landed 2026-08-12 (§Zone classes); the operator-witnessed echo/test claim is still the FU-039 next act | 🟡 |
| `ha.teststuff.net` retrofit = consumer #2 (retires `tofu/cloudflare/` + the write-key) | ☐ operator-witnessed, after the test claim |
| Product zones (a claim owning a whole zone, e.g. the IdP/oracle-sales domains) | ☐ future — §Zone classes |
| Zone-phase ruleset aggregation | ☐ **still the open leg (FU-039) — and now a live LIMIT.** The profiles' rulesets are rendered PER CLAIM, but Cloudflare keeps ONE entry-point ruleset per phase per zone (a second is added as a *rule* on the existing entry point, never as another ruleset — Ruleset Engine docs). So today: **at most one claim per profile per zone** (minutark.ee: the apex `consumer` + `mcp` `api` fit, disjoint phases); and on the platform zone `http_request_firewall_custom` is already the ha mTLS entry point (`tofu/cloudflare/mtls.tf`), so **any `api` claim on teststuff.net is unsupported** until aggregation lands (the never-challenge Skip lives in that phase since 2026-09-03 — before, only claims with `.spec.origins` collided). A collision is expected to fail the claim's Workspace loudly (create of a second phase ruleset), not to replace the existing entry point — expected from the API model, not yet observed live. Tracked as the post-launch child filed at assembly (2026-09-03). |

Until a claim exists, the capability is machinery with the switch on: rendering, credential
flow, and Workspace reconciliation are live-verified; **no route has actually been driven
through it** — that first end-to-end proof is exactly why the test claim and the ha retrofit
are operator-witnessed.

### Design record (requirements source — kept; the build followed it)

Mechanism/policy split as every platform capability (ADR-076 provider-terraform, ADR-085 XRD
doctrine, ADR-092's LAN precedent). Claim = safe knobs only: hostnames/routes under the
delegated subtree → in-cluster backend; `.spec.profile` selects the class defaults (consumer
or api); `.spec.rateLimit.threshold` and `.spec.origins` are the api profile's claim-field
knobs. Composition = sane defaults, tunnel+DNS+zone wiring, the scoped token, profile-specific
rulesets (rate-limit, cache, skip-challenge, CORS, RUM), and the deprecation lifecycle (when
Cloudflare retires a primitive, the composition absorbs it once; no stack migrates a Cloudflare
feature). Requirements came from four live artifacts, not design sessions: (1) diff-the-existing
`tofu/cloudflare/` — the claim schema must express everything the ha one-off does; (2) the first
consumer's backend contract (oracle gateway: streamable-HTTP/SSE, no buffering, never-challenge
on the MCP path); (3) ADR-092 parity — the LAN claim is the ergonomics benchmark; (4) the
≥2-projects rule — the schema isn't frozen until the **ha retrofit converges as consumer #2**;
that convergence is the acceptance test that the XRD generalizes.

### Zone classes: two kinds + a delegation verb (operator design, 2026-08-08)

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

**The live zone map** (merged here from the old §"Zone classes + spend surface" header,
2026-08-12 — the parked structural debt, closed when the minutark onboarding landed):
`teststuff.net` = **platform zone** (any ns claims in its delegated subtree); `minutark.ee` =
**product zone, owner `oracle-fleet`** (the owning ns claims anywhere incl. the apex; consumer
#1 is the minutark placeholder claim in oracle-iac). The zone map is a platform constant in the
PublicRoute composition; a product zone's BOOTSTRAP (records, TLS floor, DNSSEC) is
`tofu/cloudflare/minutark.tf` until the composition grows a product-zone bootstrap class.

## Token matrix (who holds what, 2026-08-08 — the ONE table; drafts died here)

| Token | Scope | Canonical + delivery | Consumer / applier |
|---|---|---|---|
| **Account admin** (CF name: "Create Additional Tokens", → 2027-01-09) | mint scope: user `API Tokens: Write` + zone/account read — *transitively* everything (it mints the rest); exact dashboard recipe in [`tofu/cloudflare-token/README.md`](../tofu/cloudflare-token/README.md) | **KeePass ONLY**, host (`~/Documents/homelab-admin.kdbx`, beside the GitHub org-admin) | the operator, solely to apply `tofu/cloudflare-token` (the mint). Never jail, never cluster. |
| `homelab-tofu-apply` | **both product zones** DNS/SSL/WAF/**Settings**/Single Redirects + account Tunnel, write (Settings = Argo-capable, see §Spend surface; Single Redirects added 2026-09-03 for the minutark www→apex rule — `Zone WAF Write` does NOT unlock the redirect phase despite the docs' "at least one of" list) | wallet `cloudflare-write-key`; jail `~/.claude/cloudflare/write-key`; ⚠ **expires 2027-01-01** (FU-156) | jail applies `tofu/cloudflare/` (ha + the minutark zone bootstrap), plan-gated by the operator. **Retires** at the consumer-#2 retrofit. |
| `homelab-acme-dns` | one zone, DNS write | wallet `cloudflare-acme-token`; OPNsense env (`ACME_CF_TOKEN` when running the ACME playbook) | acme.sh DNS-01 |
| `homelab-observability-read` | ALL zones read (analytics/zone/WAF-config) + account read (analytics, tunnel, **audit logs via `Account Settings Read`** — fixed 2026-08-08, see the gotcha) | KeePass → `~/.claude/cloudflare/observability-read` (jail) + Infisical `CLOUDFLARE_OBSERVABILITY_READ` (→ ESO) | jail LLM sessions (GraphQL + audit), the CF exporter, responder triage later |
| `homelab-ingress-write` | DNS (both product zones) + Tunnel write only | KeePass → Infisical `CLOUDFLARE_INGRESS_WRITE` → ESO **`cf-api-proxy/cf-api-token`** — the PROXY holds it (2026-08-09 custody move); provider-terraform is TOKENLESS (`base_url` → the proxy). Never in claims, never the reconciler. | **cf-api-proxy** (§below), on behalf of PublicRoute Workspaces. |
| `homelab-inventory-read` (staged) | token inventory read, for the FU-156 expiry belt | `inventory-read.tf`; `var.user_id` DEFAULTED 2026-08-12 (settled by the legacy-token dump) — mints on the next operator apply | the token-expiry exporter (future) |
| `homelab-jail-read-all` | EVERY read group per scope, filtered live from the catalog (`\bRead\b` — 43 zone + ~117 account + 2 user groups at mint); zones `*`, account `*`, user | `jail-read-all.tf` → KeePass → `~/.claude/cloudflare/jail-read-all` via wallet-files.sh. **Replaced the dashboard "Read all resources" token (deleted at apply, 2026-08-12)** | jail LLM sessions' ad-hoc read-everything archaeology (token audits, settings dumps, permission probes) |

**Operator-applied tofu = exactly one root, one command**: `devbox run cloudflare-token-tofu
plan|apply` (`scripts/cloudflare-token-tf.sh`, the github-tofu twin). Minted tokens flow into
the ordinary wallet: `keepass-init.sh` entry → `wallet-files.sh` regenerates the jail cache →
Infisical for cluster consumers via ESO (the apply prints the store checklist). Note on mTLS:
the write token needs `SSL and Certificates Write` — **not** the `Access: Mutual TLS…` groups
(that's the Enterprise Access path we deliberately avoided; same trap as the audit-logs group,
see gotcha 3's lesson: pick permission groups from the ENDPOINT's docs, not by name-similarity).

## cf-api-proxy — the autonomous write path (2026-08-09)

The one Cloudflare consumer that writes WITHOUT a human per action is provider-terraform
reconciling PublicRoute claims — so that path, and only that path, goes through an allowlisting
proxy (`argocd/resources/cf-api-proxy/`; third instantiation of the proxy+policy pattern after
the OpenRouter proxy and oracle's ert-egress-proxy). The jail's `write-key` deliberately does
NOT route through it: jail applies are operator-plan-gated, and the bootstrap needs paths
(settings, DNSSEC) that must never enter the autonomous allowlist.

- **The nginx location table IS the permission model** — method+path in git, reviewed like any
  manifest: `dns_records` CRUD on the two product zones, `cfd_tunnel` under the account,
  `rulesets` CRUD on the two product zones (rate-limit rules, cache rules, skip rules),
  `rum/site_info` CRUD under the account (`cloudflare_web_analytics_site`),
  `rum/v2/{ruleset_id}/rule` CRUD under the account (`cloudflare_web_analytics_rule`),
  read-only zone lookups + token verify. Everything else
  403s in Cloudflare's own error shape, naming the configmap.
- **Two independent layers**: a request must pass the allowlist AND the token's permission
  groups (live-verified 2026-08-09: an Argo enable dies at the proxy; a settings READ passes
  the allowlist and is then 403'd by the token). Cloudflare's undocumented group semantics stop
  being the only line of defense.
- **Custody**: the reconciler holds no credential at all — bypassing the proxy would need a
  token the pod doesn't have. A Cilium egress lockdown on provider-terraform is the deliberate
  residual (needs the full egress inventory: garage, infisical, k8s API — do it with care, it
  can brick Garage bucket reconciles fleet-wide).
- **Extended for consumer-profile RUM** (#1322/#1324/#1335): the consumer profile renders
  `cloudflare_web_analytics_site` and `cloudflare_web_analytics_rule`, which use account-scoped
  API paths (`/client/v4/accounts/{account_id}/rum/site_info` and
  `/client/v4/accounts/{account_id}/rum/v2/{ruleset_id}/rule`). These account-scoped paths are
  the whole of what RUM needs — the zone-scoped `web_analytics/rules` entry was removed as dead
  (#1322 established the rendered resources use account-scoped paths only, #1324 added the
  account-scoped pair, #1335 removed the unused zone-scoped entry).
- Re-resolution: `resolver <kube-dns> valid=30s` + variable `proxy_pass` (the ert-egress-proxy
  pin-forever lesson).

## Spend surface (2026-08-09; argo verdict 2026-08-12)

Zone-class definitions + the live zone map: §Zone classes above (one home — the duplicate
header this section used to carry was merged up 2026-08-12).

**Spend surface**: the account has a payment card attached (eid-demo.com is Pro), and the
assumed usage-toggle case was **Argo Smart Routing (per-GB) via
`PATCH /zones/{id}/argo/smart_routing`, gated by Zone Settings Write** — flagged ⚠ UNPROVEN at
PR#220 and **SETTLED 2026-08-12 by the host-side admin-token session: the argo setting is
ENTITLEMENT-gated, not permission-gated.** The evidence chain, complete:

| Token | Relevant groups | `GET/PATCH …/argo/smart_routing` |
|---|---|---|
| admin | Zone Read only | 10000 Authentication error |
| `observability-read` | Zone Read + Zone Settings Read | 1015 `Cause(s): smart_routing` |
| `tofu-apply` | Zone Settings **Write** | 1015 `Cause(s): smart_routing` |
| legacy "Read all resources" | every read group incl. Billing Read | 1015 `Cause(s): smart_routing` |

…and no Argo permission group exists in the full catalog, and the endpoint's docs name no
accepted-permissions line. **No mintable token scope can read OR write it on these zones** — the
metered-spend toggle effectively can't be reached by any credential we hold, jail token
included, which is good news for containment. Consequences: the spend-probe's **argo leg was
RETIRED** (not reinterpreted — "1015 ⇒ off on a free zone" is plausible but unverifiable without
buying the entitlement; conservative option taken), so the belt is now the PLAN gauge +
probe-health, and a dashboard-side Argo toggle lands in the **audit log** (`Account Settings
Read` on the observability token — an on-demand jail read, `accounts/{id}/audit_logs`).
⚠ Scope of that claim, measured 2026-08-12: the account audit log carries ZONE/account actions
(`zone.settings` updates verified present) but NOT user-token CRUD — the day's own token mints
and the legacy-token deletion never appeared in it. Token lifecycle is `/user/tokens` territory
(the FU-156 inventory credential), not the audit log's.
Purchase-shaped spend (plans, subscriptions) needs Billing groups no token carries — verify
anytime with `devbox run cloudflare-token-audit` (renders minted policies with NAMES; plans show
hex only). Containment: the autonomous path can't reach those endpoints (allowlist); the jail
token can, so the drift belt (homelab#217, **built** — §Observability) alerts on any plan change
on the product zones. Doctrine (the mTLS/audit-logs lesson, generalized, now with the argo
verdict as its sharpest instance): **permission semantics come from the target ENDPOINT's
"accepted permissions" docs line — the catalog names document nothing, the dashboard shows a
subset, and any `*Write` group is presumed entitlement-toggling until the endpoint list says
otherwise; a group can also gate NOTHING, because the gate may not be a permission at all.**

## Observability

**What exists today:** `cloudflared`'s own Prometheus metrics (PodMonitor, ~119 series —
per-tunnel request totals + connection health; ⚠ this build exports **no response-code dimension
and no hostname label** on `cloudflared_tunnel_total_requests` (labels: container/instance/job/
namespace/pod — verified live, homelab#362), so the tunnel metrics are a liveness signal, NOT a
substitute for zone analytics); the `homelab-observability-read` token for on-demand GraphQL +
audit-log reads from the jail; the lablabs exporter (`argocd/resources/cloudflare-exporter/`) —
correctly configured and **correctly idle**: neither zone can currently produce zone series
(below), so its alert is keyed to scrape-target health (`CloudflareExporterDown`), not data
presence; the **DIY GraphQL poller** (`argocd/resources/cloudflare-exporter/edge-probe.py`,
built #1306) — a ConfigMap-python poller beside the exporter in the same app/namespace, on the
same ESO-delivered `CLOUDFLARE_OBSERVABILITY_READ` token, polling `httpRequestsAdaptiveGroups`
and `firewallEventsAdaptive` (both ✅ on free zones per the validated matrix below) to produce
per-route edge series. ⚠ NOT routed through `cf-api-proxy`: that allowlist injects the
ingress-write token and deliberately 403s settings paths; this is a direct read against
`api.cloudflare.com/client/v4/graphql`, same as the spend probe's direct REST reads.

**Edge series contract** (the ORACLE stack's Grafana folder consumes these — cross-repo consumers
grep this doc, so the strings must match the emitter exactly):

| series | labels |
|---|---|
| `cloudflare_edge_requests_total` | `zone`, `host`, `status` |
| `cloudflare_edge_cache_hit_ratio` | `zone`, `host` |
| `cloudflare_edge_rate_limit_events_total` | `zone`, `host`, `action` |
| `cloudflare_edge_probe_ok` | `zone` |

The poller queries one zone at a time (never batched — a free zone riding into a batched query
would make Cloudflare reject the whole batch, homelab#132 round 3). Self-test replays recorded
API shapes through the real collector AND through the alert expressions scraped out of the
committed `prometheusrule.yaml` (`python3 edge-probe.py --self-test`). The alert
`CloudflareEdgeProbeBlind` (severity: warning, `platform_machinery: "true"`) fires when the
probe has not read a zone's edge data for 30m — the gauges above are UNKNOWN, not safe, and
edge data absence would go unnoticed.

**Spend drift belt** (homelab#217, 2026-08-09; argo leg retired 2026-08-12 — §Spend surface):
`cloudflare-spend-probe` — a ConfigMap-python poller beside the exporter in the same
app/namespace, on the same ESO-delivered `CLOUDFLARE_OBSERVABILITY_READ` token, polling the
zone REST surface the exporter doesn't touch. One gauge per product zone —
`cloudflare_zone_plan_is_free` — plus
`cloudflare_zone_spend_probe_ok`, so a blind belt is loud rather than reassuring
(`CloudflareZonePlanNotFree` / `CloudflareSpendProbeBlind`,
both `severity: warning` into the normal responder path). Unlike the exporter it watches
`teststuff.net` too — `CF_EXCLUDE_ZONES` hides that zone from the exporter (#132) and the belt
must not inherit that blind spot. `eid-demo.com` is out of scope: legitimately Pro, outside every
write token's zone map. Why a belt and not a guard is §Spend surface above; the mechanism and its
`--self-test` (recorded API shapes replayed through the committed alert exprs) live in
`argocd/resources/cloudflare-exporter/spend-probe.py`. That self-test evaluates ONE instant; the
alerts' behaviour over time — the `for:` windows, and the fact that neither restarts one
when the single-replica probe rolls (homelab#334) — is the promtool fixture beside it,
`spend-belt.promtool-test`, run by `devbox run prometheus-rules-lint` in CI.

### Free-zone GraphQL matrix (VALIDATED LIVE 2026-08-08, teststuff.net free vs eid-demo.com pro)

Probed with `homelab-observability-read` against `api.cloudflare.com/client/v4/graphql` — the
limits below are the API's own error messages, not doc paraphrase (probe script shape:
scratchpad `cf-graphql-probe.sh`, one dataset per query so errors can't mask each other):

| Dataset | free (teststuff.net) | pro (eid-demo.com) | monitoring use |
|---|---|---|---|
| `httpRequests1dGroups` | ✅ (requests/cached/bytes/threats/encrypted + uniques; no wall hit at 11 months back) | ✅ | daily traffic + threat trending |
| `httpRequestsAdaptiveGroups` | ✅ — **1d max window/query, 1w1d retention**; host+status dims proven. **Field shape**: `count` (request count), `dimensions { datetime, clientRequestHTTPHost, edgeResponseStatus, cacheStatus }`, `sum { edgeResponseBytes }` | ✅ — window widens to 1w1d, **retention SAME 1w1d** | per-host/per-status series — poll short windows into Prometheus and retention becomes ours |
| `firewallEventsAdaptive` | ✅ — flat event list (one row per event). **Field shape**: `datetime`, `clientRequestHTTPHost`, `action`, `source` — no `dimensions`/`sum` wrapper. Count events by counting rows in Python. | ✅ | WAF hits on `ha.teststuff.net` = someone probing the public edge |
| `dnsAnalyticsAdaptiveGroups` | ✅ live rows (queryName, responseCode) | ✅ | authoritative-DNS query monitoring |
| `httpRequests1mGroups` | ❌ "does not have access to the path" | ✅ | minute-granularity totals — **the lablabs exporter's dataset** (why it can't serve free zones, #132) |
| `healthCheckEventsAdaptiveGroups` | ❌ | ❌ (Health Checks not configured; Biz/Ent feature) | n/a |

**Pro-for-monitoring verdict: thin.** The measured delta is 1-minute granularity + 8× query
window; adaptive retention does NOT improve, and a poller that scrapes every few minutes makes
both moot (Prometheus keeps the history). A Pro upgrade should be justified by WAF/bot features
on public endpoints, not analytics. Per-request logs (Logpush/Logpull) are Enterprise — but
`httpRequestsAdaptive` (per-request sampled records: datetime/host/path/status/country/UA) IS
queryable on free, and at our traffic volumes sampling ≈ 100%: that's the incident-forensics
"log", fetched on demand from the jail.

**Web Analytics (RUM), free, built for consumer-profile routes** (built #1305, merged 2026-09-02):
the consumer profile renders `cloudflare_web_analytics_site` (auto_install = true, enabled = true)
and `cloudflare_web_analytics_rule` (host = the route, paths = ["*"]) for each consumer-profile
claim. The JS beacon auto-installs on orange-clouded pages under the route hostname. Requires
account-scoped API paths in the cf-api-proxy allowlist (added by #1322/#1324). Not relevant for
`ha.teststuff.net` (an app behind mTLS, not a page we optimize) — that leg becomes a PublicRoute
claim at the consumer-#2 retrofit and will carry RUM then if desired. The IdP OIDC login flow
and oracle's public "sales" page are the first real browser-facing surfaces that will exercise
this.

## Remote access to Home Assistant (the original leg, LIVE 2026-06-06)

Goal was: reach **Home Assistant from the phone, anywhere**. `https://ha.teststuff.net` returns
**403 without a client cert** (mTLS + WAF enforcing) and serves HA **with** it — verified from
the phone on mobile data. The phone `.p12` is at `~/.claude/cloudflare/ha-client.p12`
(`scripts/make-client-p12.sh` regenerates). This leg becomes a PublicRoute claim at the
consumer-#2 retrofit; until then `tofu/cloudflare/` owns it.

**Decisions** (detail: ADR-050…054): transport = **Cloudflare Tunnel** (outbound-only, no WAN
port-forward, CGNAT-proof); auth = **mTLS via Application-Security / SSL Client Certificates**,
NOT Cloudflare Access — Cloudflare has TWO mTLS mechanisms and only this one is Free-plan
(Access mTLS is Enterprise; managed-CA client certs + WAF custom rules are not). The client
cert rides the TLS handshake, so the HA companion app works with no interactive login; HA's own
login + TOTP stays as a second factor. **Don't buy Pro for teststuff.net** — nothing this leg
uses needs it. IaC = OpenTofu + the official `cloudflare/cloudflare` provider (NOT Crossplane's
community CF providers — they lag; note this predates ADR-101, whose composition drives the
SAME tf provider via provider-terraform Workspaces, which is the reconciliation).

**Request chain** for a proxied tunneled hostname: (1) L3/L4 DDoS drop → (2) TLS termination —
mTLS *validates* here, records `cf.tls_client_auth.*`, does not block → (3) rules pipeline —
WAF custom rule **enforces** (`http.host in {"ha.teststuff.net"} and not
cf.tls_client_auth.cert_verified` → Block) → (4) cache (HA passes through) → (5) Access —
skipped, no Access app exists → (6) tunnel egress via `cloudflared` → in-cluster HA → (7) HA
login + TOTP. CNAME gotcha: enable mTLS on the **specific hostname**, not the CNAME target.

**What `tofu/cloudflare/` contains** (built 2026-06-06, provider v5): tunnel
(`cloudflare_zero_trust_tunnel_cloudflared`, remotely-managed config object; DNS target is
`${tunnel.id}.cfargotunnel.com` — no `.cname` attr in v5), `cloudflare_dns_record` (uses
`content`, not `value`): `ha` CNAME → tunnel (proxied), `*.local` A → 127.0.0.1 (DNS-only);
mTLS chain `tls_private_key` → `cloudflare_client_certificate` (zone managed-CA) +
`certificate_authorities_hostname_associations` (per-zone **singleton**) + the WAF
`cloudflare_ruleset`; the `cloudflared` namespace/secret/Deployment (2 replicas,
digest-pinned). Lesson that keeps recurring: don't trust model memory for CF v5 — provider
GitHub docs + a credential-free `tofu validate` before any apply.

## Rollout gotchas (hit + fixed 2026-06-06; +1 2026-08-08)

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
3. **(2026-08-08, token root) Provider v5 "inconsistent result after apply" on
   `cloudflare_api_token` modify = ORDERING, not failure.** Editing a token's permission
   groups errors with four "Provider produced inconsistent result" messages — the API returns
   policies/groups in a different order than sent and the provider doesn't normalize. The
   mutation LANDS anyway: verify live (`/user/tokens/verify` with the STORED value — it does
   not rotate on modify — then hit the endpoint the permission was for), then re-`plan`; if
   the plan shows only a policy/group reorder, it is cosmetic. Confirmed on the
   `observability-read` audit-logs fix: apply "failed", audit endpoint worked seconds later.

4. **(2026-09-03, goal #1302 assembly) `Composition.spec.compositeTypeRef` is IMMUTABLE.** Moving
   the PublicRoute composition from v1alpha1 to v1alpha2 in place was rejected by the API server
   (`Value is immutable`), ArgoCD's server-side-apply sync retried forever, and the XRD — which
   had already flipped its referenceable version — left the live composite reporting "referenced
   composition is not compatible". Un-wedged with `kubectl replace --force` from master; composed
   resources (Workspace, cloudflared) are owned by the XR, not the Composition, so nothing
   serving was touched. Next time: either a NEW composition name per XR version, or the
   `argocd.argoproj.io/sync-options: Replace=true` annotation on the Composition for the flip
   commit. Companion gotcha: a version that makes a field REQUIRED (`profile`) strands every
   stored composite lacking it (`spec.profile: Required value`) until its CLAIM is updated in the
   owning -iac repo — the apex claim sat Synced=False (Ready=True, still serving) until
   oracle-iac#530.

Client-side gotchas from the phone rollout: a cached NXDOMAIN needs **airplane-mode toggle**
(force-stop doesn't flush system DNS; Chrome masks it via DoH, the HA app's WebView doesn't);
the companion app's Internal URL stays `homeassistant.teststuff.net` (LAN HAProxy, NXDOMAIN
off-LAN) and External must be `https://ha.teststuff.net` — pointing External at the LAN name
works on WiFi and dies on mobile.

5. **A storage-version flip with a new REQUIRED field strands the stored XR on TWO things, not
   one (2026-09-03, the G-G rollout, oracle-iac#530).** Gotcha 4 covers the claim manifest;
   after the claim moved to `v1alpha2 + profile`, the composite STILL refused: its
   `spec.claimRef.apiVersion` was pinned at `v1alpha1`, so the claim controller declined to
   propagate the new field ("refusing to operate on composite resource … not bound to this
   claim") while the XR controller could not update the XR without it (`spec.profile: Required
   value`). Neither side can move first. Un-wedge = two merge patches on the XR, composed
   resources untouched (the tunnel served throughout):
   `kubectl patch xpublicroute <xr> --type merge -p '{"spec":{"profile":"<class>"}}'` then
   `… -p '{"spec":{"claimRef":{"apiVersion":"platform.teststuff.net/v1alpha2"}}}'`. Design
   consequence for the NEXT XRD rev: ship a conversion webhook, or add the field as optional
   with the class default and make it REQUIRED one rev later, once every stored XR carries it.

6. **Free-plan entitlement + phase legality of the api-profile rulesets (2026-09-03, pre-merge
   dry-run for oracle-iac#532).** The composition's first api shape was rejected by the API on
   `minutark.ee` (Free) — invisible to `tofu validate`, which checks HCL, not entitlements. Probed
   by POSTing the exact rendered payloads THROUGH the deployed cf-api-proxy (the Workspace's own
   path: allowlist + ingress-write token + plan), then deleting what landed (204s; zero residue):

   | payload | verdict |
   |---|---|
   | rate limit, `characteristics = ["ip.src"]` | ✗ 20155 `characteristics field is missing 'cf.colo.id', this is required as ratelimiting counting is processed at colocation level only` |
   | rate limit, `["cf.colo.id","ip.src"]`, period 60 | ✗ `not entitled to use the period 60, can only use a period among [10]` |
   | rate limit, period 10 / timeout 10, with the JSON 429 custom response | ✓ created (custom response accepted at create despite the docs' Pro+ note; serve-time = #1334 check 1) |
   | Skip `products`+`phases` in `http_request_firewall_managed` | ✗ 20120 `skip action parameter phase 'http_request_sbfm' is not authorized` |
   | same Skip in `http_request_firewall_custom` | ✓ created |

   Consequence: a `terraform apply` is not transactional — with the old shape the tunnel, tunnel
   config, CNAME and cloudflared would have landed and the route gone PUBLIC with no rate limit
   and no Skip (Workspace `Synced=False` forever). Composition fixed in the same change (period
   10 s, ⌈threshold/6⌉ per window, `cf.colo.id`, Skip + preflight in ONE custom-phase ruleset).
   Doctrine: a NEW Cloudflare resource shape is dry-run through the proxy before its first claim
   merges — `tofu validate` proves syntax, only the API proves entitlement.

## Cloudflare MCP

`github.com/cloudflare/mcp-server-cloudflare` — 13 Cloudflare-hosted remote servers, mostly
read-only. The **Docs** server (`https://docs.mcp.cloudflare.com/mcp`) is wired into this
project (local scope) and fixes "model too old / UI hides IaC options". No token-management
server exists (define tokens in tofu). The read servers (GraphQL, Audit Logs, CASB, DNS
Analytics) aren't self-hostable → the jail uses `homelab-observability-read` directly instead.

## History (2026-06, all ✅ — kept for the record)

- **Route53 → Cloudflare, clean slate** (2026-06-05): imported zero records; kept only
  `*.local.teststuff.net → 127.0.0.1` (work use: local envs with self-signed TLS) and added
  `ha`. Deleted dead records (`burger`/`rancher` — internal-IP leaks; retired projects and
  their ACM validation CNAMEs). AWS cruft cleanup ran via `scripts/aws-cleanup-legacy.sh`.
- **NS cutover** ✅: `teststuff.net` is registered at **Route53 Domains** (so are `eid-demo.com`
  + `taranortaltest.net`); its NS were repointed to Cloudflare's two. Domain registration stays
  at AWS, auto-renew ON.
- **ACME swap** ✅ (real renewal verified): certs were DNS-01 via Route53; now
  `dns_cf` with the `homelab-acme-dns` token (`tofu/cloudflare-token/acme-dns.tf`,
  `ansible/opnsense-acme.yml`; export `ACME_CF_TOKEN` for ACME-touching playbook runs).
- **FU-036 (still open, needs admin SSO)**: the orphaned Route53 **hosted zone**
  `ZCGRPARGVE3CW` still exists — delete the stale `burger` A record first (Route53 refuses to
  delete a zone with more than apex NS+SOA), then the zone:
  `aws sso login --profile rasmus && ZID=ZCGRPARGVE3CW && aws route53 change-resource-record-sets --hosted-zone-id $ZID --change-batch '{"Changes":[{"Action":"DELETE","ResourceRecordSet":{"Name":"burger.teststuff.net.","Type":"A","TTL":300,"ResourceRecords":[{"Value":"192.168.2.3"}]}}]}' && aws route53 delete-hosted-zone --id $ZID`
  — this is the hosted zone only; leave the domain registration alone.
