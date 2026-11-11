# Launcher routing — the launcher's half of the old routing rules

> Moved here from [`docs/agents/model-routing.md`](../../../../docs/agents/model-routing.md) §The
> carriers and §The strike ladder (island specs spike, 2026-11-07): the rules whose anchor is
> `agents/agent-session.sh`. The router's rules — the ladder, the strike vocabulary and its scopes,
> the pair cooldown, the override rules of the other launchers — stay there.

**Every rule on this page is old contract.** It is the launcher choosing for itself, which the
gateway's `POST /sessions` retires
([admission.md LAUNCH-ADMIT-NO-MODEL](../specs/admission.md#launch-admit-no-model) counts the sites;
[outcome.md](../specs/outcome.md) holds the strike side's `⚑ gap` rows). A gateway ride skips all of
it; every other ride still runs it. The rules keep their anchor and evidence lines as written, so the
deletion PR can check each one off.

## The rail degrade and the chainless guard

- **OpenRouter capacity-down ≠ budget-spent.** A project-key headroom exhaustion stops the
  dispatch (a budget decision); an ACCOUNT-scope failure (credit floor, hard 402, cross-model 429s)
  degrades it to `claude/haiku` on the subscription instead — an infra failure, the same class as
  a 5xx.
  - anchor: `openrouter-proxy.py` (the `_or_capacity_*` block) types it; `agents/agent-session.sh`
    decides via three triggers (routed defer typed `or-capacity-down:*` in authoritative mode;
    `/router-status` → `.openrouter_capacity.down` in all modes; the credit floor).
  - evidence: `agents/rail-degrade-replay.sh` (CAP…CAP9, FAILOPEN…); replays
    `agents/replay/fixtures/rail-degrade`, `agents/replay/fixtures/go-rail-latch`;
    `router_openrouter_capacity_down`, `router_openrouter_account_credit_usd`.
- **The degrade's bounds are the rule**: `class=fix` only, semaphore-bounded (the degraded ride IS
  a claude ride, so FU-088 gates it unchanged), per-stack opt-out
  (`subscriptionFallback: false` / `AGENT_SUBSCRIPTION_FALLBACK=0`, read `== false` never
  `// false`), and the claim's `modelDeny` binds.
  - anchor: `agents/agent-session.sh` (the degrade branch).
  - evidence: `agents/replay/fixtures/rail-degrade` rows.
- **A degrade is visible on three surfaces**: the pod label
  `homelab.teststuff.net/rail`, the `AGENT_RAIL` pod env, and the launcher's `POST /report` field.
  - anchor: `agents/agent-session.sh`; `router.py:record_report` (`run_reports.rail`).
  - evidence: `router_run_reports_by_rail_total{rail="subscription-fallback"}`.
- **Key-read discipline: read the boolean, never `reason`.** The proxy publishes
  `openrouter_capacity.reason` unconditionally while `down` is the latched verdict — a
  reason-keyed read would degrade the fleet forever from the first 429; an unavailable balance is
  *no balance* (fail-open with one visible line), never a low one.
  - anchor: `agents/agent-session.sh` (the `GET /router-status` read).
  - evidence: replay `agents/replay/fixtures/rail-degrade` (CAP5 the stale-`reason` trap, CAP4 the
    lost payload).
- **A platform claim is chainless when it has no chain** and refuses a chainless dispatch without
  an authoritative verdict.
  - anchor: `agents/agent-session.sh` `REPLAY:chainless-guard`; [the platform stack](../../../../docs/agents/agentstack.md) went chainless
    at `routerMode: authoritative` 2026-09-19 (Goal #1640 acceptance 6 — homelab#1782/#1783/#1787), the fleet's
    last static chain.
- - **Except the platform stack's worker rides, flipped to the gateway (FU-270 (c), 2026-10-21):**
  the coordinator session pod carries `AGENT_GATEWAY=sessions`, so
  [`agents/agent-session.sh`](../../../agent-session.sh) admits them through the gateway's
  `POST /sessions` ([UC-1](../../../../gateway/specs/use-cases/uc-1-worker-ride.md)) and never calls
  `/route`; the knob is pod env, not a claim field.

## The strike comment and its readers

- **A key-class budget error is NOT a strike.** `budget-403-key` / `budget-exhausted-key` are a
  mint defect → a `KEY-RETRY:` marker, same model, fresh session key.
  - anchor: `agents/agent-session.sh` (the `KEY-RETRY` branch).
  - evidence: the `KEY-RETRY:` comment; `devbox run clause-replay` over
    `agents/replay/fixtures/strike-quota-classifier` (the classification it rides on).
- **The raw-log fallback emits the finer subclasses** when no structured report exists
  (`budget-403-key`, `budget-403-account`, `http-403-other`) — the residual `budget-403` is
  neither a strike nor a key-retry and escalates. Goose's one-line 402 rendering (`add more
  credits`) is key-class, not residual, by the 2026-10-15 operator ruling (retro r8 F3): the
  credit-floor gate (FU-088b) already defers dispatch on a low account.
  - anchor: `agents/agent-session.sh` (the classify block).
  - evidence: replay `agents/replay/fixtures/strike-quota-classifier` (three branches); the
    comment's `error_class=`.
- **The launcher retries at worker-terminal.** `AGENT_STRIKE` ∧ salvage verdict `none` ∧ class ∈
  {serving-shaped, `turn-cap`} ∧ attempts < cap (one automatic retry per
  `(model, provider, class)`, two per task) ⇒ `/route` again and re-run at the SAME round — no
  scan re-queue, no coordinator session; cap reached ⇒ the strike list + doorbell as today.
  - anchor: `agents/agent-session.sh` (the `REPLAY:strike-retry` block — Goal #1640 acceptance 4,
    landed via PR#1934).
  - evidence: replay `agents/replay/fixtures/strike-retry`.
- **The strike comment remains the store FOR NOW, with a named debt**: migrate the strike READERS
  (the chain-walk, the ≥2-in-24h rule) to the router store's `strikes` table, then demote the
  comment to one appended line on the `agent-summary` index.
  - anchor: `agents/agent-session.sh` (the writer) + `agents/coordinator-scan.sh` (the reader).
  - evidence: replay `agents/replay/fixtures/fleet-strike-reader`.
  - **`unenforced`** for the migration — operator ruling 2026-08-19; blocked on the router's
    storage-engine question settling. Proposed, no owner.
