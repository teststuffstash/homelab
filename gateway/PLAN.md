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
[`model-routing.md`](../docs/agents/model-routing.md) (the ladder), `agents/specs-reviewer-session.sh` (the live consumer),
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

### 3. Specs-reviewer cell experiments — harnesses × rails through the gateway, in shadow

Operator (2026-10-16): exercise the gateway with the specs reviewer, its one live consumer, instead
of moving the worker launcher — the blast radius is the gateway build, nothing else. The launcher
move (`agents/agent-session.sh`) is NOT part of tonight.

- **Shadow mode in `agents/specs-reviewer-session.sh`:** a run that takes an explicit `harness`
  (and an optional `rail` override — both are `POST /sessions` inputs already) and a PR list,
  builds the SAME context pack, runs the brief, and writes the verdict + findings to a file/S3
  object — it **never submits a review, comments or labels** (assert it: the shadow path has no
  `gh` write call; a fixture/self-test row proves it). The live cron path is unchanged.
- **The cells:** `claude@anthropic` (today's, the control), `claude@opencode` (claude on the
  [Go rail](../docs/agents/chainless-redesign.md)), `opencode@opencode` (deepseek), `goose@openrouter`. Codex has no cell —
  its rail ships dark (step 2). Each non-claude cell first proves its `GW-SESSIONS-ENV` "⚖ (verify)"
  rows: whatever the pinned CLI really reads is what the rows say (if that is
  `OPENCODE_CONFIG`'s `baseURL`/`apiKey` or goose's `OPENROUTER_HOST`, the GATEWAY's env changes,
  not the harness), and the confinement contract (`env -i` + the dispatch env) holds for it.
- **Where it runs:** the cluster, as one-off runs of the specs-review WorkflowTemplate shape with
  the shadow parameters; the opencode/goose cells need an image carrying those CLIs (the
  agent-base family) — pick the existing image that has them, never build a new one tonight.
- **The corpus:** merged specs PRs with KNOWN verdicts — #2635 (r1 blocked on a missing
  `Spec changes:` section), #2640 (r1 blocked on the GET row the diff missed — a true positive),
  #2628, #2631 — each PR at the head the live reviewer judged. Bounded: ≤ 4 cells × ≤ 4 PRs × 1
  run; the openrouter cell under its session key's budget.
- **The output:** one table — cell × PR → verdict, the known findings caught/missed, invalid
  findings, tokens by class (the session row), wall clock, timeouts — written into
  [`specs-reviewer.md`](../docs/agents/specs-reviewer.md)'s measurement section (ADR-156 step 5's
  "per completed PR" numbers), with the raw files linked. A comparison, not a ruling: which cell
  the live reviewer rides stays the operator's call.

**Settles:** every cell either completes the corpus or names the row/harness gap that stopped it
(a failed env row is a finding, not a skip); the ⚖ (verify) rows on the openai dialect are
resolved one way or the other; no review, comment or label written by a shadow run (check the
four PRs' timelines).

## Boundaries — what the unattended session never does

- Touch `argocd/resources/openrouter-proxy/` or `agents/agent-session.sh`, or change which cell the LIVE
  specs reviewer rides (shadow runs only).
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
  is parked and why, the shadow table's state), a TICK-LOG entry, FU-270's next steps updated, monitors
  killed, this file deleted or trimmed to what remains.
