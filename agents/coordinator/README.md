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

> **Be visible; never stall silently.** Your state lives in **GitHub**, not your head. The moment you
> pick up an issue, **claim it** (relabel + a one-line plan comment) — do this *before* investigating,
> not after. Keep narrating progress as issue comments. If you get stuck — ambiguous issue, repeated
> failure, missing access, the estimator says `⚠ ESCALATE` — **label `agent/blocked` and comment
> exactly what's blocking, then move on**. Investigating quietly and then doing nothing is the **one
> unacceptable outcome**: a blocked issue a human can see beats a silent stall every time.

## Per-issue runbook (what the interactive coordinator does)

> **You are running IN the pod, not the jail.** Tools are on `$PATH` and called **directly** — there
> is **no `devbox`** here, and **no `tofu/kubeconfig`** (it's gitignored, absent from the clone).
> So: `kubectl …` (plain — it auths via the pod's in-cluster ServiceAccount; **never** `devbox run`
> and **never** `--kubeconfig`), `python3 agents/estimate_budget.py …`, `bash agents/agent-session.sh …`,
> `gh …`. (The `devbox run …` forms in the other READMEs are the *jail* equivalents — ignore them here.)

> **MODEL — do not freelance.** The worker model is **`openrouter/deepseek/deepseek-v4-flash`** (cheap,
> instruct-tuned, priced in the estimator). Use it for BOTH `--model` flags below. Do **not** swap in a
> model you happen to know (especially **reasoning** models like `deepseek-r1*` — slow, verbose,
> pricier) — that produces a bogus $1/M-default estimate and a worse fix. Only change the model if the
> human tells you to.

1. **List** open `agent-fix` issues; pick one labelled `agent/queued` (level-triggered — just
   re-read the world each pass).
2. **Claim it FIRST — before investigating.** Relabel and comment a one-line plan, so the work is
   visible and won't be double-picked:
   ```sh
   gh issue edit <N> --repo teststuffstash/<project> --add-label agent/in-progress --remove-label agent/queued
   gh issue comment <N> --repo teststuffstash/<project> --body "🤖 picking this up (round <r>): <one-line plan>"
   ```
3. **Read + estimate.** Pipe the issue text into the budget estimator:
   ```sh
   gh issue view <N> --repo teststuffstash/<project> --json title,body -q '.title+"\n"+.body' \
     | python3 agents/estimate_budget.py --model openrouter/deepseek/deepseek-v4-flash \
           --project <project> --session issue-<N>-round-<r> --emit-cr
   ```
   **Read the estimator's stderr verdict.** If it prints `⚠ ESCALATE` (estimate exceeds the **top**
   tier cap, not merely "tier == lg") → label `agent/blocked`, comment the numbers, **stop**: the cap
   can't cover the run so it would 403 unfinished, and a human must approve. A `$1.0/M` price in the
   verdict means the model was **unpriced** (you used the wrong one) — fix the model, don't escalate.
4. **Mint the per-session budget IMMEDIATELY before dispatch** — by re-running the estimate command
   from step 3 with `| kubectl apply -f -` (it sets a fresh `expiresAt` each time). Hard `budgetUSD`,
   no reset, ~2h `expiresAt`. The openrouter-operator mints the key and writes the Secret
   `<project>-session-issue-<N>-round-<r>-openrouter`. **Wait on the CR**, not the Secret (you can't
   read Secret values): `kubectl -n <project> get openrouterkey <name> -o jsonpath='{.status.openrouter.hash}'`
   returns non-empty once minted. The operator **self-heals** — if a prior key expired/was revoked,
   applying the CR (with its fresh `expiresAt`) re-mints a live one (it no longer NoOps on a dead key).
   So **always (re)apply right before dispatch** rather than reusing a key minted earlier — a 2h key
   that sat unused can expire, and a stale `status.hash` does NOT prove the key is still live. This is
   the real breaker — the worker can't outspend `budgetUSD`.
5. **Dispatch a fresh worker** for this round (already labelled `agent/in-progress` from step 2):
   ```sh
   bash agents/agent-session.sh <project> --harness goose --model openrouter/deepseek/deepseek-v4-flash \
       --openrouter-secret <project>-session-issue-<N>-round-<r>-openrouter \
       --run "goose run --recipe .agents/fix.yaml --params issue=<N>"
   ```
   `--openrouter-secret` binds the worker to the per-session key (not the shared standing one). Use
   the **exact** name `--emit-cr` printed to stderr (`→ session Secret: …`) — it's the CR's
   `spec.secretName` (`<project>-session-<session>-openrouter`, with the `-session-` infix). **Do NOT
   reconstruct it** from the CR's `metadata.name` (`<project>-<session>`); that omits `-session-` and
   the worker crash-loops on `secret … not found`.
