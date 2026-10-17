# Spike — a live catalog for the OpenCode Go rail

**Status:** investigation, 2026-10-17. No decision has been taken; every fork below is marked ⚖
for the operator. The question (operator, 2026-10-17): the Go rail's models, prices and limits
are hand-copied JSON and Markdown — can they be read from the vendor instead, *"dynamic without
me just like providers/cost on openrouter"*?

**Prior art.** `docs/spikes/` holds no doc on this topic. The neighbours are adjacent, not
owners:
[`opencode-model-matrix.md`](opencode-model-matrix.md) is the model×surface **compatibility**
register (tool path, region gates, liveness verdicts) and carries a price snapshot only as a
copy. [`../agents/chainless-redesign.md`](../agents/chainless-redesign.md) §The OpenCode Go rail
records the 2026-08-13 finding this spike revisits: *"the rail is registry-POOR … the Go-rail
registry must be a curated snapshot"*. The 2026-08-13 finding is now partly out of date (§F1).

Every fact below was fetched live on 2026-10-17 between 19:32 and 19:37 UTC. Probes ran inside
the `agent-gateway` pod (`kubectl exec -i deploy/agent-gateway -n agent-egress -- python3 -`,
env `OPENCODE_GO_API_KEY`). They sent their own `User-Agent` and a fresh `x-opencode-session`,
and they never printed the key. Vendor pages were fetched with curl and the vendor repo through
`gh api`. All page content was read as data.

## Findings

### F1 — `GET /console/api/v2/config` is a live, machine-readable Go catalog

Sources:
- the docs page `https://opencode.ai/v2/docs/console/api/` (fetched 19:32:58Z);
- a live call `GET https://opencode.ai/console/api/v2/config`, sent with the Go key as a bearer
  token (19:35:01Z, HTTP 200).

The docs describe this endpoint as returning *"the providers and models available to the
workspace in the OpenCode V2 config format. OpenCode loads it after `/connect`"*. **Any key
permission level can read it**, including an "Inference only" key.

The live response has a provider `opencode-go`:
- `name` is "OpenCode Go"; `settings.baseURL` is `https://opencode.ai/inference/go/openai/v1`;
- it lists **29 models**;
- each model row has the keys `name, family, capabilities{tools,input,output}, cost[], limit{context,output[,input]}`,
  plus `package` and `settings.baseURL` when the model is served by a different API family.

`cost` is an **array of tiers**. The first tier is the base rate:
`{input, output, cache:{read[,write]}}` in $/M. Each later tier adds
`tier:{type:"context", size:N}`. For example, `claude-haiku-5-5` has a base row of
0.1/0.5/0.01/0.125 and a context-tier row at >100000 tokens of 0.5/2.5/0.05/0.625. These tiers
match `GO_PRICES_LONG` exactly.

The same response also carries the pay-as-you-go `opencode` provider with 84 models, where a
retired row is marked `"disabled": true`. **This one call covers what `GO_PRICES` +
`GO_PRICES_LONG` hold by hand, plus per-model context and output limits, tool support and
modalities.**

The 2026-08-13 reading ("`/v1/models` returns ids only") still holds for `/v1/models`. Both
`https://opencode.ai/zen/go/v1/models` and the new `https://opencode.ai/inference/go/v1/models`
return 37 rows of `{id, object, created, owned_by}` only, and they answer without auth. In those
rows `created` is the server's clock (1792265566 = 2026-10-17T19:32:46Z), not a model date.

### F2 — the per-model limits are only in docs and site source, and they are per model, not a global triple

The vendor's Go page is `https://opencode.ai/v2/docs/console/go/` (fetched 19:33:11Z). Its
source is `anomalyco/opencode:services/www/src/docs/content/console/go.mdx` on `dev`, which
moved there from `packages/web/…/go.mdx` in #54761 on 2026-10-12. The page says:

> Usage limits are defined as monthly dollar amounts … Each model has the following usage
> limits: 5-hour — 20% of the monthly limit; weekly — 50%; and monthly — 100%.

It also has two plan tables:
- **Go**, $10/month. DeepSeek V4.1 Flash has a monthly limit of **$80**, V4 Pro $15, Kimi K3 $15,
  GLM-5.3-Flash $60, and so on.
