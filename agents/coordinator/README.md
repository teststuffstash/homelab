# agents/coordinator — the coordinator brief

The **coordinator** is the cockpit's brain: it watches `agent-fix` work, decides what to dispatch,
sizes a budget, spawns a scoped worker pod per round, and drives the review loop to a merge. v1 is
an **interactive Claude Code session** that loads *this file as its brief* and follows the runbook
below by hand — structured, not autonomous. The structure is the point: the same brief survives the
move from hand-driven → a real workflow engine later.

## Design rule (keep every door open)

**State lives in GitHub labels + CRs, never in the coordinator's head.** The coordinator is a
*level-triggered reconciler*: it can crash, restart, or be a different person/agent and pick up
exactly where things are by re-reading labels. That property is what makes graduating to a durable
engine (Temporal / Argo Workflows+Events / a CRD+controller / Camunda-Zeebe) a mechanical swap
rather than a rewrite. Until then, "the engine" is this brief + your judgement.

## State machine (labels on the issue/PR)

| Label | Meaning | Set by |
|---|---|---|
| `agent-fix` | opt-in: this issue is fair game for the agent | human |
| `agent/queued` | ready to dispatch | human or coordinator |
| `agent/in-progress` | a worker pod is running this round | coordinator |
| `agent/review` | PR open, awaiting review (human or agent) | coordinator |
| `agent/blocked` | needs a human (budget escalate / max rounds / ambiguous) | coordinator |
| `agent/done` | merged | coordinator |
| `agent-budget/{xs,sm,md,lg}` | optional cap-tier override for the estimator | human |

Invariants: **one active worker per PR**; **bounded rounds** (max 3, then `agent/blocked`);
idempotency key `(issue, base-sha, round)` so a re-list/redelivery never double-spawns.

## Per-issue runbook (what the interactive coordinator does)

1. **List** open `agent-fix` issues; pick one labelled `agent/queued` (level-triggered — just
   re-read the world each pass).
2. **Read + estimate.** `gh issue view <N> --json title,body` → pipe to the budget estimator:
   ```sh
   gh issue view <N> --repo teststuffstash/<project> --json title,body -q '.title+"\n"+.body' \
     | devbox run estimate-budget -- --model <model> \
           --project <project> --session issue-<N>-round-<r> --emit-cr
   ```
   If the estimate sets `escalate` (above the `lg` tier) → label `agent/blocked`, comment the
   numbers, stop. Humans review the *fixer*, but they also gate an unusually expensive run.
3. **Mint the per-session budget.** Apply the emitted ephemeral `OpenRouterKey` CR (hard `budgetUSD`,
   no reset, `expiresAt`); the openrouter-operator writes `<project>-session-issue-<N>-round-<r>-openrouter`.
   This is the real breaker — the worker can't outspend it (see [`../README.md`](../README.md) §budget).
4. **Dispatch a fresh worker** for this round and relabel `agent/in-progress`:
   ```sh
   devbox run agent-session -- <project> --harness <goose|opencode> --model <model> \
       --run "goose run --recipe .agents/fix.yaml --params issue=<N>"
   ```
   (The worker consumes the session Secret, not the standing key — wiring TODO, see below.)
5. **Watch.** The run streams logs + drops an `AGENT_RUN_STATS` line and a PR stats comment. When a
   PR opens → relabel `agent/review`.
6. **Drive the round.** Review the PR (humans only ever review the fixer's diff):
   - approved + CI green → **merge** → `agent/done`; delete the session CR.
   - changes requested (by human *or* a reviewer agent) and `round < max` → bump round, go to step 2
     with a **fresh** pod + **fresh** session key.
   - `round == max` or ambiguous → `agent/blocked` + comment.
7. **Clean up.** Delete the ephemeral `OpenRouterKey` CR (its `expiresAt` is the backstop).

## Runtime

- **v1 — interactive, anywhere.** Run a Claude Code session with this file as the brief and follow
  the runbook. Works from the jail today (it already has `kubectl`, the repo, and the launchers).
- **Target — a coordinator pod** (mirrors `agent-session.sh`): Claude Code in a pod with the homelab
  repo cloned, a **scoped** kubeconfig/ServiceAccount (spawn agent pods + apply `OpenRouterKey` CRs +
  read issues), and subscription auth via **`CLAUDE_CODE_OAUTH_TOKEN`** (one-time `claude
  setup-token`, ~1-year, stored in a Secret — *not* `ANTHROPIC_API_KEY`, which would take
  precedence). Launcher: `coordinator-session.sh` (TODO).

## Open wiring (not done yet)

- `coordinator-session.sh` + a Claude Code coordinator image + the scoped SA/RBAC.
- `agent-session.sh` must accept a per-session secret name so the worker uses the ephemeral key
  instead of the shared `<project>-openrouter`.
- `provider`-routing injection (opencode.json or the ADR-081 egress proxy) so the paid path stops
  default-routing to a pricey provider.

See [`../README.md`](../README.md) (launcher + per-session budget), [`../../docs/agents/workflow.md`](../../docs/agents/workflow.md)
(reconcile loop + hazards), and [`../../docs/agents/README.md`](../../docs/agents/README.md) (design/ADRs).
