# Pattern: the public request map — one picture per app, rendered from two maps

> To find **what** services exist (and their status), see the catalog [`../../SERVICES.md`](../../SERVICES.md).
> This doc is the **request-flow contract** for anything served through a [`cloudflare.md`](../cloudflare.md)
> §PublicRoute claim — the third consumption contract beside
> [`app-owned-resources.md`](app-owned-resources.md) (buckets, keys, DBs) and
> [`observability.md`](observability.md) (monitors, rules, dashboards). Decision: **ADR-124**.
> Written 2026-09-03 after the first api-profile claim (oracle-iac#532) showed that the edge's
> limits, the platform's networking and the app's guards had no single picture — and that the
> split between them is exactly where the bugs land (five seams found in one read, §Seams).

**The one-line rule: the platform publishes its half of the request path as a machine-readable
map; every app publishes its own half in the same row schema; the app renders the merged picture
in its own repo, in CI, and never hand-copies the platform's rows.** A hand-written merged doc on
either side is the drift bug the routing table warns about — oracle is one consumer, the next
stack is another, and the platform half changes under both.

## Ownership — who guards what

| Piece | Owner | Where |
|---|---|---|
| the row schema, the platform stages per profile (`api`, `consumer`), the LAN path, the **contract rows** (what the platform assumes of an app) | **platform** | [`request-flow/platform.yaml`](request-flow/platform.yaml) |
| the renderer + its self-test (byte-identical example, validator teeth) | **platform** | `scripts/request-flow-render.py` (`devbox run request-flow-render`, `request-flow-self-test`) |
| the app stages — one row per guard, each pointing at the app's spec id | **stack** — from its own repo | the app's `request-flow.yaml` (template: [`request-flow/example-app.yaml`](request-flow/example-app.yaml)) |
| the rendered picture — table + diagram + contract status | **stack** — generated in its CI | the app repo's docs (example output: [`request-flow/example-rendered.md`](request-flow/example-rendered.md)) |
| the edge MECHANISM behind every platform row (rulesets, tokens, gotchas) | platform | [`cloudflare.md`](../cloudflare.md) §PublicRoute — this doc only sequences and assigns |

Same split as observability: the platform runs the mechanism, the stack ships its artifacts, and
they meet through a schema, not through a copied paragraph.

## The schema — one row per stage

`seq · stage · owner · guard · value · rejection · verify · id` (+ `fulfils` on app rows).

- **seq** orders the merge: platform stages 10–89 (DNS → TLS → DDoS → custom rules → rate limit →
  managed WAF → cache → tunnel → Service), app stages from 100. The LAN path (ADR-092) is a
  second chain that joins the public one at the Service stage.
- **owner** ∈ `cloudflare` (a plan constant nobody here configures) · `platform` (composition,
  zone bootstrap, network) · `app`.
- **value is a POINTER**, never a number: the claim field, the composition, the chart value — the
  number's home stays authoritative and the map cannot go stale on it.
- **rejection** is what a client sees — status AND body grammar — because that is the contract a
  machine client parses.
- **verify** names the probe that proves the stage live (the dry-run-through-the-proxy doctrine
  of `cloudflare.md` gotcha 6, written per stage).
- **id** is the app's spec id (`SRV-…`) or the platform's (`PRF-…`, `LAN-…`, `CTR-…`) — the
  "requirements MUST have unique identifiers" principle, so a row is a link, not prose.

**Contract rows** (`CTR-*`) are the platform's assumptions about the app: the things the Free
plan's edge structurally cannot do (body cap, backend timeout, per-identity metering, answering a
preflight) or that the platform's design relies on (one endpoint path, operational paths answered
pre-auth, Origin default-deny on the LAN path). An app row claims one with `fulfils: CTR-…`; an
unfulfilled row renders as a **GAP** and fails the render under `--strict`. The seams below are
those rows before they had a name.

## Rendering — how an app gets its picture

```sh
# in the app repo (devbox task); HOMELAB = a checkout of homelab at a PINNED ref — the same
# pinning discipline as the chart version in the -iac repo, so the picture states what it merged
python3 $HOMELAB/scripts/request-flow-render.py \
  --platform $HOMELAB/docs/patterns/request-flow/platform.yaml \
  --profile api --lan --strict \
  --app docs/request-flow.yaml --out docs/request-flow.md
```

The output header carries the sha256 of BOTH inputs (never a git sha: the committed picture must
not change when an unrelated commit touches the file). The example in this directory is the
platform's self-test fixture: `devbox run request-flow-self-test` renders it and byte-compares, so
a platform-map edit that changes the picture reds CI until the example is regenerated with it.

## Seams — the register (a seam is a contract row that was unfulfilled or unnamed)

| id | seam | status |
|---|---|---|
| S1 | **Preflight is not edge-terminable on Free**: the Ruleset Engine cannot synthesize a 2xx, so an allowed `OPTIONS` reaches the origin; the oracle gateway has no `OPTIONS` handler | `CTR-OPTIONS` — GAP in the example |
| S2 | **Public-origin mode is deployment-global**: one Deployment serves the LAN route and the tunnel; a boolean that accepts any Origin drops the DNS-rebinding default-deny on the LAN too | `CTR-ORIGIN` — fulfilled in name; the fix is one allow-list (the claim's `origins` mirrored into the chart) instead of a mode |
| S3 | **Three rejection grammars on one URL**: edge 429 = Cloudflare envelope; app 429 = `{"error"}` + `Retry-After: 60` (the edge window is 10 s); body-cap/timeout = HTTP 200 JSON-RPC frames | `CTR-ERRORS` — GAP in the example |
| S4 | **DDoS L7 is outside the never-challenge Skip**: `ddos_l7` mitigations can be challenge-shaped; whether Free allows an action override is unverified | `PRF-DDOS` — ☐ verify (cloudflare.md completion table) |
| S5 | **The Skip drops the Free managed WAF**: listing `http_request_firewall_managed` in the Skip's phases removes block-shaped WAF rules for the api host, not just challenges | `PRF-WAF` — ☐ decide (cloudflare.md completion table) |
| S6 | **Operational paths are public** until the composition blocks them (ADR-123) | `PRF-CUSTOM` — ☐ FU-206 |

## Phase 2 — the platform half from the reconciler, not a file

`platform.yaml` is hand-written today and mirrors what the composition renders. The honest
source is the **PublicRoute XR's status**: the composition knows which rulesets, thresholds and
tunnel it applied for THIS claim, and can publish the platform rows there — then the app renders
against `kubectl get publicroute <claim> -o yaml`, i.e. against what is live, and the file becomes
a fixture for CI only. Tracked in `cloudflare.md` §PublicRoute completion table (FU-039's leg);
ADR-085's second half (catalogs generated from XRDs) is the same direction one ring out.
