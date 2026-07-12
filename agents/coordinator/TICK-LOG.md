# Tick log — manual meta-coordination of the oracle stack

_Started 2026-07-09. Purpose: run the coordinator "by hand" (one tick per world-state change,
**single coordinator/worker active at a time**) and log every condition → command pair, so the
future coordinator reflex (the CronJob sibling of review-reflex) is specified from evidence, not
guesses. Kept in-repo because this file IS the reflex's requirements draft._

**Process-file push policy (finding G, decided 2026-07-09):** this log, `docs/follow-ups.md`, and
⚖ spec pins landed by the meta-coordinator during a live session are **gate-exempt** (direct push,
bypass) — they are the session's flight recorder and blocking them on PR flow would decouple the
record from the events. Everything else — recipes (`.agents/`), reflex scripts, launchers, platform
code — goes through the normal gates (CI + review where configured). The exemption is the FILE LIST
above, not the author.

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
| C9 | PR open ∧ auto-merge NOT armed | arm it (`gh pr merge --auto --squash`) — decision-free; unarmed PRs are invisible to the review reflex | agent-finalize (in-pod) + meta backstop |
| C10 | human direction reversal (`direction-change` label) | SWEEP before any dispatch: re-scope carrying issues, close invalidated PRs **with `--delete-branch`** (a stale same-named branch non-fast-forwards the next round), re-queue; scan excludes + reports carriers | human (scan reports) |

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

### 2026-07-09 10:1x — round-2 review: CHANGES_REQUESTED again; review depth ESCALATED
- **The reviewer ran the engine against the PR's fixture corpus** (evidence-based review emerged
  unprompted): caught multi-lõige § with omitted loige returning PARTIAL text under a complete
  citation — a CITE-invariant breach no static read would find. Second blocker: TOC still
  lexicographic (inconsistent with the PR's own numeric fix). Four non-blockers incl. a
  case-sensitivity mismatch between the unique index and the lookup (future-ingest hazard).
- **Root cause both blockers: spec gaps again** — omitted-loige semantics never defined (every
  canonical call passes loige); ordering pinned for points but not TOC/sup-numbers. Pinned
  spec-first (whole-§ concatenation ⚖; glossary "display-number order" 2 < 2¹ < 3 < 10).
- **Suspected reviewer error, logged for tie-break**: its last non-blocker claims the spec's
  end-date rule is "boundary-inclusive" — the glossary says EXCLUSIVE. If round 3 flip-flops on
  this, the coordinator arbitrates FROM THE GLOSSARY, not the review.
- **Round accounting**: coordinator count r2 of 3 → round 3 is the last before blocked→human.
- **Pattern now twice-proven**: worker ships → reviewer finds → spec was ambiguous → pin spec →
  next round implements rules. The spec is being GROWN by the loop, through the human gate,
  exactly as designed (specs rule 5 / principle 5).

### 2026-07-09 10:16 — tick 4: round 3 (=max) dispatched
- Coordinator correctly read the spec-first master move as the BEHIND cause, cited spec lines in
  the fixer directive, minted `issue-1-round-3`, dispatched `agent-oracle-fleet-101337`, and
  pre-announced the round-bound consequence. Nothing to correct.

### 2026-07-09 10:26 — round 3 died (triple failure) → agent/blocked (round bound) → HUMAN
- **r3 = zero artifact, $0.036**: (a) SAME truncation as r1 (14781 vs 15267 chars — model's ~15k
  tool-output ceiling) DESPITE the post-r1 recipe rule → **instruction guardrails don't bind this
  model on file-recreation**; (b) 401 "User not found" auth STORM (dozens of fatal retries — FU-021
  class, scoped to budget-403, must extend to auth-401); (c) died on the throwaway `agent/<ts>`
  branch before checking out the PR branch → even success wouldn't have touched PR #5.
- **Round budget spent on infra, not the task.** r2 succeeded; the task is small + fully spec'd.
  Blocking reason is precise: systematic harness/model limitation, NOT task/reviewer.
- **Terminal action**: `agent/blocked` + diagnostic issue comment; did NOT re-dispatch (round 4
  into the same wall = negative-EV — the bound working as designed). Handed to Rasmus.

### 2026-07-09 ~17:00 — meta-session 2 begins (unattended, Rasmus-authorized; budget cap $8.52 OpenRouter)
- **World reset after the language reversal** (oracle-fleet 0662af7, Python/uv): PR #5 (TS scaffold,
  CHANGES_REQUESTED, armed) would have been picked up by the scan's CHANGES_REQUESTED clause and
  burned a round fixing code the repo now forbids — the stale-task-state trap after a human
  direction change. **Meta actions**: closed PR #5 (spec pins it produced are already on master);
  re-scoped issue #1 to Python/uv (body rewritten, seed-format contract + FTS5 pre-flight guard
  added); `agent/blocked` → `agent/queued`; **round counter reset to 1** (task materially changed);
  TRACKS.md chassis lane shared-files updated to pyproject/uv.lock.
