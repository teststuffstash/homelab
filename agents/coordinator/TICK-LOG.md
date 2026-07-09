# Tick log — manual meta-coordination of the oracle stack

_Started 2026-07-09. Purpose: run the coordinator "by hand" (one tick per world-state change,
**single coordinator/worker active at a time**) and log every condition → command pair, so the
future coordinator reflex (the CronJob sibling of review-reflex) is specified from evidence, not
guesses. Kept in-repo because this file IS the reflex's requirements draft._

## The emerging reflex pattern (condition → action)

| # | Condition (level-triggered, from labels/pods/PRs) | Action | Owner today |
|---|---|---|---|
| C1 | issue `agent/queued` ∧ no worker pod in stack ∧ no open agent PR | fire a tick (it claims, estimates, mints, dispatches) | meta (manual) |
| C2 | worker pod Running | **wait** — no tick; WIP=1 | meta |
| C3 | PR open, CI pending/green | wait — updater + review reflexes own it | reflexes (LIVE) |
| C4 | worker Completed ∧ no PR ∧ no pushed branch | diagnose from run.log → fire a tick (coordinator re-dispatches round N+1 fresh) | meta |
| C5 | worker Completed ∧ pushed branch ∧ no PR | fire a tick (resume from WIP branch) | meta |
| C6 | PR merged (`agent/done` due) | fire a tick (bookkeeping + queue-release decision for the next dependency-ordered issue) | meta |
| C7 | `agent/blocked` | escalate to Rasmus; no tick | human |
| C8 | systematic failure pattern in run.log | retro-grade fix as PR to process files (recipe/rubric), THEN re-tick | meta→human gate |
| C9 | PR open ∧ auto-merge NOT armed | arm it (`gh pr merge --auto --squash`) — decision-free; unarmed PRs are invisible to the review reflex | meta (reflex candidate) |

