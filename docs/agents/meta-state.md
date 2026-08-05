# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)

## Fresh-session pickup (2026-08-05, end of day — meta-coordination STOPPED by the operator)

**Session closed deliberately: all watches stopped, nothing mid-flight, no chain awaiting a next
step from meta.** Everything below is either an operator decision or a durable warning. The goal
lane ran end-to-end today (#17 → #22+#23 → both merged+closed → `goal-review` ruled goal met);
that history is in TICK-LOG 2026-08-05 cont. 2–5.

### The one live experiment — both arms exist, the comparison is YOURS

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

### Shipped today, NOT yet verified end-to-end

- **`goal-decompose` → opus** (`1b4bda5`, narrowed `5ad6c48`); `goal-review` stays sonnet — it was
  in the list for ~90 min and came out on evidence (both its live runs were sonnet and both were
  right; it contradicted standing doctrine — `reviewer-session.sh`: sonnet sufficient, opus a
  per-case `--model`). Axis is **AUTHORING vs CHECKING**, not goal vs routine. With #17 closed and
  #18/#19 held there is NO goal work pending, so the first proof is the next `goal-decompose`
  dispatch echoing `model opus`. ⚠ All the evidence is from #17 — re-test on a real
  multi-deliverable goal; escalate a specific hard one with `GOAL_MODEL`, don't move the floor.
- **homelab#103 containment** (`fc7e9fb`): alert `AgentCoordinateScanWedged` (>15m Running,
  measured 1-in-2474, verified `health=ok` live). Root cause still OPEN — the only live route is
  reproducing the Sensor spin against the burst hypothesis. ⚠ Do NOT "tighten"
  `activeDeadlineSeconds`: already 1800, and the legitimate tail reaches 1458s (p50 29s / p99 302s
  over 2474 runs), so 600s kills ~9 real scans/week. ⚠ Do NOT implement the issue's "reject
  `unit=-`" candidate — `-` is the legitimate full-scan default.

### Durable warnings — re-read before touching these files

- **⚠ FU-143: a child of a goal CANNOT close itself** (GitHub honours closing keywords only on a
  merge into the DEFAULT branch). Until it lands, meta closes each merged child BY HAND
  (`agent/done` + close) — done for #22 and #23. Skip it and C4/C5 re-dispatches onto merged work,
  `goal-review` never fires, and `Depends-on:` siblings never unblock.
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
sprouts triaged. **`devbox run follow-ups-lint` is RED on FU-143 (15 lines > 10)** — pre-existing,
needs its detail moved to a doc with a pointer left behind.

## Re-arm on a fresh session (watches were STOPPED at end of day, not lost)

- Loop watch: `STACK_NS=circles-agents RIDE_NS=circles REPO=teststuffstash/circles
  SCAN_PREFIX=coordinate-circles- BASE_EXPECT=goal/17-p0-mvp bash agents/meta-watch-loop.sh`
  (persistent) + `bash agents/meta-handoff-watch.sh` (persistent) + a 2h backstop heartbeat, each
  sweep running `agents/meta-alert-crosscheck.sh`.
  ⚠ `BASE_EXPECT` is the GOAL branch, not `research/issue-1-weave`. The armed-PR clause is scoped
  to armed-AND-base-drifted — arming into `goal/**` is the happy path, so the old clause would have
  alarmed on every healthy ride.
  ⚠ Monitors can SURVIVE a `/clear` — two orphans were still running mid-session. Stop them by task
  id before re-arming; a survivor runs the script as it was PARSED and never picks up your edits.
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; never a bare
  `devbox run -- kubectl` with no subcommand (prints help into the captured var); watch the FAILURE
  signature explicitly; stop orphan monitors from dead sessions on sight.