- **Platform deltas in effect this session**: FU-021 watchdog live-accepted (in the pinned
  agent-base); strike bookkeeping (PR-less deaths → AGENT_STRIKE issue comments); model chain
  tencent/hy3:free → hy3 → deepseek-v4-flash (infra deaths burn no round); egress-proxy provider
  pin; review-reflex + tokens stack-derived (gaps #4/#5 fixed).
- **Reflex-spec note (new condition class)**: a human direction change (language/architecture
  reversal) invalidates open agent PRs + queued issue scopes — the reflex table needs a C10
  "human-invalidation sweep" (close/re-scope before the next C1), or the scan will happily
  dispatch against stale scope. This session's manual sweep is the specification of it.

### 2026-07-09 16:37 — meta-2 tick 1 (C1) — textbook, two platform checks passed live
- Coordinator claimed #1, estimated (xs, $0.25 cap, est $0 — free model), minted, dispatched
  `agent-oracle-fleet-164034` on `tencent/hy3:free`. **FU-060 remaining check ✓** (token resolved
  both oracle clones); **FU-061 ✓ live** (tick transcript keyed `oracle-fleet/_ticks/…` — the
  stack-vs-project split is gone).
- **Mid-run meta-fix**: deleted stale remote branch `fix/issue-1-chassis-scaffold` (closed PR #5's
  head) — a same-named push from any future round would die non-fast-forward. **C10 sweep item:
  closing a PR deletes its head branch.**

### 2026-07-09 18:10 — round 1 terminal: work SUCCEEDED, platform lost it (token-expiry, new class)
- **The task side was flawless**: full Python chassis, 32 spec-row tests (incl. every ⚖ pin),
  `devbox run ci` GREEN in-pod, scan-secrets clean, incremental writes held, and the model
  **refused to storm the 401** citing the issue history — the recipe lesson bound this time.
- **The infra side lost the artifact**: 2917s on the free model outlived the **60-min GitHub App
  token TTL** → push + PR both 401'd → green code stranded in the dead pod. New error class
  **`token-expiry`** (not auth-storm — no storm happened; the watchdog correctly stayed quiet).
- **Three platform gaps confirmed/found:**
  1. **Strike/stats bookkeeping is still dispatcher-lifetime-coupled on the coordinator path**
     (FU-043 class): the coordinator pod exits ~1 min after dispatch, so the launcher's
     PR-less-death AGENT_STRIKE never posted. Meta posted it by hand. The e45f575 fix covered slow
     pod STARTS, not the dispatcher exiting before worker END. Ownership must move in-pod
     (agent-finalize already runs there and posted stats to the LOG + pushgateway — it just
     doesn't own the GitHub comment) or to a reflex.
  2. **Classifier gap**: agent-finalize scored this run `exit_status=clean, error_class=""` —
     ci_passed=true + no pr_url must NOT be clean (proposal: `no-artifact` or `token-expiry`;
     the model-health dashboard reads this field — a "clean" that shipped nothing poisons it).
  3. **Push-early STILL doesn't bind** (2nd model it fails on): first push attempted only at the
     end. An early push at scaffold time (~30 min in) was inside the token window and would have
     left a resumable branch. Recipe wording alone is insufficient across models — candidates: a
     deterministic post-scaffold push hook in the harness, or the reviewer/finalize flagging
     "no push before minute N" as an error class.
- **Chain semantics honored**: no round consumed; strike walks dispatch to `tencent/hy3` (paid,
  fast enough to finish inside the TTL). Token-TTL root fix belongs to FU-018's cred-injection leg
  (mid-run token refresh at the egress proxy) — noted there.
- **Meta policy update (Rasmus)**: when the loop is proven this session and tempo is slow, run a
  SECOND track-scoped coordinator in parallel (TRACKS.md seed line). Sequencing decision: the
  parallel point is AFTER #1 merges — #2/#3 both hard-depend on #1's pyproject/package layout
  (shared file, chassis lane); queueing them earlier would force a lane trespass. #2's body swept
  for Python-era accuracy (TS reference marked approach-only; entry-point + shared-file rule made
  explicit; seed-format contract path added).

### 2026-07-09 18:19 — tick 2 (C4 via strike): clean chain walk; then attempt 2 died at 18:40 — OPERATOR BUG
- Tick 2 was textbook: read the strike, walked to paid `tencent/hy3`, re-minted, dispatched
  `agent-oracle-fleet-181942` (est $0.30/cap $0.50). Worker ran healthily ~20 min, then a 401
  "User not found" storm — **caught properly this time**: turn-bound stopped the loop,
  agent-finalize classified `auth-storm/http-401-storm`, metrics pushed. FU-021 machinery ✓.
- **Root cause (diagnosed from the OpenRouter API, to the second): key re-mint PATCH does not
  extend `expires_at`.** The reused CR `…issue-1-round-1` was PATCHed at 18:19 (spec expiry
  20:19:22Z) but the live key kept its creation-time deadline 16:40+2h = **18:40:08Z** — the
  worker died at the key's real expiry exactly. Model innocent; strike record corrected on the
  issue (hy3 stays active; only hy3:free stays struck). **Load-bearing interaction: strike
  semantics reuse the round → same CR name → always the PATCH path → every infra-death
  re-dispatch inherits a near-dead key.** Filed **openrouter-operator#6** (rotate-on-expiry-drift
  + surface `expires_at` in status for a dispatch-time pre-flight). Workaround: meta deletes the
  stale CR pre-redispatch (forces the POST path).
- **Bookkeeping gap re-confirmed** (2nd time this session): no AGENT_STRIKE posted for the
  attempt-2 death either — dispatcher-lifetime coupling. Meta posted the corrected record.
- Round still 1/3; two attempts, two DIFFERENT infra walls (git-token TTL 60m; session-key TTL
  2h-from-first-mint), zero model/task failures. The chassis task itself is proven implementable
  (attempt 1's in-pod green).

### 2026-07-09 19:02–20:11 — attempt 3 (tick 3, fresh key): died on wall #3 — budget-403
- Tick 3 itself was the best coordinator pass yet: it read the postmortem, **deliberately dodged
  the PATCH bug** (verified the CR was *created* not *configured* → POST path, real 2h window),
  cleaned up expired TS-era CRs, and dispatched `agent-oracle-fleet-190248` on paid `tencent/hy3`.
- Worker ran healthy, real work (FTS query refinement observed live) — then died at 3918s:
  **`403 Key limit exceeded`, real spend $0.5086 vs the $0.50 cap** (estimator: $0.30/sm-tier).
  Turn-bound + classifier ✓ (`auth-storm/http-403-storm`); **cost recorded correctly** (key
  alive-but-limited → the /key read still works; corroborates agent-runtime#12 being specifically
  about DEAD keys). No push (push-early unbound, 3rd time), zero artifact.
- **Meta verdict: hy3 struck on PACE, not just budget** — at ~75+ min/task its push lands past
  the 60-min git-token wall even with a raised cap. Both hy3 tiers are structurally PR-incapable
  here until mid-run cred refresh (FU-018/FU-064). Chain walks to `deepseek-v4-flash` (405s-class
  fast, fits every window; truncation risk = the recurrence experiment, recipe hardening now in).
- **Session pattern named: three attempts, three DIFFERENT TTL/limit walls** (git-token 60m;
  key-expiry PATCH bug; key budget cap) — every platform assumption is tuned to ≤30–60-min runs
  while real scaffold-sized runs on cheap models are 50–75 min. The class, not the instances, is
  the finding: **slow-cheap models break every freshness assumption at once.** Fixes split:
  FU-064 (deterministic: harness-owned terminal push + git-token volume-mount), FU-018 (proxy
  cred injection = endgame), FU-019 (persistent per-task workspace = salvage/warm-resume cache,
  doctrine-compatible per ADR-078 "snapshot=cache"). In-sandbox test clusters: Rasmus pushed back
  on "unit-scale Gate A suffices" — operator-shaped repos (openrouter-operator: helm install +
  kyverno chainsaw) need a cluster in the WORKER's inner loop; the CI-push cycle is too slow for
  that workflow. Tier ladder — DECIDED 2026-07-09 (Rasmus): rungs 1+2 (FU-065); claude+haiku worker = subscription-only, FU-018 hard prereq (FU-066). Ladder: envtest+chainsaw (unprivileged, in-pod, likely
  sufficient for API-level operators) → vcluster (unprivileged, workloads really run via the host
  syncer, needs sandbox-ns quotas/NetPol) → remote docker / DinD-on-tainted-node for true kind
  (kind-in-rootless-podman inside an unprivileged pod is not viable today: nested systemd/kubelet
  + cgroup delegation + /dev/fuse). Test-cluster tier = a future AgentStack policy field (ADR-085).
- Meta also: negative-cost dashboard row root-caused (agent-finalize fail-into-0.0 usage probe,
  rule #6 in the money pipeline) → **agent-runtime#12**; `hy3:free×sleep-tracking $0` row
  confirmed by Rasmus as the FU-021 acceptance trace (not a bug).

### 2026-07-09 20:27 — attempt 4 (deepseek, tick 4): truncation recurred at 250s — then ROOT-CAUSED
- Worker `agent-oracle-fleet-202238` died `-32602 EOF while parsing` on a giant tool call, exactly
  the r1-old class. Classifier ✓ (`harness-death/goose-32602-truncation`), $0.033. Chain fully
  struck at that moment (hy3:free/hy3/deepseek). Hardened recipe did NOT bind (2nd model).
- **Root cause found in the numbers**: all three truncation deaths cut at 14781/15267/16322 chars
  ≈ **~4k tokens** — a `max_tokens=4096` default in the goose→OpenRouter path, NOT model
  indiscipline. Any single file-write above ~4k tokens is structurally fatal, and no recipe
  wording can fix a config ceiling. (Old finding A "instruction guardrails don't bind" gets a
  kinder reading: they *couldn't*.)
- **Deterministic fix shipped (C8): egress-proxy `max_tokens` floor** (`fa05517`) — the ADR-081
  proxy now raises missing/low `max_tokens` to 16384 (env `MAX_TOKENS_FLOOR`), clamped to the
  pinned endpoint's `max_completion_tokens`; explicit higher values win; provider-pin and floor
  are independent legs. Verified the dying request DID transit the proxy (`injected:deepseek`
  20:27) — so the floor will bind future worker traffic. deepseek strike to be annulled for a
  re-test once the rolled pod is verified (same annul-on-root-cause precedent as hy3/attempt-2).
- Ops note: the ArgoCD webhook did not fire for the `openrouter-proxy` app (synced rev lagged
  HEAD); refresh-annotation nudge required — check webhook coverage for platform child apps.

### 2026-07-09 ~21:00–22:00 — meta-session 3: the clean-slate build night (Rasmus-authorized, direct-push)
Experiment stopped on operator decision; every P0 root cause from meta-2 got its mechanism fix:
- **agent-runtime 09cd3e0** (pinned live as agent-base `2026.7.9-g09cd3e0d6542` via deploy-pin #18):
  salvage-push at terminal (FU-064a), in-pod bookkeeping (arm + stats + strike with `*_by_pod`
  flags, FU-043 decoupling), honest classification (`no-artifact`/`token-expiry`; `key limit
  exceeded` → budget-403), cost truth (#12: None-on-failure, `cost_unknown`, no zero-push),
  live-token credential helper + gh wrapper (GIT_TOKEN_FILE), deterministic WORK_BRANCH resume.
- **homelab af8e2e1/98d42f3**: launcher pre-flight (FU-042 open-PR + WIP=1 + key-life refusals),
  git-token volume mount, `--work-branch`, launcher demoted to bookkeeping FALLBACK, oracle chain
  paid-first, registration lint in CI, coordinator-reflex CronJob (SUSPENDED — unsuspend = the
  autonomy switch), scan v2 (C4/C5 predicate — flagged #1's real stall on first run), C10 clauses
  (`direction-change` label on all six repos + tofu; stale-branch backstop).
- **openrouter-operator af04086** (fixes #6): expiry drift → Rotate (mint→swap→delete; 120s
  tolerance for OpenRouter's storage rounding; drift outranks cap drift), live `expires_at` in
  status + LiveExpires column. 23 decision-table rows green, 100% coverage.
- **oracle-fleet ae87906**: execute-the-engine promoted to review rubric row 7 (finding D).
- **homelab sync.yaml**: in-cluster ArgoCD webhook nudge for homelab-sourced apps (the >4-min
  proxy-hotfix sync lag, measured live) — same ADR-084 pattern as sleep-iac.
- **Meta-lesson (rule #6 on myself)**: a `git push | grep` pipe swallowed a credential failure and
  I reported the operator push as landed when remote never moved — probes must surface exit codes,
  not filtered stdout. Re-landed verified (cherry-pick onto fresh master; stale local branch was
  also silently checked out — jail clones need a state check before committing).
Pending: acceptance round on #1 (deepseek through the max_tokens-floored proxy + all the above);
operator chart bump auto-merge; FU-064/FU-042/FU-050 items updated in follow-ups.

### 2026-07-10 ~21:40–04:00 — meta-3 acceptance: three clean rounds, one new deadlock found+fixed, blocked at bound
**The P0 machinery passed acceptance across three full rounds on oracle-fleet#1 / PR #6:**
- **Truncation class DEAD**: every completion `injected:deepseek+max_tokens:16384`; deepseek
  finished the twice-fatal scaffold in 534s, then two fix rounds at 364s/330s. $0.06/round.
- **In-pod bookkeeping perfect 3/3**: armed_by_pod + stats_comment_by_pod on every round; zero
  manual meta bookkeeping the entire night (vs 3 hand-posted strikes in meta-2).
- **Deterministic resume proven**: rounds 2+3 landed on the PR branch via --work-branch; the
  round-2 coordinator FOUND a pre-flight gap (resume refused unconditionally), safely bypassed
  with justification, flagged it → fixed (f86079c) → round-3 coordinator confirmed clean pass.
- **Reviewer depth escalating by round** (execute-the-engine rubric row 7 binding): r1 ran the
  engine on the fixture corpus (2 bugs + gitignore regression); r2 CONSTRUCTED new edge-case
  seeds (points-only lõige family); r3 caught the r-3 fix applied point-wise not family-wise +
  the alampunkt-ambiguity spec pin left unimplemented. Three rounds, three DISJOINT genuine bug
  sets — not flip-flop; the bound fired correctly → `agent/blocked`, human decides (grant round 4
  with the precise 2-bug list, or wait for the FU-066 claude+haiku tier).
- **NEW DEADLOCK found + fixed (FU-041 hole)**: the adRise updater refuses PRs with
  changesRequestedReviews>0; the reflex refused BEHIND PRs → CHANGES_REQUESTED + fix pushed +
  master moved (routine here: spec pins move master mid-review) wedged the whole serializer.
  Fix (d381a3a): BEHIND re-review exception in review-reflex.sh — re-approval clears the
  updater's gate. Proven live: re-reviews at 01:04 and 02:20 ran on BEHIND heads.
- **Merge-path onboarding gap**: oracle-fleet had NO update-pr-branch/renovate-approve callers
  (the FU-052 layer-1 checklist skipped) — added (ae87906 side); the registration-lint class
  should grow a workflow-callers check (FU-048's claim renders these eventually).
- **Meta-lesson ×2 (rule #6, my own shell)**: `git push | grep`/`grep -c "master -> master"`
  both read REJECTED pushes as success — two fixes sat stranded local while I watched them
  "not work" in-cluster. Push verification = compare `git ls-remote` to local HEAD, never parse
  filtered push output. (Also: a jail clone may sit on a stale non-master branch — check before
  committing; the operator fix initially landed on a dead merged branch.)
- **Session spend**: ~$0.83 total across all attempts/rounds today; $7.69 of the $8.52 remains.

### 2026-07-10 morning — meta-4: THE HIGHER-LEVEL PROCESS FIX (operator directive)
Rasmus, reviewing the #1 round-bound block: **the process is broken above the mechanics** — the
review loop has depth but no merge JUDGMENT. A human author answers a nitting reviewer with
"better than master, merge now, nits to the backlog"; our loop had no such move, so a scaffold
that beat empty master burned 3 rounds and blocked on residual edge semantics — in a repo with
zero prod consumers, where no "good enough" judgment even applies. The coordinator never
exercised its tie-breaker mandate; the reviewer verdict was binary; scaffold tasks weren't scoped
for what scaffold quality means (structure/libraries/seams, NOT edge completeness).
**Encoded as mechanism (the "hard to put in markdown" attempt):**
- Reviewer doctrine (reviewer-session.sh): verdict question = "is master better off WITH this
  PR"; findings classify BLOCKING (secrets/blobs/CI-red/breaks-master/prod-invariants) vs
  FOLLOW-UP (approve + `Follow-ups:` section, each bullet issue-ready; spec ambiguities = ⚖
  proposals, never blockers). Pre-prod repos bias hard to approve-with-follow-ups.
- Repo maturity knob (.agents/review.md, oracle-fleet 93ccb50): PRE-PROD merge-forward declared;
  flips to invariant-blocking when the stack first serves consumers — operator-edited only.
- Coordinator tie-breaker play (brief step 7): on CHANGES_REQUESTED, ARBITRATE before relaying —
  follow-up-class findings → file as backlog issues + re-dispatch reviewer with the arbitration
  note; agent/blocked is reserved for "master would be worse off", never for imperfect progress.
- Scaffold scoping note in the brief; scaffold quality bar in the rubric.
- Economic argument recorded: N follow-up issues × 3 rounds each converges faster + cheaper than
  one PR × unbounded rounds — measured on PR #6 (3 rounds, 3 disjoint bug sets, no convergence).
**Live application to #1/PR #6**: filing the two residual findings as backlog issues, un-blocking,
updating the PR branch, re-dispatching the reviewer under the new policy → expect merge.

### 2026-07-10 day — meta-5: the solo P2 run (FU-018 shipped + accepted; new classes harvested)
- **FU-018/ADR-087 BUILT + ACCEPTED under fire**: opaque-ref LLM creds (`+cred` on every
  completion), broker git tokens (`/git-token`, label-checked, per-ns RBAC — split across the
  proxy app + coordinator app because kustomize's namespace transformer can't host cross-ns
  RBAC), launcher `AGENT_CRED_INJECT=1`, broker-aware entrypoint (mock-tested fallback chain),
  `or_usage` via proxy. Acceptance on oracle-fleet#7: salvage-push fired IN ANGER through broker
  creds (FU-064a's first live rescue), in-pod strike with resumable branch, honest $0.078 cost,
  and the resume round (--work-branch) opened PR #12 end-to-end with no credential in the pod.
- **New failure class: degenerate REPETITION loop** (deepseek repeating one sentence to the
  max_tokens ceiling, 500KB completions, goose grinding minutes/turn). Root cause was a RECIPE
  TRAP: RED-first ceremony applied retroactively ("revert the fix, commit RED, re-apply" ×∞) —
  fixed in fix.yaml (evidence over ceremony, never revert working code); detector filed as
  agent-runtime#13 (watchdog shape); proxy hard-deadline + in-flight gauge filed as homelab#22.
  NB the max_tokens floor gives this class 4× the old rope — the two mitigations trade off.
- **FU-024 ENFORCED**: operator writes GUARDRAIL into session Secrets; the proxy 403s paid-model
  completions on only-free sessions BEFORE spend (unit-verified 3 shapes). Guardrailed keys are
  issued injected by design — the scout canary path unblocks.
- **FU-057 polish**: AgentRunNegativeCost + AgentRunInfraDeathBurst PrometheusRules;
  KEY_HASH now durable (operator→Secret→launcher env→finalize stats) for ledger backfill.
- **Meta-lesson ×2 MORE (pipe-masking)**: `devbox run ci | tail` swallowed a red CI (pushed a
  red operator master for ~3 min — ruff format only); the registration lint's gh probes 404'd
  into false MISSINGs blocking a deploy-pin. FIVE instances of fail-into-a-value in 36h across
  three layers. PROMOTED TO PLATFORM PRINCIPLE: every probe is true/false/PROBE-FAILED, and
  probe-failed triggers nothing (in either direction); exit codes are read from $?, never
  through pipes; pushes verify via ls-remote-vs-HEAD.
- Updater gate finding: require_passed_checks was the SECOND wedge flavor of the same gate
  (a base-side CI fix can only reach a PR through an update) — dropped in the reusable workflow;
  named rule: **every updater precondition beyond armed+behind is a potential wedge.**

## Systematic findings for the reflex/platform (harvested from this issue's 4 ticks + 3 rounds)
Reflex gaps (stale-registration class, all fixed): #1 PR-less death invisible in GitHub; #2 pod
cleanup before next-read; #3 C9 arm-at-PR-open; #4 review-reflex repo list; #5 reviewer token
scope; #6 probe must fail-loud not fail-into-trigger.
Platform/recipe findings (need decisions): (A) model truncation on file-recreation — recipe rule
insufficient, needs model/harness change; (B) retry hard-stop on 401/403; (C) deterministic PR-
branch checkout (not LLM-dependent); (D) reviewer methodology "execute the engine" worth promoting
into review.md; (E) autonomy-as-dial (Turnstone) for P3; (F) bucket prefix stack-vs-project;
(G) direct-push-bypass on this log — DECIDED 2026-07-09 (meta-3): gate-exempt, see the
policy block in the header.

### 2026-07-12 — meta-6: FU-048 AgentStack XRD built; oracle is the first claim (solo meta-session)
- **FU-048 BUILT + ACCEPTED**: cluster-scoped `AgentStack` XRD + go-templating Composition
  (Crossplane 2.3.2, function pipeline). One claim per stack renders the fixer MECHANISM per repo:
  git-token trio, standing OpenRouterKey, worker egress CNP, proxy session-key RBAC. The FU-020
  rollout strategy is ENCODED AS API: CNP = baseline + ecosystem profile + extraFQDNs with an
  `egress.enforce` dial — false attaches the allowlist with `enableDefaultDeny.egress:false`
  (monitor: DNS visibility, nothing blocked; harvest→diff→flip). New stacks onboard in monitor;
  oracle carried over enforce=true (already live under deny-all). hubble.relay still off — the
  harvest prereq, enable when the second stack onboards.
- **Dual-surface documentation convention** (the FU-049 seed): the XRD schema IS the reference
  (`kubectl explain agentstacks.spec --recursive`); the quickstart is an in-cluster ConfigMap
  found FROM the XRD (`platform.teststuff.net/docs-configmap` annotation; ConfigMaps labeled
  `platform.teststuff.net/docs=true` enumerate every capability doc). A kubectl-only agent gets
  from `kubectl get xrd` to a working claim without leaving the API. Human/design doc:
  docs/agents/agentstack.md.
- **Platform gotcha worth keeping**: crossplane core's SA holds NO RBAC for arbitrary composed
  kinds — first render 403'd on ciliumnetworkpolicies. Fix = aggregated ClusterRole
  (`rbac.crossplane.io/aggregate-to-crossplane`, argocd/resources/agentstack/rbac.yaml); extend
  it whenever a Composition grows a new kind.
- **Probe instances SIX and SEVEN in 4 days**: (6) coordinator-scan's stale-branch check —
  `$(gh api … || echo '[]')` concatenates the 404 BODY with the fallback (gh prints error bodies
  to stdout) → --argjson crash killed the whole scan; surfaced by the render-test claim's fake
  repos; fixed = fallback OUTSIDE the substitution + jq-validate both probe values. (7) my own
  acceptance poll: zsh does NOT word-split `$KC` → 30 polls read a DEPLOYED XRD as "absent"
  (the 2>/dev/null ate the real error). The rule compounds: any JSON crossing a boundary gets
  jq-validated; any poll loop needs one positive-control iteration before trusting "absent".
- **Migration state**: oracle policy lives in oracle-iac (claim; hand files deleted same-commit —
  crossplane won't adopt, so prune-then-compose, one transient round; OpenRouterKey re-minted as
  expected). sleep/platform still stacks.json + fixer dirs; oracle's stacks.json entry stays as
  the probe-failed BELT until the in-cluster reflex is verified reading claims (RBAC granted).
  Scan merge: cluster claims WIN per stack name.

### 2026-07-12 — meta-6 (cont.): FU-048 completed — all stacks on claims; FU-020 rollout ring live
- **sleep + platform migrated** (sleep-iac claim / fixer-dir claim): both gained worker egress
  CNPs in MONITOR (`enforce: false` — their first netpols ever, ring 1 of the rollout). Gapless
  proxy-RBAC handoffs; the openrouter-proxy-rbac.yaml hand-list is GONE (composed per-claim now).
- **FU-020 alert chain live WITH a positive control**: hubble.relay + drop:sourceContext=namespace
  (tofu targeted apply + cilium ds rolled — helm alone does NOT restart agents; the ConfigMap was
  updated but June-vintage pods still exported old labels until the roll). Then a deliberate
  forbidden egress from an `app=agent-session`-labeled pod in oracle-fleet: curl HUNG (the
  predicted failure shape), the DROPPED flows were visible cluster-wide via relay, and
  `hubble_drop_total{source="oracle-fleet",reason="POLICY_DENIED"}=16` landed in Prometheus —
  the exact expr AgentWorkerEgressDropped matches. Extend the alert's ns regex on onboarding.
- **In-cluster reflex path VERIFIED, zero LLM spend**: a one-off report-only Job (same SA/image/
  clone as coordinator-reflex, no --spawn) listed all three stacks FROM claims, no fallback warn.
- **stacks.json NOT deleted — redefined as the committed MIRROR of the claims.** Discovered
  dependency: the registration lint's repo universe is stacks.json and CI has no cluster access —
  ADR-085's build-time-discovery question, answered: keep a committed mirror (cluster claims win
  at runtime; the lint doubles as the mirror's freshness incentive; generating it FROM claims is
  FU-049's catalog problem).
- **Decisions recorded** (agentstack.md §Decisions): ONE global coordinator-reflex (per-stack
  CronJobs only if cadence/isolation diverges — a Composition addition, not a redesign);
  GitHub-side + `.agents/` recipes stay OUTSIDE the claim (in-cluster GitHub-admin credentials
  deserve their own ADR; recipes are repo content, versioned with the code they steer).

### 2026-07-12 — meta-6 (cont. 2): the #8 stall broken by one supervised gate firing; FU-020 ride validated
- **The stall the operator flagged**: PR #13 CHANGES_REQUESTED for 2 days — round-2 dispatch is
  the coordinator's move and the reflex is SUSPENDED. Resolution: ONE manual
  `coordinator-scan --spawn` (the designed middle path — no autonomy flip). The tick arbitrated
  per meta-4 (blocking = the unflagged specs/ edit, by repo rule 2; three findings scoped out as
  follow-ups), minted round-2 key ($0.25 cap), dispatched on the PR branch.
- **FU-020 VALIDATION RIDE — CLEAN**: round 2 under enforced deny-all + broker creds +
  claim-composed infra: 441s, $0.0347, ci green, exit clean, key_hash in stats, armed_by_pod.
  Review-reflex re-dispatched the reviewer automatically → APPROVED 15:16Z.
- **PR #13's terminal state is a HUMAN GATE, not a stall**: it touches specs/, and CODEOWNERS
  (/specs/ @RasmusSoot) + require_code_owner_review route the spec diff to the operator BY
  DESIGN. Auto-merge armed; merges on his approval. (Round 1's blocking finding was exactly
  this diff unflagged — the loop worked end-to-end.)
- **Unclassified: ~150 POLICY_DENIED drops from oracle-fleet DURING the clean ride** — something
  non-essential retried against the allowlist the whole run (candidates: goose telemetry, a
  direct openrouter.ai attempt — the latter is the policy doing its job). The flow ring buffer
  rotated before I queried it: **the harvest must run LIVE (`hubble observe --follow`) during a
  ride** — binding lesson for the monitor-stack harvests.
- **FU-050 unsuspend precondition MET**: this was the clean supervised acceptance round. The
  switch stays the operator's.
- **Probe instance EIGHT**: my PR-poll wrapped gh's --jq in the wrong quoting layer → 11 polls
  of PROBE-FAILED (labeled correctly at least — the loop design held, the probe itself was bad).
- **New dashboard: "Agents — issue drill-down"** (uid agent-issue, pushgateway app): per
  project/issue rounds table (cost/duration/exit_status/model), cost-per-round, POLICY_DENIED
  stat, project-scoped OTLP control-plane cost/tokens, Loki worker logs; links to the
  transcripts viewer (the trace substitute until Tempo + CC traces GA).
