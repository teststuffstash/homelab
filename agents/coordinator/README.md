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

The coordinator runs as **Claude Code in a scoped pod**, the sibling of the worker launcher —
`coordinator-session.sh` (`devbox run coordinator-session`):

```sh
# interactive: clone homelab, drop into `claude` loaded with this brief (supervised)
devbox run coordinator-session

# headless: run one reconcile pass and self-terminate
devbox run coordinator-session -- --run "Do one reconcile pass over open agent-fix issues."
```

The pod gets the homelab repo cloned in, a ServiceAccount scoped by [`rbac.yaml`](rbac.yaml) (spawn
worker pods + mint/observe `OpenRouterKey` CRs; **no** Secret-value access), and subscription auth via
**`CLAUDE_CODE_OAUTH_TOKEN`** (*not* `ANTHROPIC_API_KEY` — it takes precedence). Interactive is
supervised by default (no `--permission-mode`); `--run` defaults to `bypassPermissions` (the pod is
the isolation boundary). Model defaults to `sonnet` (a Pro plan); pass `--model opus` on Max.

**In-pod, call the scripts directly** (the image has no devbox): `python3 agents/estimate_budget.py …`
and `bash agents/agent-session.sh …` (it falls back to the pod's in-cluster ServiceAccount). Mint the
session key by `kubectl apply`-ing the estimator's `--emit-cr` output, then **wait on the
`OpenRouterKey` `.status` hash** (not the Secret), and dispatch the worker with
`--openrouter-secret <project>-session-<id>-openrouter`.

## Bootstrap (one-time)

```sh
# 1. scoped identity (creates the agent-coordinator namespace)
kubectl --kubeconfig tofu/kubeconfig apply -f agents/coordinator/rbac.yaml

# 2. git token — ESO mints it from the homelab-agents App (needs issues:write granted on the App).
#    Writes the coordinator-git Secret (key GH_TOKEN), auto-refreshed ~hourly. See §Git token.
kubectl --kubeconfig tofu/kubeconfig apply -f agents/coordinator/git-token.yaml

# 3. subscription token (~1y) — paste-a-code flow works in the jail; still imperative for now
kubectl -n agent-coordinator create secret generic coordinator-claude \
    --from-literal=CLAUDE_CODE_OAUTH_TOKEN="$(claude setup-token)"
```

The image is built + pushed to `ghcr.io/teststuffstash/agent-coordinator:latest` by CI in the
[`agent-coordinator`](https://github.com/teststuffstash/agent-coordinator) repo (every push to master,
à la `agent-base` in `agent-runtime`) — **no manual `docker build`**. After the first build, make that
ghcr package public (or add an imagePullSecret). `coordinator-git` is now GitOps'd via ESO
(`git-token.yaml`); only `coordinator-claude` stays imperative — fold it into Infisical/ESO later.

## Git token

The coordinator's `coordinator-git` (`GH_TOKEN`) is broader than the per-project *worker* git-token
(which is `contents`+`pull_requests`, one repo, ~1h, minted by the `homelab-agents` GitHub App). The
coordinator needs, across the agent project repos: **`issues:write`** (apply/move the `agent/*`
labels) + **`pull_requests:write`** + **`contents`** (merge). Two ways to source it, least-sprawl
first:

- **Preferred — the existing `homelab-agents` GitHub App.** Add `issues:write` to the App and install
  it on the coordinator's target repos, then mint the coordinator token from it (ESO, like the worker
  token) — *no new standing credential to track*.
- **Interim — a scoped fine-grained PAT** (`issues:write` + `pull_requests:write` + `contents:write`
  on the agent repos). Simple, but it's one more static token; rotate it like the rest.

The **image-build CI needs no token** — it pushes to ghcr with the job's built-in `GITHUB_TOKEN`
(`packages: write`). The only *new* credential the coordinator adds is this runtime `coordinator-git`.

## Open wiring (still TODO)

- **`provider`-routing injection** (opencode.json or the ADR-081 egress proxy) so the paid worker
  path stops default-routing to a pricey provider — see [`../README.md`](../README.md) follow-ups.
- **Graduate the loop** off hand-driving to a durable engine (Temporal / Argo Workflows+Events / a
  CRD+controller) once the runbook is proven — state already lives in labels+CRs, so it's a swap.

See [`../README.md`](../README.md) (worker launcher + per-session budget), [`../../docs/agents/workflow.md`](../../docs/agents/workflow.md)
(reconcile loop + hazards), and [`../../docs/agents/README.md`](../../docs/agents/README.md) (design/ADRs).
