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
⚠ **Badge/Usage semantics UNRESOLVED** — "2x usage" may mean a DOWNGRADED value pool
($20/mo vs $60; the docs' "6x… for some models lower" reading) **or the operator's half-off
reading (you get 2× usage per $)**. Decider: console per-model usage-$ vs list-price math on
known traffic (no API for it). Until then no window accounting builds on either reading.
Charter §Go rail carries the same flag.

## OpenCode Go (subscription rail, `https://opencode.ai/zen/go/v1`)

| model | $/M in/out/cR/cW | Usage | badge | anthropic-compat tools | text (compat) | notes |
|---|---|---|---|---|---|---|
| **qwen3.5-plus** | **UNPRICED** — absent from docs table AND picker | ? | — | ✅ `tool_use` round-trip (raw 08-13) + **live subagent w/ Bash tool** (claude 08-13) | ✅ | current **haiku slot** + subagent default; undocumented id — pricing may surprise |
| **kimi-k3** | 3.00/15.00/0.30/– | $15 | — | ✅ `tool_use` (raw 08-13) | ✅ | current **sonnet slot**; expensive output — sparse big calls |
| **qwen3.8-max** | 2.00/6.00/0.25/2.50 | $15 | — | ✅ (go-session probe 08-13; not independently re-verified) | ✅ | current **opus slot** |
| glm-5.2 | 1.40/4.40/0.26/– | $60 | — | ✗ **422 on EVERY function tool** (raw+claude 08-13) | ✅ but ⚠ drops STRING-shorthand content (free-associates; blocks form fine — shim normalizes) | serves the CLI's auxiliary calls fine; tools work OpenAI-shaped on `/chat/completions` (raw 08-13, `tool_calls`) |
| glm-5.1 / glm-5 | 5.1: 1.40/4.40/0.26/– · glm-5 unpriced | $60/? | — | untested (glm-5.2 class suspected) | untested | |
| deepseek-v4-flash | 0.14/0.28/0.0028/– | $60 | 2x | ✅ `tool_use` round-trip (raw 08-13, **post China-opt-in** — see quirks; the earlier 403 was the un-toggled gate, not a hard lock) | ✅ (opencode client, operator 08-13, 1.4s) | cheapest PRICED tool-caller; haiku-slot candidate once the 2x-badge semantics resolve |
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
| hy3-free · nemotron-3-ultra-free · nemotron-3.5-lightning-free · laguna-s-2.1-free · big-pickle | untested | |

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