Queue-release rule (single-active mode): only ONE issue carries `agent/queued` at a time; the
next is queued at C6 per the dependency order (TRACKS/gantt: #1 → {#2, #3} → #4).

## Loop safety — why agent-created issues can't spiral

Agents (coordinator/retro/workers) MAY create issues. Four independent breakers keep that from
becoming a self-feeding loop; ALL must hold in the automated reflex later:

1. **The execution gate is a label only humans apply.** `agent-fix` + `agent/queued` are the
   opt-in; an agent-created issue without them is inert. Formalize before automation: reflexes
   refuse to queue issues authored by bot identities unless a human has touched them (labeled or
   commented) — provenance is visible in the issue author.
2. **Economic ceiling**: every round needs a minted session key under the weekly standing budget
   ($5 on oracle-fleet). A runaway loop starves at the ceiling and 403s into `agent/blocked`.
3. **Round bound**: max 3 rounds per issue → `agent/blocked` → human.
4. **WIP=1** (this exercise): no dispatch while any worker/coordinator pod is active in the stack.

## Log

### 2026-07-09 06:23 — tick 1 (C1)
- **World**: #1 `agent/queued`; no pods; no PRs.
- **Command**: `devbox run coordinator-session -- --stack oracle --repos "oracle-iac oracle-fleet" --main-repo oracle-fleet --run-tick`
- **Outcome**: textbook. Claimed #1 (label hygiene correct), estimator md/$1 cap/$0.54 est,
  session key minted, worker `agent-oracle-fleet-062617` dispatched, auto-merge armed,
  transcript uploaded (`oracle/tick-…` — NB: stack-vs-project prefix inconsistency; workers use
  `oracle-fleet/issue-1/…`. Pick one before FU-057 keys the ledger off prefixes).

### 2026-07-09 06:36 — event: worker terminal, no PR, no branch (C4 + C8)
- **run.log**: real progress (scaffold, adapted to `devbox run -- node` after PATH 127), then
  fatal: model emitted ONE giant file-write tool call, truncated at ~15k chars → goose
  `-32602 EOF while parsing` → run died at 601s, $0.0533. Push-early rule violated (nothing
  pushed) → zero resumable artifact.
- **Lessons → recipe (C8, via the human gate)**: (a) large files are written INCREMENTALLY —
  multiple small writes/appends, never one monolithic tool call; (b) push-early must happen at
  the FIRST commit-worthy state (scaffold compiles), not only at RED.
- **Action**: recipe hardening committed to `.agents/fix.yaml` (CODEOWNERS path — Rasmus's
  standing review), then tick 2.

### 2026-07-09 06:49 — tick 2 (C4) — the most instructive one yet
- **Command**: same tick command as tick 1.
- **Outcome**: coordinator found #1 `in-progress`, no pod, no PR — and concluded the prior round
  **"died before dispatch"** (it re-used the round-1 key name and dispatched
  `agent-oracle-fleet-065344`, now Running WITH the hardened recipe). Correct reconciler behavior
  on the evidence it had — but the history reading was wrong: round 1 DID run and die.
- **Why it couldn't know — two lessons:**
  1. **Meta-coordinator error (mine): never delete terminal pods before the next tick has read
     them.** Pod deletion destroyed the only kubectl-visible record. New meta-rule: pods are
     cleaned up only AFTER the following tick's world-read.
  2. **Platform gap (the real one): a worker that dies without opening a PR leaves ZERO GitHub
     trace** — stats post as PR comments, so no-PR deaths are invisible to "state lives in
     GitHub". Fix for the launcher: on terminal-without-PR, post AGENT_RUN_STATS + failure tail
     as an ISSUE comment (then round accounting stays truthful too — this round is really r2,
     but the coordinator had no way to count r1).
- **Also**: coordinator transcripts land under `oracle/tick-…` (stack) while worker used
  `oracle-fleet/issue-1/…` (project) — prefix inconsistency confirmed twice now.

### 2026-07-09 07:15 — event: PR #5 opened, worker Succeeded (C3 + C9)
- **Stats**: 1168s, $0.1049, ci_passed=true in-pod (Gate A), branch `fix/issue-1-chassis-scaffold`.
  The hardened recipe held: incremental writes, PR opened properly. 14 files, +3200, 29 tests,
  seed-format contract consumed from `specs/use-cases/uc-1/expected-seeds/`.
- **Gap found (C9)**: auto-merge was NOT armed at PR-open (the tick-2 coordinator dispatched
  manually from the runbook and the launcher's arming step didn't fire) — and the review reflex
  deliberately ignores unarmed PRs, so the PR would have sat invisible forever. Meta armed it.
  Reflex spec note: "arm at PR-open" must be guaranteed by exactly one owner (launcher), with C9
  as the level-triggered repair.
- **Now**: C3 — reflexes own it (CI on homelab-ephemeral → review reflex → reviewer bot →
  auto-merge). Meta stands down; watching for terminal state. Pod 065344 NOT deleted (tick-2
  meta-rule) until the next tick reads the world.

### 2026-07-09 08:50 — event: reflex-gap #4 — review reflex was sleep-hardcoded (C8)
- **Symptom**: PR #5 green (CI success 07:13) + armed + current + unapproved for 90 min; reflex
  logs every 5 min: only `[sleep-tracking] / [snore-recorder] nothing to review`.
- **Cause**: `AGENT_REPOS` hardcoded in `review-reflex.yaml` (pre-stacks era).
- **Fix (pushed, bypass)**: `review-reflex.sh` now derives repos from `agents/stacks.json`
  (fresh homelab clone each tick ⇒ always current); env removed from the CronJob (ArgoCD syncs).
  Side-effect accepted & noted: iac repos (`require_approval=false`) may get harmless reviewer
  dispatches in the short window before green auto-merges them — observe, filter later if it
  actually burns reviewer quota.
- **Reflex-design lesson #4**: every reflex's scope must come from the ONE stack registry, never
  its own list. (Same lesson as coordinator-scan's `stacks_json()` swap-point — the reflexes
  predate it.)

### 2026-07-09 09:25 — event: reflex-gap #5 — reviewer token sleep-scoped (C8)
- **Good news first**: the #4 fix worked — the reflex dispatched `reviewer-oracle-fleet-5` on its
  first tick with the derived repo list. And P0 capture held on failure: the dying reviewer still
  uploaded its manifest+transcript to the bucket.
- **Symptom**: reviewer died on `GraphQL: Could not resolve to a Repository` — its
  `reviewer-git.yaml` `repositories:` was sleep-only (the App installation already covered the
  oracle repos, per docs/github-apps.md).
- **Fix**: widened to the coordinator-git set (pushed, bypass); Argo synced; ESO force-re-minted
  (refresh 09:28); Error pod deleted AFTER evidence capture (log excerpt here + transcript in
  bucket — the meta-rule is satisfied by capture, not by pod hoarding).
- **Count: 5 gaps, ALL stale registrations.** Three are per-identity token repo lists
  (coordinator FU-060, reviewer here, worker's was wired correctly by luck of being new). Until
  the AgentStack claim renders these from one object (FU-048), add the deterministic
  reconciliation gate: homelab CI asserts every stacks.json repo appears in coordinator-git +
  reviewer-git lists — the monitoring-over-testing principle applied to the platform itself.
- **Next**: reflex re-dispatches on its next tick (level-triggered — PR #5 still
  green+armed+unapproved).

### 2026-07-09 09:35 — viewer observation (while reviewer 093007 runs)
- "No reviews visible for oracle-fleet" — correct, not a bug: no oracle review has COMPLETED
  (the 09:25 attempt died pre-claude → manifest-only upload → invisible to the jsonl-only sync).
  Sleep's `sleep-tracking--pr-19` renders fine, proving the reviewer pipeline.
- Two stated properties to document with the viewer: (a) **failed sessions are invisible in the
  GUI** (manifest-only) — failures belong to the ledger/Grafana lane (FU-057); (b) the
  stack-vs-project prefix split is user-visible in the flattened listing (`oracle--tick-*` vs
  `oracle-fleet--pr-5`) — decide the convention before FU-057 keys the ledger.

### 2026-07-09 09:5x — event: PR #5 CHANGES_REQUESTED (C-table: review round)
- **Review quality: high.** Two blockers (UTC-vs-Tallinn "today" — a real domain defect; the
  omitted-paragraph TOC path shipped as a bare title, untested and unflagged against the ⚖ spec
  line) + three follow-ups (lexicographic points ordering, unclosed WAL DB, unused imports).
  Citation invariant verified held. The reviewer also independently caught the worker's unflagged
  spec gap — the flagged-spec-changes rubric works.
- **Spec-first repair BEFORE dispatch**: both review-found ambiguities pinned into
  specs/tools/statute.md as ⚖ rows ("today = Europe/Tallinn"; numeric points ordering) — the fix
  round implements rules, not review opinions. (Meta note: my line-based edit briefly mangled the
  paragraph; caught by reading the diff, repaired — even meta-coordinators need the read-your-diff
  rule.)
- **Next**: tick #3 → coordinator round 2 with reviewer comments fed to the fixer.

### 2026-07-09 09:44 — tick 3 (review round transition) — clean
- Coordinator: identified CHANGES_REQUESTED + no live worker as the round transition; **relayed
  reviewer comments into the issue** (the recipe's context channel — unprompted, correct);
  noticed master moved due to the spec pins and directed the fixer to **rebase the PR branch**;
  estimated (md/$0.54), minted `issue-1-round-2`, dispatched `agent-oracle-fleet-094358`.
- Round accounting note: coordinator calls this round 2 (it can't count the invisible first
  death — the gap-#1 launcher fix will make future counts truthful).

### 2026-07-09 09:55 — round 2 complete; reflex self-healed a CI race; meta-probe false positive
- **Worker r2** (405s, $0.054): all 5 review items fixed on the rebased PR branch, +1 TOC test
  (30 green), correctly reported "No specs/ edits — behavior now matches the ⚖ requirement".
  Push landed (`5b27604`), CI green 09:50:00.
- **Reflex race, handled by design**: the 09:50:03 tick saw a not-yet-green rollup ("nothing to
  review"); the 09:55 tick dispatched `reviewer-oracle-fleet-5-095506`. Level-triggered wins —
  no fix needed. (Also verified: review-reflex.sh line 96 `reviewable_again` covers
  CHANGES_REQUESTED+new-commits, since GitHub's dismiss-stale only clears APPROVALS.)
- **Meta-tooling lesson (mine)**: the watch probe fired "PR unchanged" because a gh error
  defaulted INTO the trigger (`${PUSHED:-1} -le 1`). Probes must fail loud, not fail into a
  condition. Reflex-design rule #6: any automated condition check distinguishes
  "true" / "false" / "probe failed" — the third is never an action trigger.
