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
| `major` | a MAJOR dependency-bump PR (un-armed, human-gated) — coordinator-owned, see §Dependency major bumps | `devbox-update.sh` |
| `major/awaiting-human` | migration documented, CI green, reviewer-approved — a **human** merges (not the bot) | coordinator |

Invariants: **one active worker per PR**; **bounded rounds** (max 3, then `agent/blocked`);
idempotency key `(issue, base-sha, round)` so a re-list/redelivery never double-spawns.

> **Be visible; never stall silently.** Your state lives in **GitHub**, not your head. The moment you
> pick up an issue, **claim it** (relabel + a one-line plan comment) — do this *before* investigating,
> not after. Keep narrating progress as issue comments. If you get stuck — ambiguous issue, repeated
> failure, missing access, the estimator says `⚠ ESCALATE` — **label `agent/blocked` and comment
> exactly what's blocking, then move on**. Investigating quietly and then doing nothing is the **one
> unacceptable outcome**: a blocked issue a human can see beats a silent stall every time.

> **Issues must be self-contained — the issue is the context channel.** The worker pod clones ONLY
> the project repo: no `../homelab` checkout, no `SERVICES.md`, no kubeconfig. App repos deliberately
> don't duplicate platform docs, so before dispatching, make sure the issue carries every platform
> fact the task needs (service endpoints/status from `SERVICES.md`, bucket names + key/Secret names,
> the relevant runbook/pattern excerpt) — add a comment with the missing facts if the reporter didn't.
> A round that fails because the worker lacked a platform fact is a triage bug: fix the issue, not
> the recipe.

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
> **Steps 6–7 are now DETERMINISTIC REFLEXES, not coordinator turns** (FU-041,
> [`../../docs/agents/merge-path.md`](../../docs/agents/merge-path.md)). `agent-session.sh` arms
> auto-merge at PR open; the per-repo **updater workflow** keeps a behind PR current; the **review
> reflex** CronJob (`agents/coordinator/review-reflex.yaml`) dispatches the reviewer the moment a PR is
> green + current + unapproved; GitHub auto-merge completes it. So in the normal path you do **not** run
> steps 6–7 by hand — you WATCH the reflexes work and only step in for the exception plays (conflict →
> close + re-dispatch fresh; changes-requested → next round; round-limit / flip-flop / stale-red →
> decide or escalate). The manual commands below remain valid as a fallback when a reflex is disabled.

> **⚠ PRE-FLIGHT BEFORE YOU MANUALLY DISPATCH A REVIEW.** The reflex applies these filters
> automatically (armed ∧ green ∧ not-BEHIND ∧ **not-DIRTY** ∧ reviewable); when you reach for
> `reviewer-session.sh` by hand you MUST apply them too — or you review a PR the reflex deliberately
> excludes and waste a scarce reviewer run. Ask, in order:
> 1. **Is it an agent PR at all?** A human's PR with no linked `agent-fix` issue is outside your
>    mandate. Assess it and take the terminal action (usually **close with a comment**, or escalate) —
>    do **not** shepherd it toward merge as if a worker opened it.
> 2. **Is it mergeable?** `DIRTY`/`CONFLICTING` (`gh pr view <N> --json mergeStateStatus`) → a review
>    **cannot** fix a conflict, and an approval can't auto-merge a conflicted branch. Decide directly
>    (close + re-dispatch a fresh worker from new master, or escalate) — never review a conflicted PR
>    hoping approval merges it.
> 3. **Is the change superseded or still needed?** Diff against **current master** — if master already
>    landed the intent (often *better*), **close with an explanation**, don't approve a redundant diff.
>
> The manual `reviewer-session.sh` is ONLY for a PR the reflex *would* pick but hasn't yet (edge-trigger
> latency) — **never** for one it excludes by design (DIRTY, unarmed, superseded, or non-agent).
> *(Learned live on sleep-tracking#9: a DIRTY, master-superseded human PR was hand-reviewed instead of
> closed; the reviewer caught it and recommended close — but a pre-flight would have skipped the run.)*

