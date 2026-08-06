# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)

## LIVE CHAIN — circles#29, the P0-complete goal (queued 2026-08-06 07:51Z)

**The one thing in flight.** Operator ask: queue it and watch for FU-143 + issue-authoring
problems. **Expected terminus: an assembly PR `goal/29-p0-complete` → master, ARMED, blocked by
the CODEOWNERS gate on `/specs/`, waiting for an OrgAdmin merge. If it stops anywhere short of
that, treat it as a platform/homelab bug, not a model failure.**

Pre-flight verified before labelling (each of these stalls a goal silently): goal branch ==
master (`d3de3c3`); `goal/**` ruleset live (`pull_request` + `required_status_checks`); `ci.yaml`
triggers on `goal/**`; CODEOWNERS `require_code_owner_review` is master-ONLY since the 2026-08-06
split, so children merge bot-approved; armed-PR count 0 (the TRACKS cap counts ARMED only — the 12
un-armed research PRs do not charge it); WIP 0; `Budget: €12` parses; no blockedBy.
`agent/queued` actor = `RasmusSoot` type **User** → the fail-closed decompose check passes.

**The work-vs-wait LEDGER is [`observability-and-retro.md`](observability-and-retro.md) §Part A″**
(operator direction 2026-08-06 — waiting burns meta context, so log it and ring what the platform
misses). Keep appending there, not here. Through child #30: **⏳ 8m35s vs ~68m ⚙**, and the only
wait was the very first hop. Two doorbell gaps filed: **FU-144** (a third dead edge — queueing an
issue rings nothing for a graduated stack; `devbox run coordinate-now` fires the GLOBAL reflex,
which skips graduated stacks — use `bash scripts/reflex-now.sh coordinate-circles circles-agents`)
and **FU-145** (`AgentCoordinateScanWedged` keys on scan-pod lifetime, so it fires on any ride
>15m on every stack — expect it as noise until re-keyed).

**Progress (09:02Z):** #36 (`fix/p0-bake-config-model` → the goal branch) is in **fix round r2**
after a CHANGES_REQUESTED. Proven live in this run, all first-time: a child PR **arms into a
`goal/**` base**; `ci` **triggers on `goal/**`** (1m42s pass); the reviewer reviews an armed goal
child; and the **`changes-requested` clause fires** — it had been dead since `671a053` (4 days),
revived this morning in `e66b421`.

⚠ **Observation, one instance, do NOT codify yet:** the #36 reviewer wrote *"I could not execute
`devbox run ci` … someone with a working devbox should confirm the 64 tests actually pass"* — while
`ci` had already passed. A reviewer blind to its own CI result may hedge or block on what the gate
already answers. Watch whether it recurs before treating it as a defect.

**Progress (08:37Z):** steps 1–2 DONE and good. Decompose ran on opus (18m03s), authored
**#30 → #31 → #32 → {#18, #19}** (all `Base:` inherited, narrowed `Touches:`, native sub-issues +
`blocked_by`), filed **#33/#34/#35** as named inert deferrals, put #29 in `agent/blocked` tracking
state, and posted a **91-id coverage map** — `CIR-BAKE-SELF-CONTAINED` owned by #32 with #19 as
cross-seam prover (the id that went unowned through four #17 reviews). Σ caps 5 × lg $2 = $10 ≤ $12.
#30's ride is running; the rest are correctly held on `Depends-on:`.

**Next expected events, with deadlines** (anti-stall: every wait has one):

3. #30's ride → PR into `goal/29-p0-complete`, **armed at creation** (launcher arms on the `goal/`
   prefix) → reviewer (only reviews ARMED PRs) → `ci` → merge. ⚠ First live proof that a child PR
   arms into a goal base and that the ruleset lets a bot approval satisfy it without a codeowner.
4. **FU-143's first live closeout** (the soak): C6 flips `agent/done`, CLOSES the child, harvests
   the review `Follow-ups:` — and goal-lane sprouts are QUEUED at harvest, not inert.
   ⚠ Check the C6 hazard above BEFORE the merge (sibling `#<n>` refs in PR bodies).
5. `goal-review` re-judges on every child closure; on "goal met" IT opens + arms the assembly PR.

