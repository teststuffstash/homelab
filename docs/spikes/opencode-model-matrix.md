# OpenCode Go/Zen model matrix — the opencode-side compat register

**Status: LIVING REGISTER (started 2026-08-13).** This is the "maintained per-model tool-compat
matrix" the [ADR-107 charter](../agents/chainless-redesign.md) §Go rail names — **opencode-side
facts only** (endpoint compat, tool path, region gates, auth quirks, prices), never model
*quality* (that's the FU-057 ledger's axis). One row per model; update the row in the same
commit as the probe; a cell that says nothing means UNTESTED — never assume.

**Why it exists** (operator, 2026-08-13): *"so I'm not doing the same experiments over and
over again."* Every ✗ here cost a real probe; re-testing a ✗ without a reason (version bump,
opt-in toggle, upstream fix) is the waste this file kills.

**Harness legend** — compat differs by CLIENT, so every verdict names how it was reached:
`raw` = direct HTTP (curl / header-less python) · `claude` = claude-code through the jail shim
(`scripts/claude-model-shim.py`) · `opencode` = the opencode client itself (may work where the
Anthropic-compat path doesn't — it speaks their native/OpenAI path).

**Verdict tokens**: ✅ pass · ✗ a real, reproducible compat failure · ⚠ **UNKNOWN** = the probe
could not reach a verdict (e.g. upstream HTTP 500) — an untested-WITH-A-REASON cell, never a ✗ ·
⚠ **GATED** = refused by an opt-in/region policy, not by compat · 💀 **DEAD** = the id is served
or listed but every call fails.

**Prices**: snapshotted from the vendor's own docs page (`go.mdx` §"Usage limits", the source
behind https://opencode.ai/docs/go/) — the ONLY price source; the API (`/v1/models`) returns bare
ids. $/M tokens: in / out / cached-read / cached-write. "Usage" = the docs' per-model monthly
limit. "Badge" = the picker's "(Nx usage)" marker. **Current snapshot: 2026-09-17** (37 published
rows / 29 model ids; the earlier 2026-08-13 console-curated snapshot had rotted). The prices in
this file and in `argocd/resources/openrouter-proxy/gometer.py` are ONE table — refresh both in
the same commit.

⚠ **REFRESH 2026-09-17 — three structural changes, not just numbers:**

1. **PEAK / OFF-PEAK is a new, TIME-VARYING axis.** Verbatim: *"DeepSeek V4.1 Flash / V4 Pro /
   V4 Flash / V4 Flash Vision Exp: Peak hours are 01:00-04:00 and 06:00-10:00 UTC, Monday
   through Friday; all other hours, including weekends, are Off-Peak."* Peak is exactly **2×**
   off-peak on all four. `gometer` now resolves prices against the REQUEST TIMESTAMP
   (`is_peak(now)`, injectable, default `time.time()`); both sides are pinned in the router
   self-test.
2. **The "(Nx usage)" BADGE COLUMN IS GONE from the vendor table.** Promotions are now published
   as an explicitly **raised monthly limit** instead — DeepSeek V4.1 Flash reads
   `~~$15~~ **$60** · 4x · Ends Sep 20`. The badge semantics recorded below (08-13 billing,
   08-17 limit-side) are therefore **HISTORY, not a live grounding**: the `half=True` flags that
   sat on `deepseek-v4-flash` and `gpt-5.6-luna` were removed from `gometer`. Those two models
   now meter at **2× their previous window draw** — the conservative side, since the draw feeds
   the capacity latch and an unproven halving makes the latch optimistic. The `half` mechanism
   is retained in code (and still self-tested) for a future, GROUNDED badge.
3. **Per-model monthly limits are DOCUMENTATION ONLY in this repo.** Nothing reads the "Usage"
   column; the latch runs one global $12/$30/$60 window triple (`gometer._GO_WINDOW_DEFAULTS`),
   i.e. it assumes the $60 pool for every model. Models on a $15/$30 pool are correspondingly
   under-metered by the latch. Recorded here; not fixed.