6. **Watch.** The run streams logs + drops an `AGENT_RUN_STATS` line and a PR stats comment. When a
   PR opens → relabel `agent/review`, and confirm **auto-merge is armed** (`gh pr merge <PR> --repo
   teststuffstash/<project> --auto --squash`; arm it yourself if the worker didn't). You do NOT merge
   by hand — GitHub auto-merge fires once the gate is satisfied (1 approving review + CI green).
7. **Get it reviewed — by the bot, not you.** The reviewer is a **distinct GitHub identity**
   (`homelab-reviewer[bot]`), never the coordinator or the worker: GitHub blocks self-approval, and its
   **native** approval is what satisfies the branch-protection `required-approval` gate. Trigger it
   headless (it clones the repo, `gh pr checkout`s the PR, runs `/code-review`, and submits exactly one
   `gh pr review --approve|--request-changes` as the review bot):
   ```sh
   bash agents/reviewer-session.sh <project> <PR>
   ```
   Then read the verdict and drive the round:
   ```sh
   gh pr view <PR> --repo teststuffstash/<project> --json reviewDecision -q .reviewDecision
   ```
   - **`APPROVED`** → hands off. The gate + auto-merge (armed in step 6) complete the PR on their own;
     do **not** merge manually. When GitHub reports it merged → relabel `agent/done`, clean up (step 8),
     then deploy (step 7a).
   - **`CHANGES_REQUESTED`** and `round < max` → bump the round and go to **step 3** with a fresh pod +
     fresh session key, **passing the reviewer's comments to the fixer** so it addresses them (feed
     `gh pr view <PR> --repo teststuffstash/<project> --json reviews -q '.reviews[-1].body'` into the
     fixer's context). New commits re-open the gate (`dismiss_stale_reviews_on_push`), so the bot must
     re-approve — re-run this step after the next round's PR update.
   - `round == max` or ambiguous → `agent/blocked` + comment the blockers.
7a. **Deploy the merged fix (version bump).** ⚠️ Deploy-versioning + repo structure are being
   **reworked** — until that lands, do NOT autonomously cut release tags or push to homelab. A merged
   fix is in code but **not live** until a release is cut and the deploy pins to it (today's manual
   path: a `v*` tag on the project → `release.yaml` publishes the image + OCI chart → bump
   `argocd/sleep/…/targetRevision` in homelab → ArgoCD syncs). For now, **flag it**: comment on the
   issue that a release + deploy is pending (with the merged SHA) and leave it for the human. Revisit
   this step once the rework defines the automated deploy path.
8. **Clean up.** Delete the ephemeral `OpenRouterKey` CR (its `expiresAt` is the backstop).

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
**`CLAUDE_CODE_OAUTH_TOKEN`** (*not* `ANTHROPIC_API_KEY` — it takes precedence). Permissions are
**skipped by default** (`--permission-mode bypassPermissions`) for both interactive and headless —
the security boundary is the pod (scoped tokens + RBAC + pre-trusted `/work/homelab`), not
per-command approval, exactly like the jail. Pass `--permission-mode default` for a supervised
session. Model defaults to `sonnet` (a Pro plan); pass `--model opus` on Max.

**In-pod, call the scripts directly** (the image has no devbox): `python3 agents/estimate_budget.py …`
and `bash agents/agent-session.sh …` (it falls back to the pod's in-cluster ServiceAccount). Mint the
session key by `kubectl apply`-ing the estimator's `--emit-cr` output, then **wait on the
`OpenRouterKey` `.status` hash** (not the Secret), and dispatch the worker with
`--openrouter-secret <project>-session-<id>-openrouter`.

## Bootstrap (one-time)

```sh
# 1. scoped identity (creates the agent-coordinator namespace) + the durable transcript store
kubectl --kubeconfig tofu/kubeconfig apply -f agents/coordinator/rbac.yaml
kubectl --kubeconfig tofu/kubeconfig apply -f agents/coordinator/transcripts-pvc.yaml

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

## Logs & behaviour analysis

`kubectl logs` on a coordinator pod is **empty** — the interactive `claude` runs via `kubectl exec`,
not as PID 1 (`sleep infinity`). The real record is Claude Code's **session transcript**
(`~/.claude/projects/*.jsonl` — every prompt, tool call, and result), persisted to the
`coordinator-transcripts` RWX PVC so it survives pod deletion and accumulates across sessions. Read it
as a behaviour trace:

```sh
devbox run coordinator-logs            # render the latest session (turns + tool calls + results)
devbox run coordinator-logs -- -f      # follow the live session
devbox run coordinator-logs -- --raw   # raw jsonl for jq / deeper analysis
```

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
- **Deploy-versioning + repo-structure rework** (the next step): the release→deploy path today is
  manual and drifty (`Chart.yaml` vs the `v*` tag vs ArgoCD `targetRevision`). Until it's reworked,
  step 7a only *flags* a pending deploy — don't automate release/deploy against the current path.

See [`../README.md`](../README.md) (worker launcher + per-session budget), [`../../docs/agents/workflow.md`](../../docs/agents/workflow.md)
(reconcile loop + hazards), and [`../../docs/agents/README.md`](../../docs/agents/README.md) (design/ADRs).