- **Go Plus**, $40/month. DeepSeek V4.1 Flash has $160.

Promotions appear as a struck-through limit and a multiplier, for example Step 5 Preview
"~~$15~~ $60 · 4x · Limited time".

The marketing page `https://opencode.ai/go` (fetched 19:33:24Z) shows "Est. requests / 5h" and
"Monthly usage" by model. Its data comes from
`anomalyco/opencode:packages/console/app/src/component/go-models.ts`: a TypeScript array of
`{id, requests, allowance, bonus?, limitedTime?, regions?}` plus a `plusLimits` map. A comment in
that file reads *"Go Plus limits are published per model in the Console, not a fixed multiplier
of Go"*. The row for V4.1 Flash is keyed `deepseek-flash`, which is the **family** id, not the
model id.

No API returns these limits. They are absent from `/api/v2/config`, from `/v1/models` and from
models.dev.

**What the repo assumes today.** `gometer._GO_WINDOW_DEFAULTS` budgets are $12/$30/$60, which is
20%/50%/100% of a **$60** pool applied to every model. The gateway copies this into
`policy.json` `rails.opencode.admission.window_draw.windows`. Under the published rule, the
gateway's draw model has a different pool:
- deepseek-v4.1-flash would have windows of $16/$40/$80;
- a $15-pool model would have windows of $3/$7.50/$15.