6. **Watch.** The run streams logs + drops an `AGENT_RUN_STATS` line and a PR stats comment. When a
   PR opens → relabel `agent/review`. Auto-merge is armed by `agent-session.sh` (confirm with `gh pr
   merge <PR> --repo teststuffstash/<project> --auto --squash`; arm it yourself only if the worker
   didn't). You do NOT merge by hand — GitHub auto-merge fires once the gate is satisfied (1 approving
   review + CI green).
7. **Get it reviewed — by the bot, not you.** The reviewer is a **distinct GitHub identity**
   (`homelab-reviewer[bot]`), never the coordinator or the worker: GitHub blocks self-approval, and its
   **native** approval is what satisfies the branch-protection `required-approval` gate. The **review
   reflex normally dispatches this for you**; trigger it by hand only as a fallback (it clones the repo,
   `gh pr checkout`s the PR, runs `/code-review`, and submits exactly one
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
7a. **Deploy — automatic, nothing to do.** The deploy path is fully automated now and the coordinator
   **never touches it** (and never touches homelab). Merging the fix PR fires the app repo's `deploy`
   workflow → it builds the image + chart at `<calver>-g<sha>` and opens an **auto-merging** version-bump
   PR in the stack's `-iac` repo (e.g. sleep-iac); an in-cluster webhook makes ArgoCD sync near-instantly.
   So a merged fix reaches prod on its own. At most, *confirm* the rollout went Healthy — post-deploy
   health/rollback is FU-044, handled in-cluster. See homelab `docs/sleep-iac.md` §"Deploy pipeline".
8. **Clean up.** Delete the ephemeral `OpenRouterKey` CR (its `expiresAt` is the backstop).

## Dependency major bumps (coordinator-owned, NOT the review reflex)

The weekly `devbox update` (FU-022) opens a bump PR per repo. A **non-major** bump arms auto-merge and
rides the normal reflex track — you never see it. A **MAJOR** bump (e.g. `kubernetes-helm 3 → 4`) is
different: `devbox-update.sh` labels it **`major`** and **deliberately does NOT arm auto-merge**, because
a major crossing needs a human to merge *after* the machine has done its homework. **Arming is the
boundary** — the review reflex only touches armed PRs, so an un-armed `major` PR is invisible to it and
lands squarely in your lap. Own it end-to-end; do **not** hand-dispatch it through the reflex path.

The PR is typically **red at birth** (the major breaks CI — that's the point, CI caught it). Drive it
like an `agent-fix` issue, but PR-first and keyed on the `major` label:

1. **List** open PRs labelled `major` (across your stack's repos) that are not yet `major/awaiting-human`.
2. **Claim + investigate.** Relabel `agent/in-progress`, comment a one-line plan, and dispatch the
   **reviewer directly** — even while red (the reflex won't, but you can; a major review is an
   *investigation* whose whole job is to explain the red):
   ```sh
   bash agents/reviewer-session.sh <project> <PR>
   ```
   The reviewer reads the tool's upstream migration notes, maps them onto this repo's usage, and comments
   exactly what must change (e.g. helm-4 needs `--verify=false` on `helm plugin install`).
3. **Fix, if within budget.** On `CHANGES_REQUESTED`, estimate the adaptation
   (`estimate_budget.py`); if it's within the cap, dispatch a **worker** to apply it **on the PR branch**
   (not a new branch), feeding it the reviewer's comments — same round mechanics as steps 3–5 above. If
   the estimator says `⚠ ESCALATE` → `agent/blocked` + comment, stop.
4. **Loop to green.** Worker pushes → CI re-runs → re-dispatch the reviewer. Repeat within the round
   bound (max 3). Green + `APPROVED` is the target.
5. **Hand off to the human — do NOT merge.** The PR is un-armed by design; your approval does not merge
   it. Relabel **`major/awaiting-human`** and comment "migration documented, CI green, reviewer-approved —
   ready for a human to merge" (link the reviewer's summary). A human reads the documented trail and
   clicks merge. Optionally the reviewer's non-blocking follow-up comments (new major features worth
   adopting) become fresh `agent-fix` issues.

Why this is yours and not the reflex's: a major bump is a **judgment** call (is the fix within budget?
is the breakage worth adopting now? is a human happy to merge?), and reviews for it must run **while red**
— both are outside the reflex's decision-free, green-only mandate. Keeping `major` un-armed makes the
split automatic: reflex = armed track (auto-merge), coordinator = un-armed `major` (human-merge). They
never fight over the same PR because no PR is ever both armed and `major`. See
[`../../docs/agents/merge-path.md`](../../docs/agents/merge-path.md) §"Reflexes vs judgment".

## Runtime

The coordinator runs as **Claude Code in a scoped pod**, the sibling of the worker launcher —
`coordinator-session.sh` (`devbox run coordinator-session`):

```sh
# interactive, SEEDED with the canonical reconcile-tick prompt — supervise the first runs
devbox run coordinator-session -- --tick

# interactive, no seed (you type the first turn yourself)
devbox run coordinator-session

# scope a first run to one item
devbox run coordinator-session -- --seed "Work PR #18 on sleep-tracking to major/awaiting-human."

# headless one tick — the exact call a future coordinator reflex (CronJob) will make
devbox run coordinator-session -- --run-tick
```

> **Tick prompt = one source of truth.** The reconcile instruction lives once in
> `coordinator-session.sh` as `TICK_PROMPT`; `--tick` (interactive) and `--run-tick` (headless) inject
> the *same* string. So the first runs are hand-supervised with exactly the prompt the eventual
> autonomous **coordinator reflex** (the LLM sibling of `review-reflex`, a CronJob doing `--run-tick` on
> a schedule) will use — graduating to autonomy is a **scheduler swap, not a behavior change**. Edit the
> wording in one place and both follow.

> **Scope note (evolving — FU-045).** The pod clones *homelab* today, but a coordinator instance is
> really scoped to a **stack**: the platform (homelab) **plus that stack's repos**. Since FU-025 a
> stack's deploy truth lives in its own `-iac` repo (sleep → `sleep-iac`), so a full "sleep coordinator"
> context is homelab + sleep-iac + the app repos — and a *different* stack (e.g. `idp`) is a different
> context (homelab + idp's repos). "The coordinator runs on cloned homelab" is thus no longer the whole
> story; generalizing the single homelab clone into a per-stack context (possibly one coordinator per
> stack) is **FU-045**.

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
(`git-token.yaml`); only `coordinator-claude` stays imperative — fold it into Infisical/ESO later
(FU-001).

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

## Open wiring (still TODO — ids in [`docs/follow-ups.md`](../../docs/follow-ups.md))

- **FU-018 — `provider`-routing injection** (opencode.json or the ADR-081 egress proxy) so the paid
  worker path stops default-routing to a pricey provider — see [`../README.md`](../README.md) follow-ups.
- **FU-026 — Graduate the loop** off hand-driving to a durable engine (Temporal / Argo
  Workflows+Events / a CRD+controller) once the runbook is proven — state already lives in
  labels+CRs, so it's a swap.
- **Deploy path (FU-025, done):** the release→deploy path is now automated — the app repo's `deploy`
  workflow builds + opens an auto-merging version-bump PR in the stack's `-iac` repo, ArgoCD syncs. So
  step 7a is a no-op (deploy is hands-off); the coordinator never cuts releases or touches homelab.
  See `docs/sleep-iac.md` §"Deploy pipeline".

See [`../README.md`](../README.md) (worker launcher + per-session budget), [`../../docs/agents/workflow.md`](../../docs/agents/workflow.md)
(reconcile loop + hazards), and [`../../docs/agents/README.md`](../../docs/agents/README.md) (design/ADRs).
