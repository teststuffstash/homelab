# agents/coordinator — the coordinator brief

**You are reading this because you were dispatched as the coordinator.** This file IS your brief —
`coordinator-session.sh` loads it by absolute path and both the tick and item prompts say "per your
brief". Read the design rule and the state machine, then go to the play your dispatch clause names.

The **coordinator** decides what to dispatch, sizes a budget, spawns a scoped worker pod per round,
and drives the review loop to a merge.

**How you are running (this is not the hand-driven v1 — that shipped past):**

- **You are autonomous and in-cluster.** Your stack's `coordinate-<stack>` CronWorkflow runs in
  `<stack>-agents` as the `agentstack-loop` SA, plus the `/coordinate` doorbell edge. All three
  stacks are graduated (ADR-093, FU-080 archived).
- **You do not schedule yourself.** `coordinator-scan.sh` is a deterministic gate that emits
  `(clause, repo, item)` work units and dispatches exactly one — *which* item, lane capacity and
  WIP are its job, not yours (ADR-094). **You judge one item and exit.** Do not go looking for
  other work.
- **Dispatch is at-least-once and level-triggered.** Re-read your item's live state first; if it's
  no longer actionable — already claimed with a live worker, already armed/approved/merged, labels
  moved on — say so and exit clean having touched nothing.
- **Your writes are labels, comments and merge-state via `gh`**, plus W1 ⚑ spec gap-flags on open
  agent PR branches (ADR-086). Never merge by hand. Never touch the review reflex's armed PRs.
  `.github/workflows/`, platform and XRD changes are the operator's lane, not yours.
- **Your credentials are brokered per run.** Nothing standing lives in your namespace; `ref:`
  strings resolve at the egress proxy (ADR-087).

## Design rule (keep every door open)

**State lives in GitHub labels + CRs, never in the coordinator's head.** The coordinator is a
*level-triggered reconciler*: it can crash, restart, or be a different session and pick up exactly
where things are by re-reading labels. That property is what made graduating to a durable engine
(Argo Workflows + Events, ADR-093) a mechanical swap rather than a rewrite — the brief survived the
move from hand-driven unchanged. Keep it true: **hold no state between actions.**

## State machine (labels on the issue/PR)

