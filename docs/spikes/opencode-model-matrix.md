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

**Prices**: snapshotted from https://opencode.ai/docs/go/ (2026-08-13) — the ONLY price source;
the API (`/v1/models`) returns bare ids. $/M tokens: in / out / cached-read / cached-write.
"Usage" = the docs' per-model column ($15 or $60). "Badge" = the picker's "(Nx usage)" marker.
✅ **Badge semantics RESOLVED for BILLING (console dump, 2026-08-13 18:28):** every itemized
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

## OpenCode Go (subscription rail, `https://opencode.ai/zen/go/v1`)

| model | $/M in/out/cR/cW | Usage | badge | anthropic-compat tools | text (compat) | notes |
|---|---|---|---|---|---|---|
| **qwen3.5-plus** | undocumented — **DERIVED from console billing 08-13**: ≈0.25/1.00/0.025/? (three 40k-in rows → $0.0102 ⇒ in $0.25/M; cached 41k row → $0.0010 ⇒ cR $0.025/M; 265-out row → $0.0003 ⇒ out ≈$1/M) | ? | — | ✅ `tool_use` round-trip (raw 08-13) + **live subagent w/ Bash tool** (claude 08-13) | ✅ | PRIOR haiku slot + subagent default (superseded by the flash promotion, 2026-08-13 — launch-frozen sessions may still ride it); undocumented id, rates now console-derived |
| **kimi-k3** | 3.00/15.00/0.30/– | $15 | — | ✅ `tool_use` (raw 08-13) | ✅ | current **sonnet slot**; expensive output — sparse big calls |
| **qwen3.8-max** | 2.00/6.00/0.25/2.50 | $15 | — | ✅ (go-session probe 08-13; not independently re-verified) | ✅ | current **opus slot** |
| glm-5.2 | 1.40/4.40/0.26/– | $60 | — | ✗ **422 on EVERY function tool** (raw+claude 08-13) | ✅ but ⚠ drops STRING-shorthand content (free-associates; blocks form fine — shim normalizes) | serves the CLI's auxiliary calls fine; tools work OpenAI-shaped on `/chat/completions` (raw 08-13, `tool_calls`) |
| glm-5.1 / glm-5 | 5.1: 1.40/4.40/0.26/– · glm-5 unpriced | $60/? | — | untested (glm-5.2 class suspected) | untested | |
| deepseek-v4-flash | 0.14/0.28/0.0028/– | $60 | 2x | ✅ `tool_use` round-trip (raw 08-13, **post China-opt-in** — see quirks; the earlier 403 was the un-toggled gate, not a hard lock) | ✅ (opencode client, operator 08-13, 1.4s) | cheapest priced tool-caller on every axis (cR 9× under qwen3.5-plus's derived rate) — **PROMOTED to haiku slot + subagent default 2026-08-13** (billing-semantics resolved; applies from the next claude-go launch) |
| deepseek-v4-pro | 0.435/0.87/0.003625/– | $15 | — | ✅ `tool_use` round-trip (raw 08-13, post opt-in) | untested | retro-proven audit tier upstream; sonnet/opus-slot candidate |
| mimo-v2.5 | 0.14/0.28/0.0028/– | $60 | — | ✗ 400 opaque "Provider returned error" (raw 08-13) — encoding unknown, openai-shaped + opencode-client paths UNTESTED | untested | price-optimal 1× — worth the openai/opencode retry before writing off |
| mimo-v2.5-pro | 0.435/0.87/0.003625/– | $15 | — | untested | untested | |
| mimo-v2-pro / mimo-v2-omni | unpriced (absent from docs) | ? | — | untested | untested | |
| kimi-k2.7-code | 0.95/4.00/0.19/– | $60 | — | untested — **named next-probe** (priced cheap-slot candidate) | untested | |
| kimi-k2.6 | 0.95/4.00/0.16/– | $60 | — | untested | untested | |
| kimi-k2.5 | unpriced (absent from docs) | ? | — | untested | untested | |
| minimax-m3 | 0.30/1.20/0.06/– | $60 | — | untested | untested | |
| minimax-m2.7 / m2.5 | 0.30/1.20/0.06/0.375 | $60 | — | untested | untested | |
| qwen3.7-max | 2.50/7.50/0.50/3.125 | $60 | — | untested | untested | |
| qwen3.7-plus | ≤256k: 0.40/1.60/0.04/0.50 · >256k: 1.20/4.80/0.12/1.50 | $60 | — | untested | untested | |
| qwen3.6-plus | ≤256k: 0.50/3.00/0.05/0.625 · >256k: 2.00/6.00/0.20/2.50 | $60 | — | untested | untested | |
| gpt-5.6-luna | ≤272k: 0.20/1.20/0.02/0.25 · >272k: 0.40/1.80/0.04/0.50 | $15 | 2x | untested via claude/raw | untested via raw | ✅ works in the **opencode client** (operator Build session 08-13, 2.8s) — cheapest cached-read in the table |
| grok-4.5 | 2.00/6.00/0.30/– | $15 | — | untested | untested | |
| hy3 / hy3-preview | hy3: 0.14/0.58/0.035/– · preview unpriced | $60/? | — | untested | untested | hy3 = retro-proven audit tier upstream |

## OpenCode Zen free tier (`https://opencode.ai/zen/v1`, same key)

Candidate rung-0 on this rail (largely the OpenRouter free-rung families). ⚠ Zen paid carries
`claude-*` — never route claude there; the Anthropic subscription exists.

| model | anthropic-compat tools | notes |
|---|---|---|
| deepseek-v4-flash-free | ✗ 400 invalid_request (raw 08-13, provider error truncated) | |
| mimo-v2.5-free | ✗ 400 opaque provider error (raw 08-13) | |
| hy3-free · nemotron-3.5-lightning-free · laguna-s-2.1-free · big-pickle | untested | |
| nemotron-3-ultra-free | plain text ✅ 200 · function tool ✗ 400 — **bisected to the SURFACE (raw curl, seat 08-14)**: OpenAI `/v1/chat/completions` + function tool → ✅ clean `tool_calls`; Anthropic `/v1/messages` + the same tool as `input_schema` → ✗ 400 upstream `Input required: specify "prompt" or "messages"` (the compat translation loses the body). Minimal curl — NOT harness decoration. Same provider-400 family as the deepseek/mimo free rows | opencode client rides the OpenAI surface → tools work there (operator, 08-14); claude-code is Anthropic-only → this rail can't serve tool lanes until zen fixes the compat layer or a translator lands |

## Cross-cutting quirks (apply to every row)

- `/v1/messages` demands **`x-api-key`** (Bearer-only → 401 "Missing API key"); `/v1/models`
  takes Bearer alone. Send both (the shim does).
- claude-code's `?beta=true` query + `anthropic-beta` headers → **422 empty-body**; the shim
  strips them on the Go leg.
- Cloudflare 1010-blocks the `python-urllib` UA (probe artifact — set a UA or use curl).
- **No pricing / multiplier / usage / quota API** — this file + the console ARE the registry;
  windows are self-metered (charter §Go rail).
- **The China-hosting opt-in** (workspace setting, toggled 2026-08-13): `deepseek-*` 403s with
  `RegionError` until the workspace UI knob is flipped — a per-workspace gate, not a hard region
  lock. If a fresh workspace ever reappears 403s on deepseek, check the knob first.
- Probe recipes live in TICK-LOG 2026-08-13 (the raw python snippets); the shim's
  `SHIM_DEBUG_BODY` dumps real claude-code bodies for bisects.

## What settles this spike

Full coverage of the Go list + Zen free tier on the anthropic-compat path (one `tool_use`
round-trip each — cents; deepseek rows CLOSED 08-13 post-opt-in), one `opencode`-harness
column datum for a model the compat path fails (mimo or glm — does their native client succeed
where the shim can't?), and the badge-semantics decider from the console. Then the table
graduates into the scout's Go-rail canary duty (charter build order step 2) and this spike
becomes its seed data.