So the latch is wrong in both directions: too optimistic for $15-pool models and too pessimistic
for V4.1 Flash. gometer already notes this (*"models on a $15/$30 pool are correspondingly
under-metered … Recorded, not fixed here"*).

### F3 — the gateway's only Go model was retired from the Go catalog on 2026-10-14, and it still serves

The vendor commit `3a69bae84`, *"docs(go): remove DeepSeek V4 Flash and V4 Flash Vision Exp
(#55332)"*, landed on 2026-10-14T07:12Z.

What the live sources show for `deepseek-v4-flash` on 2026-10-17:
- it is absent from both `/v1/models` lists (19:32:45Z, 19:34:37Z);
- it is absent from the `opencode-go` provider in `/api/v2/config`;
- the pay-as-you-go `opencode` provider lists it as `"disabled": true` at 0.14/0.28/0.028.

Despite that, **it still answers 200** on all three Go paths at 19:35:01Z: `zen/go …/chat/completions`,
`inference/go/openai …/chat/completions` and `zen/go …/messages`. Every response carried
`x-opencode-endpoint-id: deepseek`, which looks like a direct DeepSeek route.

Every Go model id this repo routes to is this one: `policy.json` `rails.opencode.models.*`,
`model-classes.json` and `agents/stacks.json`. **Nothing published says which pool a retired id
now draws from.** The workspace's Budgets API showed `spent_micro_cents: "0"` for the month,
which is weak evidence that no extra-usage credits were spent (see F5).

This is the **qwen3.5-plus trap in reverse**:
- for qwen3.5-plus, the list kept an id that had died (it still returns
  `400 Upstream request failed: Model is unavailable.`, re-probed 19:35:46Z);
- here, an id was dropped from the list while it still serves.

Only the console catalog, read together with the docs, marks the id as **retired** rather than
dead.

### F4 — models.dev mirrors the vendor, and the console endpoint is the vendor's own source

`https://models.dev/api.json` (fetched 19:33:27Z) has a provider `opencode-go` with 32 models.
- It includes the `deprecated` rows `cat-jam-free`, `minimax-m2.7` and `step-5-preview-free`
  through `status`.
- `cost` matches the console rows and uses the same `tiers` shape.
- It has `limit.context` and `limit.output`, plus `release_date`, `last_updated`, `reasoning`
  and `tool_call`.
- It has **no peak rows and no monthly limits**.

Its repo, `anomalyco/models.dev`, is the vendor's own (last push 2026-10-17T19:20:59Z). Its
`providers/opencode-go/` history follows each Go launch within hours; for example, Step 5 Preview
was added on 2026-10-15T16:30Z.

The two catalogs differ in what they include:
- the console endpoint is **account-scoped**: it shows the workspace's actual Go model set and no
  deprecated rows;
- models.dev is public and carries a deprecation marker. Whether the `opencode` CLI's picker
  reads it was not checked in this spike.

**Most authoritative machine-readable source** for prices, context and capabilities:
`/console/api/v2/config`. It is what the vendor's own client loads after `/connect`. models.dev
is the fallback, and its `status: deprecated` field is the only machine-readable deprecation
marker.

### F5 — usage, allowance, key metadata: no API

From the console API docs (`…/console/api/`, `…/api/budgets/`, `…/budgets/`, `…/billing/`,
fetched 19:32:58Z–19:33:13Z):

- **Budgets API** (`GET /console/api/v1/budgets/members`) returns each member's
  `limit_micro_cents`, `spent_micro_cents`, `exceeded` and `resets_at` (the UTC calendar month).
  The budgets page states that *"Go usage within the plan"* does **not** count toward budgets;
  *"Go extra usage paid from credits"* does. This API therefore measures only spend **past** the
  Go limits (when "Use balance"/"Extra usage" is on), not the Go windows. The live call returned
  200 with `spent_micro_cents "0"` and `resets_at 2026-11-01T00:00:00Z`.
- **No endpoint** for Go usage per window or per model, remaining allowance, or window anchors.
  The docs only say *"track your current usage in the console"* (a UI).
- **No endpoint** for key metadata such as expiry. Expiry is set when the key is created in the
  UI. *"Automations using a revoked or expired key get HTTP 401 immediately."*
- **Service accounts and scopes.** Keys are `oc_sk_…` and belong to a service account. Two
  permission levels exist: **Inference only** (inference, providers, `GET /api/v2/config`) and
  **All** (adds the Console API with admin rights). Creating and revoking keys always needs a
  person. **The gateway's key has the `oc_sk_` shape and read the Budgets API with 200, which
  the docs reserve for All keys.** The gateway's key is admin-scoped, broader than inference
  needs. The catalog leg proposed below needs only Inference only.
- **Rate-limit headers.** A real 200 carries no rate-limit or quota header. Its only vendor
  headers are `x-opencode-endpoint-id`, `x-opencode-log-id`, `x-opencode-upstream-model-id` and
  `x-zen-model`. This was checked on five 200s, 19:35:01Z, and on two free-model 200s at
  19:35:46Z. Free ids now work over the API, unlike the 2026-09-18 matrix finding.
  **No real 429 could be observed.** The gateway's 7-day log and the old proxy's 7-day log hold
  no Go 429. A quota 429 cannot be provoked without draining a live window on the shared key,
  which was not done. The documented budget 429 body is *"Upstream request failed: Account budget
  exceeded"*, and it *"does not say which budget was reached"*.

### F6 — peak/off-peak still applies, and only the docs state it

The `go.mdx` page (above) has this footnote: *"DeepSeek V4.1 Flash / V4 Pro: Peak hours are
01:00-04:00 and 06:00-10:00 UTC, Monday through Friday"*. Its table has explicit `(Peak)` rows,
exactly 2× the off-peak rate. V4 Flash and V4 Flash Vision Exp left the footnote with their
retirement, so it now covers two models instead of four.

Neither `/api/v2/config` nor models.dev carries a peak tier; both show the off-peak row only. The
console's single `cost[]` row for V4.1 Flash is 0.15/0.60/0.003, the off-peak price. **Peak is
not available from any machine-readable source.** It is parseable only from the mdx table (row
suffix `(Peak)`) and the footnote's prose hours.

## Manual fact → machine source

The confidence column rates how well the named source can supply the fact. High means a vendor
API returns it, structured. Med means it is structured but not an API, or it is derived. Low
means prose or a TypeScript literal, open to format drift.

| manual fact today (file:symbol) | API / field that can supply it | refresh cadence | confidence |
|---|---|---|---|
| `gometer.py:GO_PRICES` in/out/cR/cW per model | `/console/api/v2/config` → `providers["opencode-go"].models[id].cost[0]` (`input`, `output`, `cache.read`, `cache.write`) | hourly–daily; changes land with launches (several per week in Oct) | **high** |
| `gometer.py:GO_PRICES_LONG` threshold + rates | same, `cost[i>0]` with `tier:{type:"context",size}` | as above | **high** |
| `gometer.py:GO_PRICES_PEAK` | none. Parse `go.mdx` table rows with the `(Peak)` suffix | on doc commit (`gh api …/commits?path=…go.mdx`) | low |
| `gometer.py:GO_PEAK_HOURS_UTC`, `GO_PEAK_WEEKDAYS` | none. Prose footnote in `go.mdx` | on doc commit | low, so keep these as policy data and alert on doc change |
| `gometer.py:_GO_WINDOW_DEFAULTS` budgets ($12/$30/$60) | none. Per-model monthly limit in the `go.mdx` table or `go-models.ts` `allowance` (Go) / `plusLimits` (Go Plus), × the published 20/50/100% rule | on doc commit | med (structured TS); the rule itself is prose |
| `_GO_WINDOW_DEFAULTS` anchors (chain / weekly Mon 00:00 / monthly 13th 11:30) | none. Not published anywhere | — | n/a: stays self-measured |
| promotion multipliers (gometer's retired `half` flag) | `go-models.ts` `bonus` + `limitedTime`; `go.mdx` struck-through limit | on doc commit | med |
| `_GO_PRICED_MODELS` / the model list | `/api/v2/config` `opencode-go.models` keys (account's set) | hourly–daily | **high** for *listed*; **not** a liveness signal (F3) |
| deprecation / retirement (no field today; matrix 💀 rows) | models.dev `status: "deprecated"`; absence from `/api/v2/config` | daily | med |
| `opencode-model-matrix.md` price + "Usage" columns | the two rows above. The matrix keeps compat verdicts only | — | — |
| `model-classes.json` `rails.opencode-go.concurrency` (3) | none. Not a vendor fact (our politeness bound) | — | n/a: stays policy |
| `policy.json` `rails.opencode.admission.window_draw.prices` / `.fallback` | `/api/v2/config` (as `GO_PRICES`); fallback = max over the catalog | with the catalog | **high** |
| `policy.json` `rails.opencode.admission.window_draw.windows` | per-model limit (row 5) | on doc commit | med |
| `policy.json` `rails.opencode.models.*` (deepseek-v4-flash) | membership check against `/api/v2/config` | with the catalog | **high** (F3 is the case it would have caught) |
| per-model context / output caps (nowhere today) | `/api/v2/config` `limit.context` / `limit.output` | with the catalog | **high** |
| key expiry (FU-314, read off the console by hand) | none | — | n/a |
| live usage / remaining allowance | none for in-plan Go; Budgets API only for credit overflow | — | n/a: stays self-metered |

## Gaps where no API exists

1. **Per-model monthly limits and the 20/50/100% rule.** These exist only in docs prose,
   Markdown tables and a site TypeScript file. They are the most important fact the latch needs.
2. **Window anchors and remaining allowance.** No usage-read endpoint exists for in-plan Go, so
   windows stay self-metered as in chainless-redesign. Only the 429 latch reports the vendor's
   view.
3. **Peak hours and peak rates.** Only prose and table rows in the docs.
4. **Liveness and retirement.** No `/v1/models` endpoint is a liveness signal (F3, and the
   2026-09-17 qwen3.5-plus note). Retirement is visible only as a model's *absence* from the
   console catalog, or as models.dev `deprecated`.
5. **Key metadata.** No expiry or scope read. Expiry is known only from the UI.
6. **429 shape.** Unobserved (F5), so the latch cannot yet read a vendor reset time.

## Proposed design — a Go catalog leg on the gateway's opencode rail

**What OpenRouter has that Go lacks, and what the gateway already lacks.**
- The old proxy reads `/api/v1/models/<id>/endpoints` per model at pin time. That feeds the M4
  session pin (`openrouter-proxy.py:compute_pin`), which picks the cheapest provider that
  supports caching, has tools and clears an uptime floor, priced at
  `effective-pricing` market rates (`MARKET_TTL_S` 6 h).
- `agents/estimate_budget.py` keeps a 24 h JSON registry of `/models` + `/endpoints` for the
  pre-flight cost estimate.
- `router.py` uses both behind `POST /route`, together with strikes and cooldowns.
- **The gateway's openrouter rail does none of this.** It forwards the policy model with no
  provider pin, no price lookup and no endpoint registry (`gateway/src/agent_gateway/rails.py`;
  sessions.md §Named gaps lists strikes and `/route` as gaps). A Go catalog would be the
  gateway's **first** vendor-registry leg, so its shape should be one the openrouter rail can
  reuse later.

**The leg, step by step.**

1. **Fetch.** The gateway's opencode rail fetches `GET /console/api/v2/config` on a schedule
   (⚖ cadence: hourly suggested; one cheap GET). It keeps `providers["opencode-go"]` and
   normalizes it to a `GoCatalog`: one row per model with
   `{id, family, cost_tiers[], context, output, tools}`, stamped `fetched_at`.
2. **Overlay.** The limits that no API carries (F2, F6) come from a second, slower source (⚖
   which one: a `gh api` read of `go-models.ts` + `go.mdx` at a pinned path, or an operator-
   edited overlay file). This source produces `{model|family → monthly_limit, plan, bonus,
   peak_rows}`. On a vendor commit to either path, the leg re-reads it and raises a "Go catalog
   source changed" alert, so a format drift fails loudly instead of silently.
3. **Persist.** The last good snapshot is persisted on the gateway's store, next to the request
   ledger. A failed or empty fetch, a schema mismatch, or a model count that drops by more than
   ⚖ N% keeps the previous snapshot and raises `GoCatalogStale` after ⚖ 24 h. This is the
   `estimate_budget.py` shape: a cached registry with the vendor read as the primary source,
   and **no hard-coded table**.
4. **Admission reads the snapshot.** `window_draw` prices each request from the catalog row
   (base or context tier) plus the overlay's peak row. Each **model's** windows become
   `{20%, 50%, 100%} × its monthly_limit` (⚖ per model or per `family`: the marketing data keys
   V4.1 Flash as `deepseek-flash`). An unlisted id is not admitted (⚖ hard refuse vs. today's
   conservative fallback price). This turns F3 from silent into a `rail:model-not-in-catalog`
   defer.
5. **Policy keeps rules only.** `policy.json` `rails.opencode` keeps:
   - the model choice per tier;
   - `threshold`;
   - `latch_429_hold_s`;
   - `max_sessions`;
   - the anchors (self-measured);
   - the plan name (⚖ `go` vs `go-plus`; not readable from any API).

   It drops `prices`, `fallback`, `peak_hours_utc`, `peak_weekdays` and the window
   `budget_usd`s. The gometer copies retire with the old proxy and are not migrated.
6. **Expose.** A `GET /catalog/opencode` read-only view and gauges
   (`gateway_go_catalog_age_seconds`, `gateway_go_catalog_models`) feed the subscription
   dashboard. The matrix spike stops carrying prices and links to this view.

**What would settle the open facts:**
- (a) one logged 429 from the Go rail, with full headers. The latch should log the response
  headers the first time it trips. This settles gap 6.
- (b) a support question to the vendor asking whether a retired id (deepseek-v4-flash) draws the
  in-plan pool, a credit balance, or nothing. Alternatively, a controlled N-request draw read
  against the console Overview usage, but that is a UI reading.
- (c) whether limits key by model or by `family`. A draw on V4.1 Flash followed by the console's
  per-model usage view, or the vendor's answer.
- (d) a read-only GET on a Go-usage path, if the vendor publishes one. Nothing in the API index
  today.

## Open questions for the operator (⚖)

- ⚖ **Retired model in production.** deepseek-v4-flash (F3) is the gateway's only Go model.
  Should it move to `deepseek-v4.1-flash`, which has the same off-peak price and the
  $80 pool, before the catalog leg exists?
- ⚖ **Key scope.** The gateway's key reads the admin Budgets API (F5). Should it be reissued as
  "Inference only" (enough for inference and `/api/v2/config`), with no admin rights in the
  egress pod?
- ⚖ **Overlay source** for limits and peak: parse the vendor's repo files (automatic, but
  breaks if their format drifts) or keep an operator-edited overlay with a change alert (manual,
  but the alert tells the operator when to update it)?
- ⚖ **Per-model windows.** Should the gateway's latch become per model (the vendor's rule, F2)
  instead of one global triple? That changes admission semantics, so it needs a sessions.md spec
  change.
- ⚖ **Unlisted id.** Refuse admission, or keep the conservative fallback price?
- ⚖ **Plan.** Go or Go Plus: no API reveals which plan the workspace is on. Should it be
  declared in policy?
- ⚖ **Cadence and staleness bounds:** fetch interval, the model-count drop threshold, and the
  stale alert age.