⚠ **Hazard found reading C6, not yet observed — check before the first child merges.** The
goal-child leg requires *no OPEN PR referencing the child*, matched as a bare `#<n>` on every open
PR body (intent: "an open fix round means live work"). But #29's decomposition rules REQUIRE seams
pinned naming the producing/consuming sibling. If a worker carries that seam text into its **PR**
body, the sibling's closeout is starved until that PR merges — the exact three-way stall FU-143
removes. Deliberately NOT patched mid-soak (changing the code under test misattributes the
regression). Instead: once children have PRs, grep their bodies for sibling `#<n>` refs BEFORE the
first merge, and only then decide whether to narrow the probe to closing keywords.

### Frozen — from goal #17, do not touch (the comparison is the operator's)

- **circles FAN-OUT vs ONE-SHOT on goal #17.** The fan-out arm is merged on `goal/17-p0-mvp`
  (#22 bake + #23 page; the page ride cost $0.0571). The one-shot arm is **PR#21, FROZEN**
  (`major/awaiting-human`, `CHANGES_REQUESTED`, DIRTY) — do not push to it, dispatch a fix round
  on it, or merge it; a repair destroys the comparison.
- **PR#25 (`goal/17-p0-mvp` → master) is a DELIBERATE DRAFT** — the only thing holding the branch
  off master; un-drafting is an operator act. It is reviewer-**APPROVED** (19:01) and codeowner-
  judged (comment, not approval — meta authored it, so self-approval is blocked and worthless).
  ⚠ The bot's approval covers CODE only; the 13 spec files were judged separately in that comment.
- **circles #18/#19 are HELD** pending that comparison (operator ruling). They are still
  `task/build` though titled `Goal:` and authored in the same 66-second batch as #17 — decide the
  class when you unfreeze them. No silent-dispatch risk: neither carries `agent-fix`/`agent/queued`.
- ⚠ **A goal small enough for one ride is not a goal** (operator, 2026-08-05). #17 made two
  children while the one-shot arm reached a comparable result, so the fan-out's advantage was never
  demonstrated. #18+#19 under one parent is the shape that would actually test the lane.

### Unverified, and #29 is what verifies them

- **`goal-decompose` → opus** (`1b4bda5`, narrowed `5ad6c48`); `goal-review` stays sonnet — it was
  in the list for ~90 min and came out on evidence (both its live runs were sonnet and both were
  right; it contradicted standing doctrine — `reviewer-session.sh`: sonnet sufficient, opus a
  per-case `--model`). Axis is **AUTHORING vs CHECKING**, not goal vs routine. ⚠ All the evidence
  is from #17, a goal small enough for one ride — escalate a specific hard goal with `GOAL_MODEL`,
  don't move the floor.
- **homelab#103 is OPEN and this goal is its first real test** (the platform queue is swept
  first for exactly this reason). The coordinator Job templates carry no CPU requests/limits and no
  topology spread, so a burst piles onto one 4-core node; #29 funds up to six rides. Cluster was
  idle at bootstrap (wk-01 15%, only Watchdog firing). **A stalled ride is a scheduling question
  before it is a code one.**
- **homelab#103 containment** (`fc7e9fb`): alert `AgentCoordinateScanWedged` (>15m Running,
  measured 1-in-2474, verified `health=ok` live). Root cause still OPEN — the only live route is
  reproducing the Sensor spin against the burst hypothesis. ⚠ Do NOT "tighten"
  `activeDeadlineSeconds`: already 1800, and the legitimate tail reaches 1458s (p50 29s / p99 302s
  over 2474 runs), so 600s kills ~9 real scans/week. ⚠ Do NOT implement the issue's "reject
  `unit=-`" candidate — `-` is the legitimate full-scan default.

### Durable warnings — re-read before touching these files

- **⚠ FU-143: a child of a goal CANNOT close itself** (GitHub honours closing keywords only on a
  merge into the DEFAULT branch) — so the SCAN closes it, not GitHub and no longer meta by hand.
  Points 1–7 shipped 2026-08-06 (`e66b421` + circles `36993f4`); FU-143 is in SOAK, waiting on the
  first live closeout + doorbell ring on circles#29's first child. Until that is observed, check
  the child actually flipped `agent/done` and closed: if the clause regresses, C4/C5 re-dispatches
  onto merged work, `goal-review` never fires, and `Depends-on:` siblings never unblock.
- **⚠ Arming is keyed on the `goal/` PREFIX** (`agent-session.sh` + `review-reflex.sh` C9). NEVER
  widen to "any non-default base": the prefix is the only thing carrying the ruleset, and arming
  into an unprotected base merges ON OPEN.
