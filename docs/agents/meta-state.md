# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)

## Fresh-session pickup (2026-08-05, end of the leg-(c) session)

- **circles is the live experiment: FAN-OUT vs ONE-SHOT on the same goal.** Goal #17
  (`task/goal`, `Budget: €5`, base `goal/17-p0-mvp`) decomposed into #22 (bake, DONE — PR#24 merged)
  and #23 (page, ride dispatched 17:07). The ONE-SHOT arm is **PR#21, FROZEN**
  (`major/awaiting-human`, `CHANGES_REQUESTED`, now DIRTY) — do not push to it, dispatch a fix round
  on it, or merge it; a repair destroys the comparison. **PR#25 = goal→master, DRAFT on purpose**
  (that is the only thing stopping the goal branch reaching master; GitHub will not merge a draft
  and cannot arm auto-merge on one).
- **The goal lane is BUILT and fully exercised** — `goal-decompose`, parent-carry, bounded goal
  card, Σ(child caps) ≤ `Budget:` (transitive over DESCENDANTS, not direct children), `goal-review`.
  Arming is keyed on the `goal/` PREFIX in `agent-session.sh` + `review-reflex.sh` C9. ⚠ NEVER widen
  that to "any non-default base": the prefix is the only thing carrying the ruleset, and arming into
  an unprotected base merges ON OPEN.
- **⚠ FU-143 is the live gap: a child CANNOT close itself** (GitHub honours closing keywords only on
  a merge into the DEFAULT branch). Until it lands, **meta closes a merged child by hand**
  (`agent/done` + close) or C4/C5 re-dispatches onto merged work, `goal-review` never fires, and
  `Depends-on:` siblings never unblock. Did it once for #22; #23 will need the same.
- **⚠ Two readers, one mirror.** `coordinator-scan.sh` builds its stack table from the LIVE CLUSTER
  claim; the DOORBELLS (`coordinator-session.sh`, `agent-session.sh`) read `agents/stacks.json`.
  They drifted six hours today (circles `graduated`) and a doorbell rang into the global trigger,
  which correctly ignored it. **Sync the file on every claim change** until the doorbells read the
  cluster too — that is the real repair, not done.
- **Traps that cost real time today — all mine, all worth re-reading before editing these files:**
  `gh --jq` takes NO `--arg/--argjson` (broke the budget gate AND, hours later, the goal-review
  predicate → it re-fired every tick and ate the sibling's WIP slot, presenting as a scheduling
  puzzle). An APOSTROPHE inside the C9 jq program closes its quote and kills review-reflex
  FLEET-WIDE — `bash -n` cannot see it; EXECUTE the block after editing. GitHub caps label
  descriptions at 100 chars and `IssueLabels` is authoritative (one over-long description froze the
  taxonomy for all 11 claim-owned repos). A branch rename CLOSES the PR whose HEAD it is.
- **Platform lane is LIVE**: homelab has `.agents/fix.yaml` + `review.md` (FU-142 archived); first
  self-fix #97 → PR#106 merged. Its recipe demands the ride NAME which lints ran and SAY when
  `manifest-lint` SKIPPED its kinds — that clause is what made the code-owner review possible.
  ⚠ homelab PRs target master so the recipe says `Fixes #N`; a `goal/**` child needs the opposite.
- **Soak watches, not actions** (each gates a later operator flip): iac-sentinel shadow violations
  (→ G01 flip, FU-106), router shadow decisions (→ P4, FU-095), native blockedBy edges in scan logs
  (→ FU-111 retirement), Monday 05:00 retro (= FU-058 run 3). ⚠ Garage still has no offsite backup
  (FU-137) and now carries tofu state.
- **✅ goal-review predicate fix VERIFIED (cadb3d1).** The 17:07 tick — the first to clone master
  after the 17:02:36 fix — dispatched only `issue-23 (queued-dispatch, child of goal #17)` and did
  NOT re-fire goal-review. The 17:00 re-fire was the last pre-fix tick, not a surviving bug.
- **⏳ oracle-fleet PR#166 (operator lane, MINE — author RasmusSoot, so no clause will ever touch
  it).** Sat `CHANGES_REQUESTED`+`BLOCKED` from 2026-08-02 to today because the coordinator
  correctly declines human-authored PRs and nothing else watches them. The finding was real and
  verified by hand: `.agents/research.yaml` shipped with no `extensions:` block while `build.yaml`
  and `fix.yaml` both had one, so the recipe could not run `devbox run ci` / `scan-secrets` / git /
  `gh` — every instruction it gives itself. Fixed in `3616fb2`; all three blocks now byte-identical.
  **Next: the review cron re-reviews → then it needs an operator merge.** ⚠ LESSON: an operator-lane
  PR has no machine owner at all — it is only ever found by a board sweep.
- **homelab#103 — containment shipped (fc7e9fb), root cause still OPEN.** New alert
  `AgentCoordinateScanWedged` (>15m Running; measured 1-in-2474, fires on the incident's own history
  and nothing else in 7d; verified `health=ok` in live Prometheus). ⚠ Do NOT "tighten"
  `activeDeadlineSeconds` — it is already 1800 and the legitimate duration tail reaches 1458s
  (p50 29s / p99 302s over 2474 runs), so 600s would kill ~9 real scans/week; my own 7-pod snapshot
  said 5s-168s and would have justified exactly that outage. ⚠ Do NOT implement the issue's
  "reject `unit=-`" candidate — `-` is the legitimate full-scan default, and every redelivered
  duplicate was well-formed. No upstream argo-events fix exists at v1.9.11; the only live route to a
  root cause is reproducing against the burst hypothesis.
- **Open, not mine:** agent-runtime #13 (watchdog misses silent loops), #31 (bank-on-first-commit,
  narrowed), #32 (finalize should guarantee the issue link), #33 (resumed round reports "no
  resumable branch"); openrouter-operator sprouts triaged; homelab#103 REOPENED (sensor spin
  recurs — a restart is palliative; hypothesis: onset correlates with workflow-submission bursts).

## Re-arm on a fresh session (watches die with `/clear`)

- Loop watch: `STACK_NS=circles-agents RIDE_NS=circles REPO=teststuffstash/circles
  SCAN_PREFIX=coordinate-circles- BASE_EXPECT=goal/17-p0-mvp bash agents/meta-watch-loop.sh`
  (⚠ `BASE_EXPECT` is the GOAL branch now, not `research/issue-1-weave` — children land there. The
  armed-PR clause was rescoped to armed-AND-base-drifted in the same pass: arming into `goal/**` is
  the happy path under the goal lane, so the old clause would have alarmed on every healthy ride.)
  ⚠ Monitors can SURVIVE a `/clear` — two orphans (a stale-BASE_EXPECT loop watch and a duplicate
  heartbeat) were still running this session. Stop them by task id before re-arming; a survivor runs
  the script as it was PARSED, so it never picks up your edits.
  (persistent) + `bash agents/meta-handoff-watch.sh` (persistent) + the 2h backstop heartbeat, each
  sweep running `agents/meta-alert-crosscheck.sh`. Re-arm fresh; don't trust old monitor ids.
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; never a bare
  `devbox run -- kubectl` with no subcommand (prints help into the captured var); watch the FAILURE
  signature explicitly; stop orphan monitors from dead sessions on sight.