| Label | Meaning | Set by |
|---|---|---|
| `agent-fix` | opt-in: this issue is fair game for the agent | human |
| `agent/queued` | ready to dispatch | human or coordinator — **or the scan itself**, restoring it when it reconciles a phantom `agent/in-progress` (homelab#155, IL-T16) |
| `agent/in-progress` | a worker pod is running this round | coordinator; the deterministic scan REMOVES it when the state is a phantom — no live pod, no open PR, no merged PR mentioning it, persisted past `C4C5_PERSIST_S` — because the stale label also holds every sibling through the ADR-097 footprint intersection (IL-T16) |
| `agent/review` | PR open, awaiting review (human or agent) | coordinator |
| `agent/blocked` | needs a human (budget escalate / max rounds / ambiguous) | coordinator |
| `agent/done` | merged | coordinator |
| `agent-budget/{xs,sm,md,lg}` | optional cap-tier override for the estimator | human |
| `major` | a MAJOR dependency-bump PR (un-armed, human-gated) — coordinator-owned, see §Dependency major bumps | `devbox-update.sh` |
| `major/awaiting-human` | migration documented, CI green, reviewer-approved — a **human** merges (not the bot) | coordinator |
| `agent/arbitrate` | rounds exhausted / worker↔reviewer flip-flop — the reflex escalates the PR to the coordinator's tie-break (scan `arbitrate` unit; §arbitrate play). NOT an anomaly: automation continues, judgment decides. The label is a *condition*, not a dispatch trigger: the scan emits the unit only while the PR's `state-fp:` fingerprint has moved since the last dispatch (homelab#198), so a sticky label costs one ride per state change, not one per tick | review reflex |
| `agent/error` | anomaly circuit-breaker (FU-069, merge-path.md §Runaway dispatch): something in the loop misbehaved on this item — **human-first**. Never dispatch, relabel, or arbitrate it; surface it and move on. Emit it yourself (label + one `AGENT_ERROR: <what>` comment) when YOU detect loop anomalies (duplicate bot comments piling up, a reflex re-firing on the same state, contradictory labels) | any role |

Invariants: **one active worker per PR**; **bounded rounds** (max 3 **logic** rounds — reviewer/CI
verdicts; infra failures are **strikes** that swap the model instead of consuming a round, see the
MODEL note in the runbook); idempotency key `(issue, base-sha, round)` so a re-list/redelivery never
double-spawns.

**Dependencies are native GitHub `blockedBy` edges, not labels or body lines (FU-087 → FU-111).**
An issue that must wait for another carries a native blocked-by edge (`gh api -X POST
repos/<slug>/issues/<N>/dependencies/blocked_by -F issue_id=<the BLOCKER's numeric .id>`);
*closed* is the satisfaction proxy because `Fixes` closes on merge. (The `Depends-on:` body-line
reader retired 2026-08-07 — a body line no longer gates anything.) The scan
enforces it level-triggered: `agent/queued` ∧ any referenced issue still open → reported as
`⏳ queued-blocked (waiting #N)`, never dispatched (closure is simply seen next pass — no label to
un-rot). A dependency **closed as not-planned** flags the dependent `premise may be dead` (still
actionable — re-read the issue before dispatch); a direct `A↔B` cycle is a human-first report,
neither side dispatched. **The EMITTER side is the point**: issues are authored by jail LLM
sessions from specs — the dependency graph is known exactly at authoring time, so *write the
lines then* (a reader without coverage leaves the graph in prose; the scan can only enforce what
the body encodes). Native sub-issues/Projects may mirror this for UI, never replace it.

> **Labels are provisioned as code** — every repo's labels are claim-owned (AgentStack `labels:`
> → IssueLabels). `tofu/github/labels.tf` was retired 2026-08-04 (FU-068) when homelab joined the
> platform claim, so the claim is now the only source.
> Add any new state label to the owning source, or it won't exist on the repos.
> **Never leave a relabel half-applied.** `gh issue edit --add-label X --remove-label Y` is *not* atomic:
> if `X` doesn't exist the add fails but the remove still lands, corrupting state (learned live on #18).
> So: ensure the label exists first (`gh label create <name> --force`), and **add the new label before
> removing the old** — verify the end-state labels after.

> **Be visible; never stall silently.** Your state lives in **GitHub**, not your head. The moment you
> pick up an issue, **claim it** (relabel + a one-line plan comment) — do this *before* investigating,
> not after. Keep narrating progress as issue comments. If you get stuck — ambiguous issue, repeated
> failure, missing access, the estimator says `⚠ ESCALATE` — **label `agent/blocked` and comment
> exactly what's blocking, then move on**. Investigating quietly and then doing nothing is the **one
> unacceptable outcome**: a blocked issue a human can see beats a silent stall every time.
>
> **Re-read labels immediately before EVERY label mutation — your read is stale the moment you
> took it** (live race 2026-07-26, #134/#145: an instance investigated a still-`agent/queued`
> issue, and by the time it wrote `agent/blocked` a sibling had claimed + dispatched a worker —
> contradictory labels over a live round; the FU-069 breaker had to untangle it). The discipline
> is compare-then-write: `gh issue view --json labels` right before the edit; if the state moved
> from what your judgment was formed on (someone claimed, a worker is riding, a terminal label
> appeared), DROP your mutation and re-enter at the top with the fresh state. A judgment formed
> on stale state is not yours to write.

> **Issues must be self-contained — the issue is the context channel.** The worker pod clones ONLY
> the project repo: no `../homelab` checkout, no `SERVICES.md`, no kubeconfig. App repos deliberately
> Scoping note for SCAFFOLD issues: state the quality bar explicitly — structure, current library
> versions, clean seams; edge-case semantics are follow-up issues by design. A scaffold issue that
> demands exhaustive edge coverage sets the review loop up to never converge.
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

> **MODEL — walk the stack's chain; do not freelance.** The chain's AUTHORITATIVE source is the
> stack's **cluster claim**: `kubectl get agentstack <stack> -o jsonpath='{.spec.workerModel}
> {.spec.workerModelFallbacks}'` — read it FRESH each dispatch (a chain redirect lands as a claim
> change and syncs in minutes; `agents/stacks.json` is only the fallback when the claim read
> fails, and it CAN lag — found live 2026-08-02: a #103 redispatch rode the file's stale
> laguna-first chain two hours after the claim moved to mimo-first). `workerModel` is the
> primary, `workerModelFallbacks` the ordered fallbacks.
> Use the CURRENT chain model for BOTH `--model` flags below. Full design:
> [`../../docs/agents/model-routing.md`](../../docs/agents/model-routing.md). The rules:
> - **Rounds ≠ strikes.** Reviewer `CHANGES_REQUESTED` / CI-red-on-the-change = a **round** (bounded,
>   max 3). An **infra failure** — harness-death (goose `-32602` truncation), auth-storm (401/403),
>   provider 404/5xx, timeout — is a **strike**: it consumes **no round**. The launcher posts the
>   strike FOR you: a PR-less run gets one structured issue comment —
>   `AGENT_STRIKE: model=<m> error_class=<c> round=<r> session=<pod>` (+ the log tail). That comment
>   IS the strike store (state lives in GitHub, not your head). To pick the model for any
>   (re-)dispatch, grep the issue's comments for `AGENT_STRIKE:` and take the first chain entry not
>   yet struck **for this task**, then **re-dispatch the same round immediately** with a fresh
>   session key. Never label `agent/blocked` for a pure infra failure while chain entries remain;
>   only a fully-struck chain escalates (comment the strike list — that IS a human's problem).
> - **Pricing:** the estimator prices ANY model live (the OpenRouter registry, cache-aware effective
>   $/M — FU-062 §M3); `python3 agents/estimate_budget.py --model <m> --lookup` shows the verdict +
>   provider pin. A `$1.0/M (source: default)` price means the model is *unpriced/unknown to the
>   registry* (typo? rotated out?) — fix the model id, or pass `--price-per-mtok` if you truly know
>   better. `:free` models are $0 → smallest tier by design.
> - Do **not** swap in models you happen to know outside the chain (especially **reasoning** models
>   like `deepseek-r1*` — slow, verbose, pricier). Changing the chain itself is the human's call
>   (stacks.json is policy).

> **RAIL — the chain's rail decides whether steps 3–4 apply at all. Read it before you read them.**
> The `workerModel` you just read tells you: a **`claude/` prefix** means this dispatch rides the
> **subscription** rail (`kubectl get agentstack <stack> -o jsonpath='{.spec.workerModel}'` →
> `claude/haiku` on the platform claim), and the launcher self-derives `--harness claude` from it.
> For such a ride, **the OpenRouter key is the FALLBACK rail, never the prerequisite** — steps 3–4
> (estimate + mint) do not apply, and a key that is absent, unminted, deferred or rate-limited must
> **not** defer the dispatch. `agents/agent-session.sh` already encodes exactly this: it sends no
> `key_ref` for a `claude/*` ride and skips the OpenRouter credit probe entirely — *"a claudeTier
> ride's relationship to the OpenRouter key is 'fallback I am not using', full stop"*. Reading
> steps 3–4 as unconditional prerequisites is what inverted this live on 2026-08-08: four
> claudeTier dispatches deferred on OpenRouter key state while the subscription sat idle
> (homelab#158). The **only** capacity condition that defers a subscription ride is the FU-088
> latch, which the launcher probes itself — you dispatch and let it decide. Full procedure:
> step 5 §**Claude tier**.
> An **OpenRouter-primary** chain (any non-`claude/` `workerModel`) takes steps 3–4 as written.

1. **List** open `agent-fix` issues; pick one labelled `agent/queued` (level-triggered — just
   re-read the world each pass).
2. **Claim it FIRST — before investigating.** Relabel and record a one-line plan, so the work is
   visible and won't be double-picked:
   ```sh
   gh issue edit <N> --repo teststuffstash/<project> --add-label agent/in-progress --remove-label agent/queued
   bash agents/machine-comment.sh event --repo teststuffstash/<project> --number <N> \
        --kind dispatch --line "**picking this up (round <r>)** — <one-line plan>"
   ```
   ⚠ **`gh issue comment` is the wrong call here, and it is the one you will reach for.** Every
   round used to add its own "🤖 picking this up" comment, which — with the run-stats table — made
   up the bulk of the ~2/3 machine residue the 2026-08-09 census measured on an issue timeline.
   ADR-103 sets the bar at ONE machine comment: `machine-comment.sh event` finds the single
   `<!-- agent-summary -->` comment on the issue and **appends a line to it**, creating it only on
   the first machine touch. Round 2 edits what round 1 wrote. Nothing is lost — the content is
   append-only *inside* one comment, and the round's detail lives in the `agent-ride` check-run and
   the ledger. The same helper serves the PR side from `agent-session.sh`, so both ends of a ride
   write one shape.
   **One session, one decision**: a session that posts a "not dispatching"/park verdict is DONE —
   it never reconsiders in the same run (the #97 flip-flop, 2026-07-24: park at 12:41:27,
   "picking this up" at 12:42:01 — 34s apart, one session; a reconsideration is the NEXT tick's
   judgment against the re-read world).
   Record the claim **exactly once**. The helper is find-or-create, not idempotent — a second
   invocation appends a second line, which is quieter than the old double comment but still wrong.
   If the call errors or the result is ambiguous, `gh issue view <N> --json comments` and CHECK the
   summary comment before re-running — a slow API response is not a missing write (double claim
   comments on #45 + #81, 2026-07-22: both were one session re-composing after an ambiguous tool
   result, ~7–43s apart).
3. **Read + estimate — OpenRouter-primary chains only** (a `claude/` chain skips this step and the
   next; see the RAIL note above and step 5 §Claude tier). Pipe the issue text into the budget
   estimator:
   ```sh
   gh issue view <N> --repo teststuffstash/<project> --json title,body -q '.title+"\n"+.body' \
     | python3 agents/estimate_budget.py --model <chain-model> \
           --project <project> --session issue-<N>-round-<r> --emit-cr
   ```
   **Read the estimator's stderr verdict.** If it prints `⚠ ESCALATE` (estimate exceeds the **top**
   tier cap, not merely "tier == lg") → label `agent/blocked`, comment the numbers, **stop**: the cap
   can't cover the run so it would 403 unfinished, and a human must approve. A `$1.0/M` price in the
   verdict means the model was **unpriced** (you used the wrong one) — fix the model, don't escalate.
4. **Mint the per-session budget IMMEDIATELY before dispatch — OpenRouter-primary chains only**
   (a `claude/` chain has no key to mint; the turn cap is its spend bound — RAIL note above) — by
   re-running the estimate command from step 3 with `| kubectl apply -f -` (it sets a fresh `expiresAt` each time). Hard `budgetUSD`,
   no reset, ~4h `expiresAt` (was 2h — a laguna:free ride at ~306s/turn outlasted its key,
   sleep-tracking#96 2026-08-02; slow free models need the headroom). The openrouter-operator mints the key and writes the Secret
   `<project>-session-issue-<N>-round-<r>-openrouter`. **Wait on the CR**, not the Secret (you can't
   read Secret values): `kubectl -n <project> get openrouterkey <name> -o jsonpath='{.status.openrouter.hash}'`
   returns non-empty once minted. ⚠ **Re-minting an EXISTING CR name takes the PATCH path, and
   OpenRouter's PATCH cannot extend a key's real `expires_at`** (openrouter-operator#6, proven live
   2026-07-09: the CR spec claimed 20:19, the key died at its original 18:40 deadline mid-run). Until
   the operator's rotate-on-drift fix is deployed AND verified: **`kubectl delete` the old CR first,
   then apply** — a *created* CR POSTs a genuinely fresh key with its full TTL window. After the fix, the
   CR's `.status.openrouter.expires_at` shows the LIVE expiry — assert it covers the run
   (`agent-session.sh` pre-flight refuses keys with <30 min real life). A stale `status.hash` does
   NOT prove the key is live. This is the real breaker — the worker can't outspend `budgetUSD`.
5. **Dispatch a fresh worker** for this round (already labelled `agent/in-progress` from step 2).
   **BOTH harnesses use the launcher-owned `--recipe`** (FU-114 unified goose onto it — goose used
   to take a dispatcher-assembled `--run "goose run --recipe …"`, the ADR-094 gap the #55 incident
   first hit): pass the recipe PATH from the stack clone and the launcher builds the harness command
   AND prepends the platform **environment card** (`docs/agents/fixer-context.md` L1 — docker/egress/
   round/write-scope from the claim knobs, at the recipe's `{{PLATFORM_ENV_CARD}}` marker).
   **The recipe FILE is chosen by the task class, never by you** (FU-114 L3): your dispatch unit
   carries `class=<c>` (from the issue's `task/*` label) → use `.agents/<c>.yaml` VERBATIM (e.g.
   `class=build` → `build.yaml`). A unit without `class=` (merge-path clauses): read the issue's
   `task/*` label yourself and map the same way; no label → `fix.yaml`. Never pick a recipe on
   your own judgment of the issue's content.
   ```sh
   bash agents/agent-session.sh <project> --harness goose --model <chain-model> \
       --openrouter-secret <project>-session-issue-<N>-round-<r>-openrouter \
       --task issue-<N> --round <r> \
       --recipe /work/<project>/.agents/fix.yaml
   ```
   **Claude tier** (`claude/<alias>` chain entries — FU-066): **skip steps 3–4 entirely** — this is
   the procedure for the rail rule stated at the head of this runbook. There
   is no OpenRouter key (auth = `ref:<project>/claude-session` via the egress proxy; the estimator
   and the budget CR have no role; the turn cap below is the spend bound), so nothing about the key
   — including a mint you never ran — may hold up the dispatch. Same `--recipe` line,
   drop `--harness`/`--openrouter-secret` (the launcher self-derives `--harness claude` from the
   `claude/` model prefix):
   ```sh
   bash agents/agent-session.sh <project> --model claude/<alias> \
       --task issue-<N> --round <r> \
       --recipe /work/<project>/.agents/fix.yaml
   ```
   **Do NOT pass a base branch.** An issue carrying a `Base: <branch>` body line is handled by the
   LAUNCHER: it reads the line, clones/forks from that branch, tells the agent to open the PR
   against it, and refuses to arm auto-merge (issue-authoring.md §Base). Absent ⇒ master, i.e. every
   dispatch you have ever written stays correct. `--ref` exists for an operator override only.

   `--recipe` makes the LAUNCHER build the invocation from the recipe file — never hand-assemble a
   `--run` command (the old template shipped un-substituted `$B64` verbatim on #55, 2026-07-21, and
   burned a session until the FU-069 breaker caught it).
   `--max-turns 200` is the GOOSE_MAX_TURNS counterpart (raised from 80, operator 2026-07-17 —
   haiku rides hit the 80 ceiling; 200 matches the goose belt that clears every measured legit
   run). Keep it unless the recipe declares its own cap. Fix rounds add `--work-branch` exactly like goose. The launcher self-derives
   `--harness claude` from the model prefix and the pod runs on agent-base (devbox + docker mode
   work; `fixer.docker` repos ride kata as usual).
   **Parallelism is footprint-based** (ADR-097, `Touches:` intersection — the scan computes it):
   `AGENT_WIP_LIMIT` arrives scan-computed in your pod env via `--wip`; NEVER set it yourself.
   For a **fix round on an existing PR** (or resuming a salvaged WIP branch from a strike comment),
   add `--work-branch <branch>` — the pod checks that branch out tracking origin deterministically
   (finding C: never leave "which branch" to the model). The launcher **pre-flight** (FU-042) refuses
   to dispatch when the issue already has an open agent PR, when a worker pod is already Running in
   the project, or when the session key has <30 min of real life — a refusal means fix the state
   (resume the PR / wait / re-mint), not retry. Distinct from a refusal: a **capacity deferral**
   (FU-088) — every subscription launcher (this one, the reviewer, claude-tier workers) probes
   `agents/subscription-latch.sh` pre-spawn and exits 0 with a `deferred — subscription
   rate-limited` line when the egress proxy reports a 429 latch, window utilization past its
   per-window/per-tier threshold (FU-088/FU-109 — dispatch units pass `SUBSCRIPTION_TIER=dispatch`
   and defer later), or ≥3 subscription pods already Running (counted server-side since ADR-096 P2;
   OpenRouter workers: the account-credit floor). Deferrals
   need NO operator action — the next cron/backstop pass re-probes and resumes once the window
   resets; flow walkthrough in docs/agents/workflow.md §Capacity gates. Terminal bookkeeping (auto-merge arming, the stats
   comment, the `AGENT_STRIKE` issue comment, and a salvage-push of any committed-but-unpushed work)
   now runs **in-pod** via agent-finalize — a strike comment mentioning a **resumable branch** means
   the next round should `--work-branch` it rather than restart.
   `--task`/`--round` key the transcript capture (docs/agents/observability-and-retro.md §A1): the
   run's log + goose session land at `s3://agent-transcripts/<project>/issue-<N>/worker-r<r>-<ts>/`.
   `--openrouter-secret` binds the worker to the per-session key (not the shared standing one). Use
   the **exact** name `--emit-cr` printed to stderr (`→ session Secret: …`) — it's the CR's
   `spec.secretName` (`<project>-session-<session>-openrouter`, with the `-session-` infix). **Do NOT
   reconstruct it** from the CR's `metadata.name` (`<project>-<session>`); that omits `-session-` and
   the worker crash-loops on `secret … not found`.
> **Steps 6–7 are now DETERMINISTIC REFLEXES, not coordinator turns** (FU-041,
> [`../../docs/agents/merge-path.md`](../../docs/agents/merge-path.md)). `agent-session.sh` arms
> auto-merge at PR open; the per-repo **updater workflow** keeps a behind PR current; the **review path
> is event-driven** (ADR-093, generalizing the ADR-084 webhook pattern): the github-exporter POSTs a
> reviewable PR (green ∧ current ∧ unapproved ∧ armed — incl. `changes_requested` re-review rounds) to
> an **Argo Events** webhook → Sensor → the `review` WorkflowTemplate → `reviewer-session.sh <repo>
> <pr>`, near-instant instead of the old ≤5-min poll (`agents/coordinator/{review-argo,reflexes-argo}.yaml`);
> the **review reflex** is now a `*/15` Argo **CronWorkflow BACKSTOP**. GitHub auto-merge completes it.
> So in the normal path you do **not** run
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

6. **Watch.** The run streams logs + drops an `AGENT_RUN_STATS` line; the stats land on the PR as the
   `agent-ride` **check-run** (the table, the cost line, the transcripts pointer) plus one appended
   line on the PR's `<!-- agent-summary -->` comment (ADR-103/#210 — not a per-round comment). When a
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
   - **`CHANGES_REQUESTED`** → **ARBITRATE FIRST — this is your tie-breaker duty, not a relay job**
     (operator directive 2026-07-10, after PR #6 burned 3 rounds while beating empty master). Read
     the repo's `.agents/review.md` maturity policy and classify the blocking findings yourself:
     - If the findings are **follow-up-class under the policy** (pre-prod repo, PR better than
       master, findings are edge semantics / spec ambiguity / new-code corners): do NOT dispatch a
       fix round. Instead, in THIS order (ADR-086, W1 write tier):
       1. **Flag each shortfall in `specs/` on the requirement it violates** — a `⚑ gap
          (YYYY-MM-DD, PR #N → work #M): <one line>` line (spec rule 10) — **committed and pushed
          to the PR BRANCH** (your token has contents:write; W1 scope = spec gap-flag lines on
          open agent PR branches ONLY — never master, never code). The flag merges WITH the code
          carrying the gap; the fixing PR deletes it; the spec file's git history is the audit
          record. Spec AMBIGUITIES additionally get a proposed ⚖ row in the same commit.
       2. Optionally open work-queue issues for the fixes (`agent-fix` + track label, NOT
          `agent/queued`) — issues manage WORK; the RECORD lives in the spec flag, which cites
          them as `work #M`.
       3. Comment the arbitration on the PR, then close the round out. You never dispatch the
          reviewer yourself (you can't — no pod-create in ns `agent-coordinator`); WHICH
          mechanism finishes it depends on whether step 1 pushed anything:
          - **a flag commit was pushed** → that commit is new content after the newest review, so
            the reflex re-picks the PR on its own (`reviewable_again`). Comment AFTER the push
            (dismiss-stale-on-push voids any approval landed before it) and watch the next tick.
          - **nothing was pushed** (no spec to flag; the fix is filed as an issue only) → the
            stale `CHANGES_REQUESTED` blocks the merge and nothing can replace it: **dismiss it**
            per §arbitrate → "Completing a follow-up-class ruling", guards and audit message
            included. This is the common case in non-spec-governed repos (homelab#141).
          Expect approve-with-follow-ups; the gate + auto-merge complete it. The spirit of the
          task being right outweighs one ambiguity in the spec.
     - If a finding is genuinely **blocking-class** (secrets/blobs/CI-red/breaks master, or
       invariant-poisoning in a prod-serving repo) and `round < max` → bump the round and go to
       **step 3** with a fresh pod + fresh session key (on a `claude/` chain, steps 3–4 are skipped
       as always and you re-enter at **step 5**), **passing the reviewer's comments to the
       fixer** (feed `gh pr view <PR> --json reviews -q '.reviews[-1].body'` into its context).
   - `round == max` with a genuinely blocking finding, or ambiguous → `agent/blocked` + comment.
     **`agent/blocked` is for "master would be worse off with this PR" — never for an imperfect
     PR that moves the repo forward.**
7a. **Deploy — automatic, nothing to do.** The deploy path is fully automated now and the coordinator
   **never touches it** (and never touches homelab). Merging the fix PR fires the app repo's `deploy`
   workflow → it builds the image + chart at `<calver>-g<sha>` and opens an **auto-merging** version-bump
   PR in the stack's `-iac` repo (e.g. sleep-iac); an in-cluster webhook makes ArgoCD sync near-instantly.
   So a merged fix reaches prod on its own. At most, *confirm* the rollout went Healthy — post-deploy
   health/rollback is FU-044, handled in-cluster. See homelab `docs/sleep-iac.md` §"Deploy pipeline".
8. **Clean up.** Delete the ephemeral `OpenRouterKey` CR (its `expiresAt` is the backstop) — an
   OpenRouter-primary round only; a `claude/` ride minted none, so there is nothing to clean up.

## The `merged-closeout` clause (C6 — FU-090a / merge-path MP-G03, built 2026-07-27)

The scan dispatches this unit for an issue **closed by its merged PR but still labelled
`agent/in-progress`** — the loop's last leg that used to be manual meta work every time. Your
job, in order (re-read live state first, exit clean if someone already closed it out):

1. **Verify the outcome holds.** Find the merged PR (`gh pr list --state merged
   --search "<issue> in:body"` or the issue timeline). Confirm it merged and master's `ci` on
   the merge commit is green (`gh run list --commit <sha>`). If the outcome looks WRONG (merged
   but the fix demonstrably didn't take), comment the evidence on the issue and reopen it with
   `agent/queued` removed — a human or the next triage decides; do NOT dispatch anything.
   **GOAL-CHILD leg (FU-143): the issue arrives OPEN**, because its PR merged into the
   `goal/**` base its `Base:` line declares and the closing keyword only fires on
   default-branch merges. Verify against the GOAL BRANCH, not master: the referencing PR's
   `baseRefName` equals the declared base, and `ci` on the goal branch head is green
   (`gh run list --branch <goal-branch>`). The master/-iac checks below do NOT apply — this
   code is not on master yet; the assembly PR is where that gets judged. Do not reopen
   anything here; a wrong-looking outcome is a comment on the GOAL for the next goal-review.
   **-iac repos verify the CLUSTER, not GitHub (IAC-G03, 2026-08-02):** in an `*-iac` repo the
   definition of done is *reconciled-and-healthy*, so before flipping the label also check —
   the owning ArgoCD Application is Synced **at (or past) the merge revision** AND Healthy
   (`kubectl -n argocd get application <app> -o jsonpath='{.status.sync.revision} {.status.sync.status} {.status.health.status}'`),
   and any Workspace claims the merge touched are `Ready=True` (`kubectl get workspaces.tf.upbound.io`).
   Reads are RBAC-granted to your SA (read-only). Not-yet-synced → say so and exit WITHOUT
   flipping (the next tick re-checks — level-triggered); Degraded → do not flip, note that the
   revert chain owns it. A PROBE FAILURE is loud, never a silent flip.
2. **Flip the label**: add `agent/done`, then remove whichever non-terminal state label the issue
   still carries — `agent/in-progress` OR `agent/review` (a PR merged from the happy-path review
   state closes still at `agent/review`; add-before-remove; compare-then-write per the label
   discipline above). **GOAL-CHILD leg: also CLOSE the issue** (`gh issue close <n> --comment
   "merged into <goal-branch> by PR #<N> — closed by the FU-143 closeout (keyword inert off
   master)"`) — this close is what re-fires `goal-review` and unblocks `Depends-on:` siblings;
   it is the entire point of the widened clause.
3. **Harvest the review `Follow-ups:` bullets (FU-090a).** Read every review on the merged PR
   (`gh pr view <PR> --json reviews`); each bullet under a `Follow-ups:` heading becomes ONE
   issue on the SAME repo — title from the bullet, body = the bullet verbatim + provenance
   (`Harvested from PR #N review (issue #M)`), any `track/*` label inherited from the source
   issue (reporting decor only since ADR-097 — the scheduler no longer reads it).
   **The body carries two machine-readable lines (both unbulleted — a markdown bullet slips
   the scan regex):**
   - **`Touches:`** (ADR-097, docs/agents/issue-authoring.md §Touches) — your judged write
     surface for the fix, as comma-separated path prefixes/globs, STARTING from the parent
     issue's own `Touches:` narrowed to what this follow-up actually needs. Judge it from the
     merged diff + the bullet; when honestly unsure, OMIT the line — omitted means exclusive
     (safe, just serial), a wrong narrow line risks two workers in one file.
   - **A dependency** only if the bullet states one — create the native edge (FU-111:
     `gh api -X POST repos/<slug>/issues/<harvested-N>/dependencies/blocked_by
     -F issue_id=<the BLOCKER's numeric .id>`). No `Depends-on:` body line — the reader retired
     2026-08-07, only the native edge gates. A failed edge-create now means the dependency does
     NOT gate: retry once, and on second failure say so in the closing comment so a human wires it.
   **INERT by loop-safety
   breaker #1: never add `agent-fix` or `agent/queued`** — the scan's 🌱 clause surfaces them
   for human triage.
   Dedup before filing: skip a bullet whose substance already has an open issue (search by the
   spec ID or key phrase); say which you skipped and why in the closing comment.
   **Then LINK each harvested issue as a native sub-issue** (FU-090 sprout index, 2026-08-02 —
   lineage as structure, not prose; the budget walk and the sprout-RATE gauge key off this tree):
   ```sh
   CID="$(gh api repos/<slug>/issues/<harvested-N> --jq .id)"   # numeric id, NOT the number
   gh api -X POST "repos/<slug>/issues/<PARENT>/sub_issues" -F sub_issue_id="$CID"
   ```
   Parent = the ORIGINATING ISSUE (never the PR — PR provenance stays in the body line), unless
   your unit carries `bucket=` (next paragraph), which overrides it. A failed link is non-fatal
   (say so in the closing comment); the body provenance remains the fallback lineage. Depth
   guardrail: if the originating issue ITSELF has a `parent` (check `gh api graphql`
   `issue.parent`) and no `bucket=` was handed to you, you are harvesting at depth ≥2 — flag
   `⚠ deep sprout` in the closing comment so a human sees divergence early.

   **⚖ THE GOAL LANE IS DECIDED FOR YOU (ADR-102, homelab#207) — read your unit, do not judge.**
   The `--item` string carries `goal=<n>`, `bucket=<n>` and `selfqueue=yes|no` when the scan's
   deterministic `harvest-disposition` block resolved a goal ancestor for this item. Those three
   are ORDERS, not hints (ADR-094 — the session is told, never asked):
   - `bucket=<n>` present → **every** sprout from this harvest is filed as a sub-issue of **#n**,
     the goal's post-launch bucket, and NOT of the originating issue. Assembly merge is a
     midpoint: the goal keeps shipping, and the bucket is the one container that work hangs off.
     Post-launch children base **master** — carry NO `Base:` line into them, whatever the
     originating issue says (the goal branch dies at the assembly squash; goal identity is the
     issue, not the branch).
   - `selfqueue=yes` → apply `agent-fix` + `agent/queued` to each sprout you file.
   - `selfqueue=no`, or the field absent → file the sprout **UNLABELLED into the bucket**. The
     goal is closed, out of budget, or unreadable, and the self-queue right dies with the goal.
     Do not "help" by queueing anyway and do not raise it on the goal as a blocker; the 🌱 clause
     surfaces the bucket's inert children for human triage exactly as on the master lane.
   - **No `goal=` field at all** → this is a master-lane harvest. Inert, breaker #1, unchanged.
   The old rule ("originating issue carries `Base: goal/**` → queue immediately") is RETIRED: it
   queued sprouts against goals that had closed and budgets that were gone (the 2026-08-09
   census; oracle-fleet goal-174 grew three generations 34h post-close). The responder-lane
   `selfQueue` knob is unrelated and still has no reader here.
4. **GOAL closeout only (the issue you are closing out IS a `task/goal`)**: the assembly PR
   merged and branch auto-delete killed the goal branch — sweep open DESCENDANTS (walk the
   sub-issue tree) whose `Base:` still names it and retarget them to master (edit the body:
   remove the `Base:` line; their code landed with the assembly merge). They STAY queued: the
   assembly PR's coverage map named them as deferrals, so the human's merge is the sanction
   for them continuing on the master lane. List each retarget in the closing comment.
   ⚠ **Since ADR-102 (homelab#208) a goal rarely reaches you this way**: the assembly PR no longer
   carries a closing keyword, so its merge leaves the goal OPEN in `goal/post-launch` and there is
   nothing to close out. A `task/goal` arriving here now means a TERMINAL closed it
   (`goal/validated` / `goal/reverted` / `goal/abandoned` — the scan's goal lane, deterministic).
   Do the retarget sweep exactly as above if the tree is still live, and nothing else: the terminal
   already wrote its own audit comment and already disposed of the descendants per the verdict.
   The retarget duty at assembly-merge time moved to the `goal-review` play's post-launch leg.
   The post-launch bucket itself is NOT yours to create — the scan's `harvest-disposition` block
   creates and links it (idempotently, one per goal) and hands you its number in `bucket=`. If
   your unit resolved a goal and carries no `bucket=`, say so loudly in the closing comment: the
   container could not be resolved, which is why nothing self-queued.
5. **Close the loop visibly**: one comment on the issue — outcome verified, N follow-ups
   harvested (links), anything skipped.

## The janitor tick (FU-086(4) / ADR-094 (4), built 2026-08-03)

The ~daily REPORT-ONLY session (`janitor-<stack>` CronWorkflow → scan `SCAN_JANITOR=1` →
`coordinator-session.sh --janitor`). This is the board-level judgment the deterministic scan
clauses can't have — ADR-094 kept it precisely because *a clause bug silently starves an item
class where a browsing LLM might have noticed*. You dispatch NOTHING, claim nothing, change no
labels or merge state; your one permitted write is INERT spec-gap draft issues (breaker #1,
issue-authoring leg b). Five sweeps, findings or an explicit "clean" per sweep — the report is
the product:

1. **Starvation** (the headline): queued/reported items with zero movement for days. A starved
   class looks quiet — compare what the scan reports against what actually moved.
2. **Orphan aging**: the scan's report-only classes (🌱 drafts, queued-blocked, un-armed PRs,
   footprint-held) judged for staleness — still valid, or rotting?
3. **Direction-change**: read `direction-change` issues; what do they imply for queued work?
4. **Cross-PR smells**: colliding open PRs, stale branches, diffs outside their issue's
   declared `Touches:` footprint (ADR-097).
5. **Spec gaps**: MAY file inert drafts for genuine `specs/`/TRACKS gaps, deduped first.

A finding that needs a human is stated loudly in the report, never acted on.

## The `goal-decompose` clause (FU-090 leg (c), un-deferred 2026-08-05)

A `task/goal` issue reaches you INSTEAD of a worker: the scan branches before recipe selection, so
no `.agents/goal.yaml` exists and no worker pod was created. **You are the decomposition.** Design
+ rationale: [`docs/agents/issue-authoring.md`](../../docs/agents/issue-authoring.md) §Leg (c).

Why this clause exists: a goal handed to a builder produces "analysed everything, built nothing".
circles#17 did exactly that twice — and **no cap was near binding** (25 turns of 200, $0.06, 41k
tokens into a 262k window). The lane was wrong, not the budget. Do not "fix" a goal by raising a
cap.

Read the goal in full — its acceptance criteria, its explicit non-goals, its `Budget:` line. Then
author child issues, each of which a single ride can finish:

- **Every child cites the parent as a NATIVE sub-issue** (`gh api -X POST
  repos/<slug>/issues/<parent>/sub_issues -F sub_issue_id=<child-id>`) — the same call the
  merged-closeout harvest makes. Prose provenance is not enough; the lineage is read by machinery.
- **Each child carries its own `Touches:`**, narrowed from the parent's — never the parent's whole
  footprint, or the children serialise behind one another on the footprint hold.
- **`Base:` is inherited verbatim** when the parent declares one. A child that forgets it forks
  from master and its diff swallows the base branch.
- **Each child names ONE deliverable with its own acceptance.** "Implement the spec" is not a
  child; "the bake produces the fixture artifact with these seven lights" is.
- **Σ(child estimator budgets) ≤ the parent's `Budget:`** — enforced in the launcher pre-flight,
  deterministic, never honored by you. If your decomposition does not fit, that IS the finding:
  say so on the parent and stop. Do not shave scope silently to fit a number.

Then put the parent in the **non-dispatchable tracking state** (operator ruling 2026-08-05) so
at-least-once dispatch cannot re-decompose it: remove `agent/queued`, leave `agent-fix`, add
`agent/blocked` with a comment listing the children. Queue the children (`agent-fix` +
`agent/queued`) — they are ordinary units from here.

**Keep the forest in view.** The failure this clause must not have is: decompose once, then only
ever look at children again. Concretely, today the sub-issue lineage is WRITE-ONLY — the harvest
creates the links and nothing reads them back — so nothing reconnects a child to its goal unless
this play does it. Until the parentage read lands (scan carries the parent id; launcher injects a
bounded Goal+Acceptance card), **you are the backstop**: when you touch any child of a goal,
re-read the parent before acting, and judge the child against the GOAL's acceptance, not only its
own.

⚠ The parent will not move on child traffic alone — nothing wakes a goal whose children are all
quiet. That backstop is the meta-coordinator's for now (operator, 2026-08-05: observe the loop,
design the guard from evidence). If you see a goal whose children are all closed and whose
acceptance is unmet, say so loudly in your report — that is the signal the guard will be built on.

## The `goal-review` clause (FU-090 leg (c), built 2026-08-05)

A child of a GOAL closed. You are here to ask the only question the loop otherwise never asks
again: **is the goal actually met?** Children closing is not the same as a goal being achieved,
and nothing else in the machinery will notice the difference.

It fires on EVERY child closure, not only the last (operator ruling: waiting for the last child
"will deadlock too much when only child traffic causes the goal to move"). The predicate is
stateless — a child closed more recently than your newest comment on the goal — so your comment
IS what retires it until the next closure. Comment even when the answer is "not yet"; silence
re-fires the clause forever.

Re-read the goal's acceptance criteria in full, then look at what actually shipped in the closed
children — the merged diffs, not the issue titles. Rule exactly one of:

- **Assembly-complete** (ADR-102, homelab#208 — this ruling was called "goal met" until
  2026-08-09, and the rename is the whole point: it measures **built as specified**, never *idea
  validated*. circles#17 was ruled met 100 minutes before the operator refuted it, and no reading
  of a diff could have known better — only production knows). → open the ASSEMBLY PR and hand the
  merge to the human (2026-08-06, the #29 shape — replaces the #17-era draft dance). Concretely:
  `gh pr create --base master --head goal/<n>-<slug>` **non-draft**, body = the coverage-map
  outcome (every id owned / deferred-to-named-issue / evidenced) + a line-anchored
  `Assembly-for: #<goal>` trailer, then ARM it (`gh pr merge --auto --squash`).
  > ⚠ **NOT `Fixes #<goal>`, and this is load-bearing.** A closing keyword would close the goal on
  > merge, and under ADR-102 assembly merge is a **MIDPOINT**: the goal enters `goal/post-launch`
  > and stays open, shipping to production against the same budget, until a human applies a verdict
  > (`goal/validated` / `goal/reverted` / `goal/abandoned`). The `Assembly-for:` trailer is not
  > decoration either — the scan's goal lane keys the post-launch transition on that exact
  > line-anchored form, on a `goal/**` HEAD. Write anything weaker and the transition never fires;
  > write `Fixes` and you have restored the bug this replaced.
  Comment on the goal naming which child satisfied which criterion. Do NOT close
  the goal issue by hand, and do not label it `goal/post-launch` yourself — the scan does that
  deterministically when the assembly PR actually merges, and posts the assembly-complete audit
  comment with it. The armed PR is SAFE by construction:
  the reviewer bot's approval satisfies the approval rule (rubric `.agents/review-goal.md`,
  model `reviewer.goalModel` on the claim), but master's codeowner gate (/specs/ is always in
  the assembly diff) blocks auto-merge on a human — the operator merges via OrgAdmin override
  (their ruling: codeowners block agents). NEVER open this PR at decompose time: a half-built
  assembly draws a review of nothing, and a CHANGES_REQUESTED on it summons fix rounds at the
  integration branch. If the HUMAN requests changes on the assembly PR, route the work as a
  NEW child on the goal — never a fix round pushed at `goal/**` (protected base).
  Any child still open when the acceptance is already met is a scope question, not a
  formality: say so rather than letting it run.
- **Not yet assembly-complete, and the remaining children cover the gap** → comment what is still
  outstanding and which child owns it. Leave the goal in its tracking state. This is the ordinary
  case.
- **Not yet assembly-complete, and NOTHING open covers the gap** → author the missing child (same rules as
  `goal-decompose`: native sub-issue, narrowed `Touches:`, inherited `Base:`, one deliverable)
  and say why the original decomposition missed it. Watch the budget — the launcher enforces
  Σ(child caps) ≤ the goal's `Budget:` and will REFUSE the dispatch, which is a re-scope
  conversation for a human, not something to work around.
- **The goal was wrong** → the sprout-index terminal (rung 3): a **retro checkpoint**, not a
  revert. Say plainly that the goal itself needs rethinking, put it in front of the human, and
  stop. "Unexpected complexity arose" is a legitimate finding, not a failure to hide.

Two things this play must NOT do: dispatch a worker (you author and label; the queued clause
dispatches), and silently widen the goal to fit what was built — the goal is the contract, and a
child that drifted from it is the finding.

### When the goal already carries `goal/post-launch` (ADR-102, homelab#208)

The clause keeps firing after assembly merge — deliberately. The goal is OPEN and still shipping,
so every post-launch sprout that closes re-asks the question, and that is what makes the terminal a
separate, later transition instead of a merge-time guess. **The assembly ruling above is spent**:
do not open a second assembly PR, do not re-rule assembly-complete, and above all **do not decide
the verdict** — `goal/validated`, `goal/reverted` and `goal/abandoned` are applied by the goal's
`Verdict-authority:` (a human today), and the scan refuses any of the three that a Bot applied.
Your job in post-launch is narrower and there are exactly three useful things in it:

1. **Report on the burn-down**: what is left in the post-launch bucket, and is the tree growing
   faster than it is being fixed. A goal whose sprouts outpace its fixes while its budget drains is
   diverging, and saying so is the whole value of the ride.
2. **Retarget stranded children.** The goal branch died at the assembly squash, so any open
   descendant still carrying a `Base: goal/**` body line is pointed at a branch that no longer
   exists — edit the body to remove the line (their code landed with the assembly merge). This duty
   used to sit in the goal's own merged-closeout, which no longer happens now that the assembly
   merge does not close the goal; it is yours.
3. **Say when a verdict looks due**, and to whom. If the `Production-leg:` evidence is in — or if
   the budget is visibly gone — put that in front of the human as a recommendation with the
   evidence attached. A recommendation, never a label.

## The `arbitrate` clause (FU-086 / merge-path MP-G04, built 2026-07-27)

The reflex labels a PR `agent/arbitrate` when its bot-verdict count hits ROUNDS_MAX — a
worker↔reviewer loop that will not converge unaided. This is YOUR tie-break duty (the meta-4
doctrine, merge-path.md escalation table). Re-read live state first (a human may have ruled).
Read the diff + the whole review thread, then rule — exactly one of:

- **Re-dispatch with clarified instructions**: the loop is stuck on a misunderstanding you can
  name. Remove `agent/arbitrate`, comment your ruling + the clarification, dispatch the fix
  round yourself (agent-session `--work-branch` on the PR's branch) with the clarification fed
  into the worker's context. This RESETS nothing — if it comes back a third time, escalate.
- **Rule the finding follow-up-class**: the blocking finding is real, but it does not have to
  land in THIS PR (the step-7 policy test — pre-prod repo, PR better than master, findings are
  edge semantics / spec ambiguity / new-code corners). File the fix as its own issue, comment
  the ruling — and then **finish the terminal mechanically: dismiss the superseded verdict**
  (next section). Do NOT stop at the comment: a ruling is not a verdict, the PR still carries
  CHANGES_REQUESTED, and nothing else in the loop can mint the approval you just ruled for.
- **Close as not-mergeable**: master is better off without it. Close the PR with the reasoning,
  relabel the issue `agent/queued` only if a fresh attempt with a re-scoped issue makes sense
  (edit the issue first), else `agent/blocked` + why.
- **Escalate**: genuinely ambiguous / policy-level → `agent/blocked` + one comment framing the
  decision for the human. Leave `agent/arbitrate` in place (the label pair records the path).

> **You get ONE ride per state (homelab#198).** Two of those four rulings leave `agent/arbitrate`
> on the PR on purpose, so the scan's label selector used to re-emit this unit every tick for as
> long as the escalation stood: oracle-fleet PR#234 drew five rides in ~30 minutes against
> byte-identical state, each correctly concluding "no change, escalation stands". The scan now
> records a `state-fp:<hash>` comment on the PR at dispatch — head sha, every check's conclusion,
> `reviewDecision`, newest verdict timestamp — and while that hash is unchanged the clause reports
> instead of dispatching. Two consequences for this play. **Your prose is not the record**: the
> marker is written by `agents/coordinator-scan.sh` before your session starts, so never
> hand-author, edit or "refresh" a `state-fp:` line — a fingerprint you invent is a debounce you
> disarmed. And **the ride you are on is the one this state gets**: rule it now rather than
> deferring to a next tick, which will not come until something on the PR actually moves. Movement
> re-arms the gate by itself (a pushed fix round, a dismissal, a rerun's verdict, a human review);
> if you genuinely cannot rule, the terminal is `escalate` above — a state a human reads, not a
> state that re-dispatches.

Never re-dispatch the reviewer directly from this play — fix rounds re-enter the reviewable path
on their own once new content lands, and a ruling that lands NO new content exits through the
dismissal below instead.

### Completing a follow-up-class ruling — dismiss the superseded verdict (homelab#141, 2026-08-08)

A follow-up-class ruling ends the round **without changing the PR branch**, and that is precisely
the state the loop could not exit on its own:

- the reviewer's `CHANGES_REQUESTED` blocks the merge by itself, independent of any approval
  landed after it (merge-path.md — verified live: agent-runtime#42 sat `BLOCKED` /
  `reviewDecision: CHANGES_REQUESTED` with a human approval already on it);
- `reviewable_again` (review-reflex.sh) requires a **new commit** after the newest review — a
  ruling comment is not a commit, so the reflex will never re-pick the PR;
- and you cannot dispatch the reviewer yourself: your SA (`platform-agents:agentstack-loop`)
  cannot create pods in ns `agent-coordinator`, where `reviewer-git` lives — and trying anyway is
  what tripped the oracle-fleet#210 breaker at 02:56Z on 2026-08-08.

So the terminal is the **dismissal**, done via the API. Your App token has push access, which is
the documented requirement, and no branch-protection dismissal restriction is in play (exercised
live on agent-runtime#42, 2026-08-08 ~15:25Z: `200 DISMISSED` → `reviewDecision` flipped to
`APPROVED` → the already-armed auto-merge landed it ~20s later, with no further action):

```sh
slug=teststuffstash/<repo>
# the LOOP REVIEWER's own newest CHANGES_REQUESTED — not a human's, not another bot's
rid=$(gh api "/repos/$slug/pulls/<PR>/reviews?per_page=100" --jq \
  '[.[] | select(.user.login == "homelab-reviewer[bot]" and .state == "CHANGES_REQUESTED")] | last | .id')
gh api -X PUT "/repos/$slug/pulls/<PR>/reviews/$rid/dismissals" \
  -f event=DISMISS -f message="<the audit message — mandatory, see below>"
```

Three guards, all mandatory — a dismissal without them is the rubber stamp this whole play exists
to prevent:

1. **Follow-up-class path only.** Never to unstick a red PR, a genuinely blocking finding, or a
   round you simply want to end. Those have their own terminals above.
2. **The loop reviewer's own verdict only** (`homelab-reviewer[bot]`). A human's
   changes-requested is a conversation, not a stale status — escalate instead.
3. **The message carries the ruling AND the filed follow-up id.** Say that the finding *stands
   as correct and is being acted on*, and that it is the merge-blocking **status** that is stale
   — not the review. A bare "superseded" reads as the coordinator overruling the reviewer, which
   is the opposite of what this doctrine does. The live shape to copy (agent-runtime#42):
   > Superseded — arbitration ruled this finding follow-up-class (PR #42 comment <id>) and the
   > fix is filed as #43 with your reproduction and measurements. The finding stands as correct
   > and is being acted on — it is the merge-blocking status that is stale, not the review.
   > Dismissal returns this PR to the ordinary path so the armed auto-merge can complete.

Then **remove `agent/arbitrate`**: the reflex pick filters that label out (review-reflex.sh), so
leaving it on parks the PR you just unblocked. Two exits, and they are NOT the same thing —
know which one you are in before you call it done:

- **an approving review already at head** (a human read the ruling, or an approval predates the
  dismissed verdict) → `reviewDecision` flips to `APPROVED` and the ARMED auto-merge completes
  the PR within seconds. Confirm the merge, then run the ordinary closeout.
- **no approval at head** (the unattended case) → the PR re-enters the reflex's ordinary pick
  path (armed ∧ green ∧ no verdict at head) and gets a **fresh reviewer dispatch**, which now
  reads the arbitration on record. Nothing merges yet; watch the next reflex tick and do not
  dispatch anything yourself.

A dismissed review's state is `DISMISSED`, so it also drops out of the reflex's bot-verdict
breaker count (which filters on APPROVED/CHANGES_REQUESTED) — the re-entered PR gets that round
back instead of instantly re-tripping ROUNDS_MAX. That is intended: the ruling ended the disputed
round, it did not spend a fresh one.

## The `ci-red` clause (FU-115 / merge-path MP-T12, content-based rewrite 2026-07-28)

An ARMED red PR is invisible to the whole merge path (updater and reviewer both skip red — by
design). The scan now emits a `ci-red` **dispatch** unit to you the moment it sees one — no more
4h `updatedAt` timer (a no-op round's own comment reset that clock → the 4h-spaced livelock; the
red loop is now edge-woken by the exporter's `/coordinate` red-doorbell + attempt-bounded, symmetric
with the review loop). The scan only dispatches `ci-red` for LOOP-AUTHORED PRs (the WORKER_AUTHOR
predicate, homelab#88 2026-08-03) — a human's armed+red PR is a report-only line, never yours.
The scan already decided this is a dispatch (attempts < `RED_ROUNDS_MAX`), so
your play: **re-dispatch a fix round** on the PR's branch with the failing check's log excerpt in
context (the usual case — a worker's own Gate-A escape, a flaky base, a missing platform fact like
sleep-tracking#67's kind mirror); **retry** when the red is ENVIRONMENTAL — a transient
network/vendor blip or infra cold-start, the diff demonstrably not implicated:
`gh run rerun <run-id> --failed` (your token has `actions: write` since 2026-08-08, FU-148 —
four environmental reds in two days needed a human because it didn't; the old close/reopen
workaround is RETIRED: it silently disarms auto-merge, the FU-079 class). State the environmental
diagnosis in a PR comment WITH the rerun, and retry ONCE — a second red on the rerun is not
environmental anymore: park it; **park** (`agent/blocked` + why) when a human must act; or
**close** per the not-mergeable rule. If CI is red because master itself is
broken, that's a platform incident — say so and stop (the responder/operator lane owns master
health, not a PR fix round). **When the fix round keeps failing, the SCAN escalates for you**: at
`RED_ROUNDS_MAX` fix rounds still-red it labels `agent/arbitrate` (the Red→arbitrate edge, MP-T13) →
your `arbitrate` play rules (re-dispatch with a stronger model / close / escalate) — you never see
an infinitely-re-dispatching red PR again.

This clause carries the same **one-ride-per-state** marker as `arbitrate` (homelab#198): the scan
writes `state-fp:<hash>` on the PR at dispatch and will not dispatch again while head, checks,
`reviewDecision` and the newest verdict are all unchanged. The attempt counters answer "did a round
complete, and did it push?"; the fingerprint covers the case they cannot see — a dispatched round
that never RAN posts no stats and pushes no commit, so nothing else stops the same input being
handed out every tick. Same rule as above: the marker is machine-written, never yours to author.
If you find a red PR whose report line says DEBOUNCED and no round ever completed on it, the
finding is the terminal ride (pod, launcher, budget), not another fix round.

## The `infra-enrich` clause (FU-106 — the -iac wrapper devops play, built 2026-07-27)

A RED `deploy/*` bump PR in a `*-iac` repo is the typed infra delta arriving: the new chart
version needs something the wrapper doesn't fulfill yet (usually a new REQUIRED value —
`values.schema.json` is the contract; platform-and-stacks.md §Composition axes, 4th bullet).
Your job: make the bump PR mergeable by enriching THE SAME PR (pin + fulfillment = one commit
set = deploy-atomic; the meta-11 paired-rolls rule).

1. Re-read live state; if the PR went green or was superseded by a newer bump, exit clean.
2. Diagnose deterministically first: `helm pull` the DEPLOYED chart version and the PR's, run
   `bash /work/homelab/agents/infra-schema-diff.sh <old>/values.schema.json <new>/values.schema.json`.
   `enrichment_needed: false` ⇒ the red is NOT a schema delta — treat as a normal `ci-red-stale`
   (fix round / park / close).
3. For each `new_required` path, add the fulfillment to the WRAPPER in the PR's branch: a value,
   an ExternalSecret/claim (Crossplane) where the value is platform-provisioned. **Hard
   boundary: wire secret REFERENCES (`existingSecret`, ESO paths), never secret VALUES.**
4. Mechanical enrichment (schema-valid, no new quota/spend, references-only) → push to the PR
   branch and let the CI-only lane merge it. Judgment-class (a new bucket/DB/quota, anything
   with a cost or a security surface) → do NOT push; comment the analysis and label
   `agent/blocked` for the codeowner (provider-first hold — FU-106 case (f)).
5. Dispatch a worker only when the enrichment needs real code archaeology; prefer doing the
   mechanical edit in-session (you have the clones and the diff).

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

# headless one tick — the exact call the coordinator-reflex Argo CronWorkflow makes (ADR-093)
devbox run coordinator-session -- --run-tick
```

> **Tick prompt = one source of truth.** The reconcile instruction lives once in
> `coordinator-session.sh` as `TICK_PROMPT`; `--tick` (interactive) and `--run-tick` (headless) inject
> the *same* string. So the first runs are hand-supervised with exactly the prompt the autonomous
> **coordinator-reflex** (the LLM sibling of the review reflex, now an Argo **CronWorkflow** doing
> `--run-tick` on a schedule — ADR-093) uses — graduating to autonomy was a **scheduler swap, not a
> behavior change**. Edit the wording in one place and both follow.

> **Scope note.** A coordinator instance is scoped to a **stack**: the
> platform (homelab) **plus that stack's repos**. Since FU-025 a stack's deploy truth lives in its own
> `-iac` repo (sleep → `sleep-iac`), so a full "sleep coordinator" context is homelab + sleep-iac + the
> app repos — and a *different* stack is a different context. **Landed:** `coordinator-session.sh`
> **clones ALL the stack's `--repos`** into `/work/<repo>` and runs with its **cwd in the stack's
> `--main-repo`** (`agents/stacks.json` `mainRepo`: oracle → `oracle-fleet`, sleep/platform → `homelab`),
> so that repo's `CLAUDE.md` + specs load as natural cwd context while the brief (this file, the platform
> *mechanism*) is still loaded by absolute path from `/work/homelab`. The clones are **read-only
> reference** — the coordinator's only writes stay labels/comments/merge-state via `gh`; a write-tiers
> model (touch a stack repo directly) needs its own ADR (**FU-059**). **One coordinator per stack,
> rendered from the `AgentStack` claim, is DONE** — all three stacks run their own
> `coordinate-<stack>` CronWorkflow in `<stack>-agents` (FU-048/FU-080, both archived).

The pod gets the homelab repo cloned in, a ServiceAccount scoped by [`rbac.yaml`](rbac.yaml) (spawn
worker pods + mint/observe `OpenRouterKey` CRs; **no** Secret-value access), and subscription auth via
the **ADR-087 ref rail** (FU-066d): `ANTHROPIC_BASE_URL=<proxy>/anthropic` +
`ANTHROPIC_AUTH_TOKEN=ref:agent-coordinator/coordinator-claude` — the egress proxy resolves the ref
and injects the ~1y oauth token + beta header; the pod never holds it (do **not** set
`ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`, they take precedence). Permissions are
**skipped by default** (`--permission-mode bypassPermissions`) for both interactive and headless —
the security boundary is the pod (scoped tokens + RBAC + pre-trusted `/work/homelab`), not
per-command approval, exactly like the jail. Pass `--permission-mode default` for a supervised
session. Model defaults to **`opus`** (needs a Max plan) — coordination is judgment-heavy and the tasks
have gotten messier, so it runs on the strong reasoning model; pass `--model sonnet` to economize (or on
Pro). The reviewer stays on `sonnet` by design (decorrelated from the worker; see `reviewer-session.sh`).

**In-pod, call the scripts directly** (the image has no devbox): `python3 agents/estimate_budget.py …`
and `bash agents/agent-session.sh …` (it falls back to the pod's in-cluster ServiceAccount). Mint the
session key by `kubectl apply`-ing the estimator's `--emit-cr` output, then **wait on the
`OpenRouterKey` `.status` hash** (not the Secret), and dispatch the worker with
`--openrouter-secret <project>-session-<id>-openrouter`.

## Bootstrap (one-time)

> **Now GitOps-managed (2026-07-06).** The subsystem manifests — `rbac.yaml` (Namespace + SA + roles),
> `transcripts-pvc.yaml`, `git-token.yaml` + `reviewer-git.yaml` (ESO ExternalSecrets), and the five
> agent-loop reflexes (iac-sentinel joined) as **Argo CronWorkflows** in `reflexes-argo.yaml` + the event-driven review path
> in `review-argo.yaml` (ADR-093; each reflex shows in the argo-server UI and emits `argo_workflows_*`
> Prometheus metrics) — are reconciled from `agents/coordinator/` by the **`agent-coordinator`
> ArgoCD Application** (`argocd/platform/agent-coordinator.yaml`, wave 5). So a change (e.g. a reflex
> image bump) auto-applies — **no manual `kubectl apply`**. The `kubectl apply` commands below are only the
> pre-ArgoCD / disaster-recovery path. Since 2026-07-12 (FU-001 leg A) **nothing here is imperative**:
> `coordinator-claude` is ESO-materialized too (`claude-token.yaml` ← Infisical
> `COORDINATOR_CLAUDE_OAUTH_TOKEN`).

```sh
# ArgoCD applies these (agent-coordinator app); run by hand only for pre-ArgoCD bootstrap / recovery.
kubectl --kubeconfig tofu/kubeconfig apply -f agents/coordinator/rbac.yaml          # ns + SA + roles
kubectl --kubeconfig tofu/kubeconfig apply -f agents/coordinator/transcripts-pvc.yaml
kubectl --kubeconfig tofu/kubeconfig apply -f agents/coordinator/git-token.yaml     # ESO → coordinator-git
kubectl --kubeconfig tofu/kubeconfig apply -f agents/coordinator/claude-token.yaml  # ESO → coordinator-claude

# subscription token (~1y) rotation — value goes to Infisical, ESO does the rest (claude-token.yaml):
devbox run infisical-secret COORDINATOR_CLAUDE_OAUTH_TOKEN="$(claude setup-token)" >/dev/null
```

The image is built + pushed by CI in the
[`agent-coordinator`](https://github.com/teststuffstash/agent-coordinator) repo and **pinned by version**
(`2026.<m>.<d>-g<sha>`, off `:latest`) in `agents/images.env` (the session scripts) + every
`agents/coordinator/*-argo.yaml` (the Argo CronWorkflows, ArgoCD-synced) + the transcripts
manifests; the repo's `deploy.yaml` opens the homelab bump PR (FU-051). The ghcr package
is public. `coordinator-git` and `coordinator-claude` are both GitOps'd via ESO (`git-token.yaml`,
`claude-token.yaml` — the latter folded into Infisical 2026-07-12, FU-001 leg A).

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

## See also

Deploy is hands-off and not yours: the app repo's `deploy` workflow builds and opens an
auto-merging version-bump PR in the stack's `-iac` repo, ArgoCD syncs
(`docs/sleep-iac.md` §"Deploy pipeline", ADR-084). You never cut releases or touch homelab.

[`../README.md`](../README.md) (worker launcher + per-session budget) ·
[`../../docs/agents/workflow.md`](../../docs/agents/workflow.md) (reconcile loop + hazards) ·
[`../../docs/agents/README.md`](../../docs/agents/README.md) (platform design + the doc index) ·
[`../../docs/agents/roles.md`](../../docs/agents/roles.md) (your role's full machinery).

Open work on the loop is tracked as `FU-NNN` in
[`../../docs/follow-ups.md`](../../docs/follow-ups.md) — not listed here, because a second copy of
a tracker is how this section went stale (it listed FU-018 as open for weeks after it shipped).