**Served but UNPRICED (9 ids, 2026-09-17)** — listed by `/v1/models`, absent from the published
price table: `deepseek-flash`, `glm-5`, `grok-4.5`, `hy3-preview`, `kimi-k2.5`, `mimo-v2-omni`,
`mimo-v2-pro`, `omen-alpha`, and the dead `qwen3.5-plus`. These take `gometer`'s
`_GO_MAX_PRICE` fallback — the most-expensive-known row (kimi-k3, $18/M split in/out) with a
loud warning — which is the right conservative behaviour and is **verified still in force after
the refresh** (`_GO_MAX_PRICE` == 18.0; self-tested through the proxy's unknown-model path).
✅ **Badge semantics RESOLVED for BILLING (console dump, 2026-08-13 18:28)** — HISTORY as of
2026-09-17 (no badge column is published any more; see the refresh note above)**:** every itemized
Cost row equals **list-price arithmetic at 1×**, badged models included — deepseek-v4-flash
(2x badge) 7,794in/22out → $0.0011 = exact list; luna (2x) 12,267/13 → $0.0028 ≈ list; kimi-k3
173/93 → $0.0019 exact; glm-5.2 7,646/727 → $0.0139 exact (and its cached sibling → $0.0060 =
cR math); minimax/qwen3.8-max exact. **The badge does NOT multiply billed usage-$** — window
accounting builds on list prices. **The limit-side meaning is COMMUNITY-CONFIRMED as the favorable direction** (operator's
half-off reading; r/opencode thread on Luna's badge, 3 independent answers, 2026-08-01≈):
"2x more usage than you would normally get" / "50 percent discounted" / "double the api worth
in your subscription" — i.e. badged models draw the windows at HALF their billed list-$ (which
is why the Cost column still shows list ×1). It also decodes the docs' Usage column: Luna $15
pool × 2x = $30 effective ("Twice the usage would be $30", ibid.). Unverified by us at the
limit boundary (window internals are unobservable); the tell is now the reverse — a badged
model NOT latching when its billed $ says it should. Effective window-draw for badged models =
list ÷ 2: flash cR ≈ $0.0014/M effective. ⚠ Wording trap (operator, 2026-08-13): the wider
industry convention ("Nx" in Cursor/Copilot premium-request multipliers) means N× COST — but
opencode's phrase is "Nx **usage**", i.e. N× ALLOWANCE (half-off at 2x). Same token, opposite
signs; opencode's poor word choice, and exactly how this register's first reading went wrong.
Read "usage" as "value you receive", never "cost you pay". Bonus from the same dump: cached
rows expose cache-read billing directly (glm cR ≈ list $0.26/M ✓).
⚠⚠ **SUPERSEDED 2026-09-17 — the 08-17 measurement was taken through a BROKEN CACHE, and
read the symptom as the rule (operator).** Until the session-header fix (FU-251, 2026-09-17)
the proxy sent NO `x-opencode-session` and one fleet-wide User-Agent, so affinity fell back to
client IP, requests scattered across providers, and **there were no cache reads to discount** —
every call re-paid fresh input. "The window draws at list on RAW tokens" was therefore an
artifact of our own defect, not a property of the vendor's accounting. Measured again once
affinity worked, on two reviewer rides (2026-09-17): the vendor's dashboard billed **$0.148**
for 1.57M input / 14.8k output at ~89% cache-read, and its three window readings — 1.4% of the
5h $12, 0.5% of the weekly $30, 0.3% of the monthly $60 — independently imply **$0.15–0.18**.
List-on-raw would have been $0.65 (5.4% / 2.2% / 1.1%). So **the window draws at per-kind LIST
prices: cache reads draw at the cR rate**, which is what `gometer.window_draw` already computes
(the homelab#540 amendment). Three windows agreeing on one spend also confirms the $12/$30/$60
budget constants. Consequence for capacity: a review of this shape costs ~$0.074, so the monthly
pool is ~800 reviews, not the ~180 list-on-raw predicted. The block below is kept as the
historical reading it was — do not price from it.

⚠ **LIMIT-SIDE SEMANTICS MEASURED 2026-08-17** (a console usage dump — transient jail upload,
not retained; the durable record is the gometer draw-pricing commit + TICK-LOG 2026-08-17 —
reconciled against a known workload — the 509-call jail subagent wave, sole account traffic):
**the window draws at LIST price on RAW tokens — cache discounts do NOT apply to window draw —
halved for badged models.** Sample arithmetic: 50.56M flash input × $0.14/M ÷ 2 ≈ $3.54 ≈ the
console's 36%-of-$12 window read, while BILLED was $1.25 (cache-discounted) and a cache-assuming
meter computed $0.145. So "2x usage" = half of list-on-raw, never half of billed — a
cacheRead-heavy workload draws ~3–4× its billed cost from the windows, and capacity math must
use DRAW, not billed. (Window accounting fix: the gometer draw-pricing + epoch-anchoring chunk,
2026-08-17.)

## OpenCode Go (subscription rail, `https://opencode.ai/zen/go/v1`)

| model | $/M in/out/cR/cW | Usage | badge | anthropic-compat tools | text (compat) | notes |
|---|---|---|---|---|---|---|
| **qwen3.8-max** | 2.00/6.00/0.25/2.50 | $15 | — | ✅ `tool_use` (go-session probe 08-13; **re-verified raw 2026-09-17, 2.5s**) | ✅ | current **opus slot** |
| **qwen3.8-flash** | 0.15/0.47/0.016/0.20 | $30 | — | ✅ `tool_use` (raw 2026-09-17, 2.1s) | untested | NEW in the 09-17 table; cheapest PASSING tool-caller after the deepseek flash pair |
| qwen3.7-max | 2.50/7.50/0.50/3.125 | **$30** (was recorded $60 — corrected 09-17) | — | untested | untested | |
| **qwen3.7-plus** | ≤256k: 0.40/1.60/0.04/0.50 · >256k: 1.20/4.80/0.12/1.50 | $60 | — | ✅ `tool_use` (raw 2026-09-17, 4.3s) | untested | the **reviewer's Go failover pin** (`opencode-go/qwen3.7-plus`) — it took over the dead qwen3.5-plus's consumers |
| qwen3.6-plus | ≤256k: 0.50/3.00/0.05/0.625 · >256k: 2.00/6.00/0.20/2.50 | $60 | — | ✅ `tool_use` (raw 2026-09-17, 2.8s) | untested | |
| ~~qwen3.5-plus~~ | **DELISTED** (was console-derived ≈0.25/1.00/0.025) | — | — | 💀 **DEAD — 400 `api_error` "Model is unavailable"** (raw 2026-09-17, 3/3 tries) | 💀 | ⚠ **TRAP: `/v1/models` STILL LISTS IT. The model list is NOT a liveness signal** — probe, never enumerate. Row deleted from `gometer.GO_PRICES` 2026-09-17; former haiku/subagent slot, consumers already repointed to qwen3.7-plus |
| **kimi-k3** | 3.00/15.00/0.30/– | $15 | — | ✅ `tool_use` (raw 08-13; **re-verified 2026-09-17, 9.1s — slowest PASS in the sweep**) | ✅ | current **sonnet slot**; expensive output — sparse big calls |
| kimi-k2.7-code | 0.95/4.00/0.19/– | $60 | — | ⚠ **UNKNOWN — HTTP 500 "Internal server error" at probe time** (raw 2026-09-17); an upstream fault, NOT a compat ✗ — re-probe | untested | priced cheap-slot candidate |
| kimi-k2.6 | 0.95/4.00/0.16/– | $60 | — | untested | untested | |
| kimi-k2.5 | unpriced (absent from the published table) | ? | — | untested | untested | `_GO_MAX_PRICE` fallback applies |
| glm-5.3-flash | 0.15/0.50/0.03/– | $60 | **2× usage** (operator read of the picker, 2026-09-25) | ⚠ **UNKNOWN — HTTP 500 at probe time** (raw 2026-09-17); re-probe | untested | NEW in the 09-17 table; ⚠ the 2× badge makes it a poor failover cell whatever the tool probe says — never a slot pick |
| glm-5.3 | 1.40/4.40/0.26/– | $15 | — | ⚠ **UNKNOWN — HTTP 500 at probe time** (raw 2026-09-17); re-probe | untested | NEW in the 09-17 table (note the $15 pool — its 5.2/5.1 siblings are $60) |
| glm-5.2 | 1.40/4.40/0.26/– | $60 | — | ✗ **422 on EVERY function tool** (raw+claude 08-13) | ✅ but ⚠ drops STRING-shorthand content (free-associates; blocks form fine — shim normalizes) | serves the CLI's auxiliary calls fine; tools work OpenAI-shaped on `/chat/completions` (raw 08-13, `tool_calls`) |
| glm-5.1 / glm-5 | 5.1: 1.40/4.40/0.26/– · glm-5 unpriced | $60/? | — | untested (glm-5.2 class suspected) | untested | |
| **deepseek-v4.1-flash** | off-peak 0.15/0.60/0.003/– · **peak 0.30/1.20/0.006/–** | ~~$15~~ **$60** (4x promo, ends Sep 20) | — | ✅ `tool_use` (raw 2026-09-17, 1.8s) | untested | NEW in the 09-17 table; the promo is published as a RAISED LIMIT, not a badge |
| deepseek-v4-pro | off-peak 0.66/1.98/0.022/– · **peak 1.32/3.96/0.044/–** | $15 | — | ✅ `tool_use` round-trip (raw 08-13, post opt-in) | untested | price CORRECTED 09-17 (was 0.435/0.87/0.003625 — that is mimo-v2.5-pro's row); retro-proven audit tier upstream |
| deepseek-v4-flash | off-peak 0.15/0.60/0.003/– · **peak 0.30/1.20/0.006/–** | **$30** (was recorded $60 — corrected 09-17) | — (2x badge REMOVED 09-17) | ✅ `tool_use` round-trip (raw 08-13, **post China-opt-in** — see quirks; the earlier 403 was the un-toggled gate, not a hard lock). **Re-verified at RIDE level 2026-08-25** (claude harness → proxy Go leg, clean 4-turn tool loop — #778 thread) and again **raw 2026-09-17 (1.8s)**. ⚠ **OpenAI surface (`/chat/completions`) BROKEN as served** (seat probe 2026-08-25): the tool call leaks as raw `<｜DSML｜tool_calls>` markup in `content`, `tool_calls: null` — the glm-shorthand class. Compat is PER-SURFACE: Anthropic ✅ / OpenAI ✗ | ✅ (opencode client, operator 08-13, 1.4s — ⚠ predates the DSML observation) | haiku slot + subagent default. **Prices were WRONG in the 08-13 snapshot** (0.14/0.28/0.0028 — that is mimo-v2.5's row) **and it carried an ungrounded `half=True`**: its window draw is now 2×(0.15/0.14)≈2.1× the old number off-peak, 4.3× at peak |
| deepseek-v4-flash-vision-exp | off-peak 0.15/0.60/0.003/– · **peak 0.30/1.20/0.006/–** | $15 | — | untested | untested | NEW in the 09-17 table. Images are converted to tokens by dimension and billed as INPUT alongside text |
| mimo-v2.5 | 0.14/0.28/0.0028/– | $60 | — | ✗ 400 opaque "Provider returned error" (raw 08-13) → ⚠ re-probed 2026-09-17: **HTTP 500** (upstream fault, verdict still open) | untested | price-optimal 1× — worth the openai/opencode retry before writing off |
| mimo-v2.5-pro | 0.435/0.87/0.003625/– | $15 | — | untested | untested | |
| mimo-v2-pro / mimo-v2-omni | unpriced (absent from the published table) | ? | — | untested | untested | `_GO_MAX_PRICE` fallback applies |
| minimax-m3 | 0.30/1.20/0.06/– | $60 | — | untested | untested | |
| minimax-m2.7 / m2.5 | 0.30/1.20/0.06/0.375 | $60 | — | untested | untested | m2.5 added to `gometer` 09-17 (it is priced but absent from the docs' model LIST) |
| longcat-2.0 | 0.30/1.20/0.006/– | $60 | — | untested | untested | NEW in the 09-17 table; cheapest cached-read of the $60 pool |
| muse-spark-1.3-contributor | 0.10/0.20/0.002/– | $60 | — | ⚠ **GATED — 403 `DataPolicyError`** (raw 2026-09-17): *"this model collects data used to improve its quality"*. An **opt-in gate**, same class as the China opt-in — NOT a hard failure, NOT a ✗ | untested | NEW in the 09-17 table; cheapest row in the whole table. [Limited regions](https://ai.developer.meta.com/legal/geographic-use-policy) |
| muse-spark-1.2-contributor | 0.10/0.20/0.002/– | $60 | — | untested (the 1.3 opt-in gate is expected to apply) | untested | NEW in the 09-17 table |
| hy4-preview | 0.834/2.501/0.042/– | $30 | — | untested | untested | NEW in the 09-17 table |
| hy3 / hy3-preview | hy3: 0.14/0.58/0.035/– · preview unpriced | $60/? | — | hy3: ⚠ **UNKNOWN — HTTP 500 at probe time** (raw 2026-09-17); re-probe | untested | hy3 = retro-proven audit tier upstream |
| **union-alpha** | **FREE / FREE / FREE** — unlimited, *"limited time"* | Unlimited | — | ✅ `tool_use` (raw 2026-09-17, 3.9s) → ✗ **DEAD ONE DAY LATER** | ✗ (same) | NEW in the 09-17 table. A **free, unlimited, tool-capable** row on the Go rail — priced 0.0 in `gometer`, so it draws nothing against the windows. ⚠ **2026-09-18, 7 attempts / 3 paths: `400 Model is unavailable.` on the Go surface (raw ×2 + through the jail shim), `500 Internal server error` on the Zen surface, `UnknownError` from the opencode CLI ×3.** Still LISTED in both catalogs — the qwen3.5-plus trap again, inside 24h. The "limited time" wording was the risk and it fired: a $0-unlimited row would sort FIRST on any price-ordered pick, so nothing may chain it until a probe says otherwise |
| grok-4.6 | ≤200k: 2.00/6.00/0.50/– · >200k: 4.00/12.00/1.00/– | $15 | — | untested | untested | NEW in the 09-17 table |
| ~~grok-4.5~~ | **unpriced** (delisted from the published table 09-17) | ? | — | untested | untested | Still SERVED, so it now takes the `_GO_MAX_PRICE` fallback like the other served-but-unpriced ids — its old 2.00/6.00/0.30 row was ungrounded and was dropped rather than carried |
| gpt-5.6-luna | ≤272k: 0.20/1.20/0.02/0.25 · >272k: 0.40/1.80/0.04/0.50 | $15 | — (2x badge REMOVED 09-17) | ✗ **400 empty-body (raw 08-17), tools AND `tool_choice`-forced** — response is a message-shaped shell (`chatcmpl_` id, empty text, `stop_reason:null`) over HTTP 400 | ✗ **plain text ALSO 400s (raw 08-17)** — the ONLY row broken on the compat surface even without tools | ✅ works in the **opencode client** (operator Build session 08-13, 2.8s); ✅ **OpenAI surface `/chat/completions` + function tool → clean `tool_calls` (raw 08-17)** — cheapest cached-read in the table; the translator (shim, #448 — closed 2026-08-17) serves it from claude-code lanes via the OpenAI surface. Its ungrounded `half=True` was removed 09-17 → its window draw DOUBLED |

## OpenCode Zen free tier (`https://opencode.ai/zen/v1`, same key)

Candidate rung-0 on this rail (largely the OpenRouter free-rung families). ⚠ Zen paid carries
`claude-*` — never route claude there; the Anthropic subscription exists.

⚠ **THE FREE TIER ADMITS NO API CLIENT — it is reachable only from the opencode CLI.** The
vendor says so in the error body: `Error from provider (Console): OpenCode's free tier can only
be used from within OpenCode` (probed 2026-09-18 through the shim's translator leg, every free
id, ~0.4s). The CLI serves the same ids from the same jail and the same IP, anonymously. This
retires the "small per-account free **usage quota**" reading recorded on homelab#946 on
2026-08-31: the 18 straight `429 Rate limit exceeded` / `FreeUsageLimitError` responses that
killed that seed run were this gate wearing a rate-limit costume, which is why replicating UA,
`stream` and `max_tokens` never helped and why the CLI sustained three 16–36 KB review prompts
back-to-back an hour later. Consequence for instruments: an evidence run over these ids invokes
`opencode run -m <id>` (`agents/re-review.sh` does, since 2026-09-18) — the API path for a free
id cannot be made to work and is not worth a retry ladder.

| model | anthropic-compat tools | notes |
|---|---|---|
| deepseek-v4-flash-free | ✗ 400 invalid_request (raw 08-13, provider error truncated) | |
| mimo-v2.5-free | ✗ 400 opaque provider error (raw 08-13) | |
| hy3-free · nemotron-3.5-lightning-free · laguna-s-2.1-free | untested | |
| **big-pickle** | **OpenAI surface ✅ FULL tool loop** (seat probes 2026-08-25, via the in-cluster proxy zen leg — homelab#778 thread): plain ✅, `tool_calls` emission ✅, tool-result consumption ✅ | **REASONING model**: a small `max_tokens` is eaten entirely by `reasoning_content` (content null at 20 tokens) — give cells headroom; one schema-adherence miss observed (`file_path` for required `path`), loop-survivable. Anthropic surface untested. **Ruled role (operator 2026-08-25, #778): deepseek's $0 SHADOW** — A5 shadow re-reviews (homelab#923) + the G-E fan-out arm; not a solo-ride slot until a rung-2 canary |
| nemotron-3-ultra-free | plain text ✅ 200 · function tool ✗ 400 — **bisected to the SURFACE (raw curl, seat 08-14)**: OpenAI `/v1/chat/completions` + function tool → ✅ clean `tool_calls`; Anthropic `/v1/messages` + the same tool as `input_schema` → ✗ 400 upstream `Input required: specify "prompt" or "messages"` (the compat translation loses the body). Minimal curl — NOT harness decoration. Same provider-400 family as the deepseek/mimo free rows | opencode client rides the OpenAI surface → tools work there (operator's opencode run, 08-14: clean 4-step shell loop — date → write → read-back → confirm — incl. the tool-result continuation); claude-code is Anthropic-only → this rail can't serve tool lanes until zen fixes the compat layer or a translator lands. **Tool-lane rung-0 candidate once translated.** translator (shim, #448) serves this via the OpenAI surface as of 2026-08-17 |

## Cross-cutting quirks (apply to every row)

- `/v1/messages` demands **`x-api-key`** (Bearer-only → 401 "Missing API key"); `/v1/models`
  takes Bearer alone. Send both (the shim does).
- claude-code's `?beta=true` query + `anthropic-beta` headers → **422 empty-body**; the shim
  strips them on the Go leg.
- Cloudflare 1010-blocks the `python-urllib` UA (probe artifact — set a UA or use curl).
- **No pricing / multiplier / usage / quota API** — this file + the vendor's docs page ARE the
  registry; windows are self-metered (charter §Go rail).
- **`/v1/models` is a CATALOG, not a LIVENESS signal** (2026-09-17): `qwen3.5-plus` is still
  listed and 400s on every call. Never infer availability from enumeration — probe.
- **Prices can be TIME-VARYING** (2026-09-17): the four DeepSeek rows are 2× during
  Mon-Fri 01:00-04:00 / 06:00-10:00 UTC. Any price arithmetic must carry a timestamp;
  `gometer.is_peak(now)` is the one implementation.
- **An HTTP 500 from the rail is an UPSTREAM fault, not a compat verdict.** The 2026-09-17
  sweep hit 500s on five ids in one window; they are recorded ⚠ UNKNOWN, not ✗, precisely so a
  transient outage cannot poison the register the way a ✗ would (a ✗ here suppresses re-probes).
- **claude-code treats Go ids as UNKNOWN models** → it assumes a 200k context window and
  auto-compacts to it (warning observed on the 2026-08-17 canary). Harmless for xs/sm rides;
  a long ride on a model whose REAL window is smaller can overrun it. Probe each slot model's
  true window and pin `CLAUDE_CODE_MAX_CONTEXT_TOKENS` (or `modelOverrides`) per model —
  flash's window is UNVERIFIED.
- **The China-hosting opt-in** (workspace setting, toggled 2026-08-13): `deepseek-*` 403s with
  `RegionError` until the workspace UI knob is flipped — a per-workspace gate, not a hard region
  lock. If a fresh workspace ever reappears 403s on deepseek, check the knob first.
- Probe recipes live in TICK-LOG 2026-08-13 (the raw python snippets); the shim's
  `SHIM_DEBUG_BODY` dumps real claude-code bodies for bisects.

## What settles this spike

Full coverage of the Go list + Zen free tier on the anthropic-compat path (one `tool_use`
round-trip each — cents; deepseek rows CLOSED 08-13 post-opt-in), one `opencode`-harness
column datum for a model the compat path fails (mimo or glm — does their native client succeed
where the shim can't?). (The badge-semantics decider RESOLVED in this file — billing 08-13,
limit-side 08-17.) Then the table
graduates into the scout's Go-rail canary duty (charter build order step 2) and this spike
becomes its seed data.
