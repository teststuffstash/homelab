# agent-gateway — overnight unattended build plan (2026-10-16 → 17)

Transient: the brief for ONE unattended seat session. Delete this file in the session's last
commit once the steps below are done or handed to the pickup (meta-state). Status lives in
[FU-270](../docs/follow-ups.md); the contract is [`specs/`](specs/README.md); the design behind
the order is [context-and-autonomy.md §The plan](../docs/spikes/context-and-autonomy.md#the-plan-ordered-each-step-one-session--one-pr--a-settle-number)
(P2) and [ADR-139](../docs/adr.md#adr-139--the-egress-proxys-shape-the-git-broker-leaves-the-gateway-becomes-its-own-project-ha-waits-for-a-measured-store-2026-09-21)
(amended 2026-10-16).

## Where it starts

LIVE on `g02fbba54`: three rails, `POST /sessions`, four token classes + the subscription window
gauges (canary 2026-10-16). One consumer: the specs reviewer (ADR-155). The old
`openrouter-proxy` stays untouched (operator, 2026-10-15). The Codex rail is proven OFFLINE in
`experiments/codex-rail/` (#2625, #2642; [the spike](../docs/spikes/codex-subscription-rail.md#gateway-prototype--isolated-build-2026-10-16-fu-270)).

## Session shape

The seat coordinates; builders are subagents in their OWN clones (never the shared tree), one PR
per step, both reviewers gate (ADR-155: specs changes need the specs reviewer's approval too —
every PR body carries a `Spec changes:` section). Waits are `pr-wait` in the background. Grounding
slice (no `/design-agents` load — it is operator-typed only): `gateway/` + specs,
[`model-routing.md`](../docs/agents/model-routing.md) (the ladder), the launcher seams named below,
the Codex spike + `experiments/codex-rail/README.md`, ADR-096/112/139/155/156.

## Steps — in merge order; builders may run in parallel, merges do not

### 1. The ladder's capacity half as admission rows (FU-270 next 2)

`POST /sessions` defers instead of the caller polling two limit endpoints (§Interfaces are redrawn).
Add to `GW-SESSIONS-ADMIT`, each a row + world + test, values in `policy.json` (never code literals):

- **anthropic utilization defer** — a window whose last-seen utilization ≥ its threshold defers
  until that window's reset (`retry_after_s` = reset − now); per-window thresholds, today's values
  copied from the old proxy's `ANTHROPIC_UTIL_THRESHOLD*` (⚖ — cite them in the row). Stale data
  (no header for N minutes) admits, never blocks: an unavailable reading is no reading.
- **429 latch per rail** — an upstream 429 on a rail defers that rail's new sessions until
  `retry-after` (default the old proxy's hold), any 2xx on the rail clears it.
- **Go window draw** — the opencode rail's window draw priced from the four token classes
  (gometer's `window_draw` semantics: list rates, cache classes at their own rates), defer at the
  window threshold. Prices are policy data with a pointer to their gometer source (⚖ duplicate
  until the old proxy retires — say so in the row).

Out of scope tonight: strikes, pair cooldowns, `/route`'s class/tier/cell walk (the router keeps
them; [§Who owns which fact](../docs/agents/model-routing.md#who-owns-which-fact)).
**Settles:** the three rows green with red-on-base evidence; deployed; `gateway_sessions_total
{decision="defer"}` shows no defer that the old proxy's `/anthropic-limit` / `/opencode-limit`
would not also give at the same moment (read both once, after the deploy).

### 2. The Codex rail into the gateway, offline (spike acceptance step 3)

Port, not rebuild — `experiments/codex-rail/` modules move under `gateway/src/` with their tests
becoming GW rows:

- a `responses` dialect (`/openai/v1/responses`; today's `openai` stays Chat Completions) and a
  `GW-RAIL-CODEX` page + schema sibling: session/model boundary, header replacement, SSE
  passthrough with terminal `response.usage` counted once into the four classes, truncation/failure
  outcomes, cancellation, HTTP failure mapping;
- headroom as admission (account-wide observations, freshness, out-of-order rejection) — the same
  defer shape as step 1;
- the OAuth lifecycle behind its persistence interface with the FAKE store only; the production
  write-back stays `⚑ gap` (Infisical is the source of truth — [secrets doctrine](../docs/secrets.md)),
  as does authenticated report ingress;
- `GW-SESSIONS-ENV`: the codex harness's env row replaces the `⚑ gap: codex` row, from what
  `compat.py` observed the CLI read;
- `experiments/codex-rail/compat.py` re-pointed at the gateway's adapter: one evidence row that the
  pinned Codex CLI completes the loopback fixture through it.

The DEPLOYED policy (`argocd/resources/agent-gateway/configmap-policy.yaml`) gets **no** codex rail
— the code ships dark. **Settles:** `GW-RAIL-CODEX` rows green, spec gate 0 red, the experiment
directory reduced to the native-CLI compat harness (or removed if the evidence row covers it).

### 3. The launcher's first worker consumer (FU-270 next 1)

`agents/agent-session.sh` gains a gateway branch for the platform `worker` role (policy: harness
`opencode`, rail `opencode`), behind a launcher flag that defaults OFF:

- `POST /sessions` replaces, for that ride only, the `/route` consult, the capacity reads and the
  hand-assembled harness env (the `CLAUDE_ENV` / `GOOSE_PROXY_ENV` / `OC_ENV` blocks): `defer` →
  the launcher's existing typed-defer path with `retry_after_s`; `dispatch` → the `env` copied into
  the pod spec verbatim, the session id recorded, `DELETE /sessions/{id}` at the ride's end (TTL is
  the belt). The router `/report` (strike store) keeps being written — the router still owns
  strikes.
- First resolve the `GW-SESSIONS-ENV` "⚖ (verify)" rows: run the pinned opencode (and goose) CLI
  against a loopback upstream and record which vars it honours. Whatever the CLI really reads is
  what the rows say — if that is `OPENCODE_CONFIG`'s `baseURL`/`apiKey`, the gateway's env changes,
  not the harness.
- A replay fixture for the new branch (ADR-103 ratchet: red on the pre-fix launcher); the
  merge-path/FSM lints the touched clauses require.

**Canary, the one live act tonight:** ONE ad-hoc platform worker ride with the flag on, on the
opencode-go rail. **Settles:** the ride ends clean; its session row shows `requests > 0` and
non-zero token classes; the pod env holds no real key; the session is released. The default stays
OFF — the flip is the operator's, in the morning.

## Boundaries — what the unattended session never does

- Touch `argocd/resources/openrouter-proxy/` or move any production consumer (the flag stays off).
- Mint, read or write a real Codex/OpenAI credential, write Infisical, or run a Codex canary
  (the spike's step 4 is a separately authorized maintenance window).
- Edit governance files (`.github/workflows/**`, `.agents/review.md`, CODEOWNERS, rulesets).
- File new FUs (extend FU-270), amend ADRs for per-class detail, or load the design-agents corpus.
- Retry a reviewer finding that asks for a design fork: park that PR and write it in the pickup.

## Stop rules and wind-down

- A gateway deploy that breaks the specs reviewer's rides or `/healthz` → revert the image pin PR
  first, then diagnose (the pinned-image revert class, ADR-139).
- A step blocked on an operator decision → leave its PR open, unarmed, named in the pickup; go on to
  the next step.
- Wind down ~50 k tokens before the context cap: a `meta-state.md` PICKUP bullet (what merged, what
  is parked and why, the flag's state), a TICK-LOG entry, FU-270's next steps updated, monitors
  killed, this file deleted or trimmed to what remains.