- **⚠ An operator-lane PR has NO machine owner.** `changes-requested` is scoped to `WORKER_AUTHOR`,
  so a human-authored PR is skipped by design and the coordinator announces that to nobody.
  oracle-fleet#166 sat blocked three days on a real, twice-repeated, correct finding. Only a board
  sweep across EVERY active repo finds these — not just the stack in flight.
- **⚠ Two readers, one mirror.** `coordinator-scan.sh` reads the LIVE CLUSTER claim; the DOORBELLS
  (`coordinator-session.sh`, `agent-session.sh`) read `agents/stacks.json`. Sync the file on every
  claim change until the doorbells read the cluster too — that is the real repair, not done.
- **⚠ "Written is not applied" — four instances in one day; the tell was always the CALLER, not
  the config.** A label description >100 chars that never reached GitHub; a required check on a
  branch pattern no workflow triggered on; a `units` entry no gate could reach (`items`-only
  gating starved `goal-review`); a router class whose only caller is the worker launcher.
- **⚠ The jail's Bash tool runs ZSH, which does NOT word-split unquoted variables** (2026-08-06).
  The repo's own `K="devbox run -- kubectl --kubeconfig tofu/kubeconfig"` … `$K get pod` idiom is a
  BASH idiom: pasted into an ad-hoc Bash-tool probe it becomes ONE command word, fails, and behind
  `2>/dev/null` yields an empty capture that a `-z` test reads as "the object is gone". The scripts
  in `agents/` are safe only because they are invoked as `bash <script>`. Wrap ad-hoc probes in
  `bash -c '…'`, or call the binary directly. Caught on the first iteration because the probe said
  PROBE-FAIL instead of assuming absence — write them that way.
- **⚠ Shell/API traps that each cost real time:** `gh --jq` takes NO `--arg/--argjson`; an
  APOSTROPHE inside a jq program kills review-reflex FLEET-WIDE and `bash -n` cannot see it (EXECUTE
  the block); `gh pr view` has no `merged` field (use `state == "MERGED"`); GitHub caps label
  descriptions at 100 chars and `IssueLabels` is authoritative; a branch rename CLOSES the PR whose
  HEAD it is.

### Soak watches, not actions (each gates a later operator flip)

iac-sentinel shadow violations (→ G01 flip, FU-106); router shadow decisions (→ P4, FU-095); native
blockedBy edges in scan logs (→ FU-111 retirement); Monday 05:00 retro (= FU-058 run 3).
⚠ Garage still has no offsite backup (FU-137) and now carries tofu state.

### Open, not mine

agent-runtime #13 (watchdog misses silent loops), #31 (bank-on-first-commit), #32 (finalize should
guarantee the issue link), #33 (resumed round reports "no resumable branch"); openrouter-operator
sprouts triaged. (`follow-ups-lint` was RED on FU-143's line count — fixed `ce29c74`, the detail
lives in `issue-authoring.md`.)

## Re-arm on a fresh session

- Loop watch: `STACK_NS=circles-agents RIDE_NS=circles REPO=teststuffstash/circles
  SCAN_PREFIX=coordinate-circles- BASE_EXPECT=goal/29-p0-complete bash agents/meta-watch-loop.sh`
  (persistent) + `bash agents/meta-handoff-watch.sh` (persistent) + a 2h backstop heartbeat, each
  sweep running `agents/meta-alert-crosscheck.sh`.
  ⚠ `BASE_EXPECT` is the GOAL branch currently in flight — **update it when the goal changes**, or
  the drift clause alarms on every healthy ride of the new goal. The armed-PR clause is scoped to
  armed-AND-base-drifted, because arming into `goal/**` IS the happy path.
  ⚠ `major/awaiting-human` PRs are excluded from the drift set (`6b29a08`): circles#21, the frozen
  #17 benchmark arm, matched `^fix/` against every later `BASE_EXPECT` permanently, which would
  have delivered each real drift bundled with a member that is never actionable.
  ⚠ Monitors can SURVIVE a `/clear` — two orphans were still running mid-session. Stop them by task
  id before re-arming; a survivor runs the script as it was PARSED and never picks up your edits.
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; never a bare
  `devbox run -- kubectl` with no subcommand (prints help into the captured var); watch the FAILURE
  signature explicitly; stop orphan monitors from dead sessions on sight.
