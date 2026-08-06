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

### ✅ RESTORED — circles#31 un-parked 10:43Z, lane running again

Latch released 10:43:03Z (probed, not assumed: `limited=false`; ⚠ the 5h utilization HEADER still
read 0.82 with `headers_age_s=3441` — the **reset epoch** is what releases, never the number).
`agent/queued` re-added → stack doorbell rung → scan dispatched
`issue-31 (queued-dispatch, class build, child of goal #29, sonnet, wip 1)`.
Ledger rows + the CAPACITY-vs-WAIT class distinction are in
[`observability-and-retro.md`](observability-and-retro.md) §Part A″.

✅ **#31 IS DONE and the whole goal-lane cycle is now PROVEN end to end** (11:22Z): ride → PR#37
into `goal/29-p0-complete` → **C9 re-armed it** (it arrived un-armed, unlike #36 which armed at
creation — worth watching whether that recurs) → reviewer APPROVED with `ci` green → auto-merged 2s
later → hand-closed with `agent/done` (verified against the goal branch HEAD `1cc6b76`, not the PR
page) → **`goal-review` fired** → **#32's `blockedBy` cleared and #32 is riding**.

Harvest done by hand (the hand-close suppresses C6's): PR#37's one `Follow-ups:` bullet → **#38**,
filed **INERT** rather than queued — test hygiene outside #29's P0 scope, and a sixth lg child
would eat the `Budget: €12` headroom (Σ caps already 5 × lg $2 = $10). Judgment call, stated in the
issue; flip the labels to disagree.

Why: a deferred item session still rang `/coordinate`, waking a scan that re-dispatched the same
issue, which deferred again — three laps in eight minutes, and coordinator sessions are themselves
`subscription-session: claude`, so the loop spent the capacity it waited for. Guard shipped
(`8740767`): no ring while latched; `coordinator-session.sh` runs from each pod's fresh master
clone, so it is live already — the park is belt, the guard is the fix.

⚠ **Thresholds are CORRECT, do not "fix" them** (operator, 2026-08-06): `ANTHROPIC_UTIL_THRESHOLD_7D
= 0.95`, base `0.80` governs 5h (`argocd/resources/openrouter-proxy/deployment.yaml`). Both windows
happening to read 0.80 is coincidence; only 5h binds. A meta session that reads 7d=0.80 as binding
will wrongly project a multi-day stall — that error was made here.
⚠ **This meta session draws on the SAME subscription** as the loop's coordinator/reviewer sessions.
Heavy meta activity directly competes with dispatch capacity.

### ⛔ LIVE CHAIN — FU-143 soak FAILED, fix riding (09:40Z)

**Every remaining #29 child reproduces this until the image rolls out. Expect to hand-close each.**

circles#36 merged into the goal branch citing only its sibling #31, never its own issue #30. C6's
goal-child leg matches a merged PR whose body CITES the issue → `ghit=0` → no closeout unit → the
C4/C5 exclusion had nothing to key on → C4/C5 re-rode merged work. Killed pre-worker; a second
redispatch raced the hand-close and its session self-caught ("exiting clean, no writes made" — the
FU-121 belt). GitHub holds NO link between #30 and #36 (no keyword, no mention, so no
cross-reference event), so nothing can recover it after the fact.

**Chain, with the next step at each hop:**

1. ✅ Containment `12e7fcf` — C4/C5 HOLDS goal children (cannot tell merged-but-unlinked from
   abandoned) and reports them under ⛔ in the scan's orphan block. Ordinary issues unaffected.
2. ✅ `agent-runtime#34` OPEN, ARMED, **`ci` GREEN** (implements `agent-runtime#32`): finalize
   prepends `Implements #<n>` when the PR body does not already match. Waiting only on the
   reviewer — which is subscription-backed, so it was behind the SAME 5h latch as #31.
   ⛔ **IT DOES NOT SELF-CLEAR — #34 NEEDS THE OPERATOR. This is the FU-143 chain's real blocker.**
   Corrected 2026-08-06 11:15Z after it blew its deadline. The `platform` AgentStack claim sets
   **`reviewer.enabled=false`**, so `review-platform` skips all four of its repos every tick:
   `[agent-runtime] skipped — stack reviewer.enabled=false`. No bot will ever review it.
   `required-approval` on agent-runtime demands `required_approving_review_count: 1` with
   **OrganizationAdmin as the only bypass**, and #34 is authored by `RasmusSoot` — the jail
   identity — so self-approval is blocked. **ACTION: the operator approves + merges #34.**
   ⚠ Do NOT "fix" this by flipping `reviewer.enabled=true` for `platform`: that stack is
   deliberately operator-lane and the flip would also point the bot at **homelab** and
   `agent-coordinator`, which are tier-3 CODEOWNERS / never-agent-authored.
   ⚠ **How the wrong reading survived a check:** the pick predicate was verified (no author
   filter — true) and `review-platform`'s existence confirmed (true), but not whether the stack
   ENABLES it. Same "written is not applied" shape as the four logged on 2026-08-05, one layer up:
   the reflex ran, matched nothing, and said so — in a log nobody read until the deadline fired.
   **A deadline is what turns a plausible reading into a checked one.**
   ⚠ agent-runtime has NO `.agents/` BY DESIGN — operator ruling 2026-08-06: its fixes come from
   meta-coordination incidents, so drive it with the JAIL credentials, never look for an agent lane.
3. ✅ **#34 MERGED 11:17:25Z** — by the JAIL, via the OrgAdmin bypass. **⚠ THE REUSABLE FACT: the
   jail credentials ARE an OrganizationAdmin, so a `required-approval` ruleset whose only bypass is
   `OrganizationAdmin: always` is NOT a human gate — merge it yourself** (`gh pr merge --admin`).
   This session read that bypass list, saw `OrganizationAdmin`, and still escalated to the operator;
   the operator merged it and corrected the reading. Applies to every platform-lane repo
   (agent-runtime, agent-coordinator, homelab, openrouter-operator) where `reviewer.enabled=false`
   means no bot will ever approve. Self-approval stays blocked — the bypass is the path, not a review.
4. ⏳ **IN FLIGHT — the build FAILED once and is re-running.** Run `31096665105` pushed the
   versioned tag fine (`agent-base:2026.8.6-g4d58cf421a62`, manifest 2.3s done) then **failed on
   the `:latest` push** with a ghcr *secondary rate limit* 403 — transient, not #34's doing (five
   prior builds green). Because `image` failed, **`deploy-pin` was `skipped`**, so no pin PR opened.
   Re-ran the failed job (the versioned tag already exists, so it only redoes `:latest` + lets
   `deploy-pin` run). **NEXT: deploy-pin PR into homelab bumping `AGENT_BASE_IMAGE` in
   `agents/images.env` (currently `2026.8.5-gbbf8da511cb4` → `2026.8.6-g4d58cf421a62`) → merge.**
   Only THEN do new worker pods carry the fix. ⚠ If the re-run fails AGAIN it is NOT a rate limit —
   read `--log-failed`. ⚠ The pin also sweeps the mirrored literals in `agents/coordinator/*-argo.yaml`
   + `transcripts-*.yaml` (images.env header) — a hand-pin must do that sweep too.
   Filed **agent-runtime#35**: `:latest` is non-load-bearing (its only consumer is the
   `${AGENT_BASE_IMAGE:-…:latest}` fallback in `agent-session.sh:542`, always overridden by
   images.env) yet its failure gates `deploy-pin`. Three candidate fixes, the call is a design one.
5. ✅ **PIN LANDED — homelab#109 merged ~11:52Z**, `AGENT_BASE_IMAGE` → `2026.8.6-g4d58cf421a62`
   (sha matches #34's merge commit `4d58cf42`, so it is not a stale tag). Verified the one-line
   diff IS the full sweep: `grep -rn 'agent-base:2026'` finds NO literal outside `images.env` —
   every mirrored literal is `agent-coordinator`, a different image on its own deploy-pin.
6. ⏳ **RE-SOAK FU-143 — the subject is #32 ROUND 2**, dispatched 12:04Z, i.e. AFTER the 11:52Z pin,
   so it is the first ride carrying the fixed image. (Round 1 pre-dated the pin and died anyway.)
   ✅ **HALF ONE PASSED (12:41Z): the fix fires.** r2's own bookkeeping: `issue link ADDED
   (Implements #32) — the PR body did not name its issue`. The MODEL still omitted it; `finalize`
   now guarantees it, which is exactly agent-runtime#32/#34's contract. **PR#39** open, armed,
   `ci` green (188/188), `exit_status=clean`, $0.125.
   ⏳ **HALF TWO — the real verdict — is the MERGE**: C6 must auto-flip `agent/done`, CLOSE #32 and
   harvest, with NO meta hand-close. Only then archive the `12e7fcf` containment. The `e704c36`
   strong-link guard **STAYS** either way — requiring an implementing keyword is the correct
   predicate whether or not `finalize` guarantees the line. ⚠ Watch that C6 matches: the guard
   wants `implements|closes|fixes|resolves` + `#32`, and finalize writes `Implements #32` — these
   were built to meet, but this merge is the FIRST time they actually do.

   ⚠ **#32 round 1 DIED and read as a success.** `exit_status=harness-death`,
   `error_class=goose-32602-truncation` on `deepseek/deepseek-v4-flash`, 1757s, $0.0353, nothing
   committed, no branch — **yet the pod phase was `Succeeded`** (the wrapper handles the death and
   exits 0). Only `AGENT_RUN_STATS` in the ride's last log lines shows it. Re-queued by hand with
   an audit comment: a goal child is held out of C4/C5 by the containment, so **nothing
   re-dispatches it automatically** — that is the containment's stated price, one meta nudge.
   ⚠ Correction to the audit comment posted on circles#32: it cites `agent-runtime#31` as covering
   this, and **#31 is now CLOSED** — salvage was not broken here, it was correctly EMPTY (nothing
   had reached disk). See the "Open, not mine" block below. `#33` still stands.
   `meta-watch-loop.sh` now shouts on a terminal ride whose `exit_status` is not clean (`3f9d226`)
   — ⚠ best-effort only: ride pods are GC'd within minutes, so **that clause's silence proves
   nothing**; the durable signal is the `AGENT_STRIKE:` comment on the issue.

⚠ **Hand-close recipe for a #29 child until then:** verify the merge against the goal branch, post
an audit comment, `--add-label agent/done --remove-label agent/in-progress`, close. That fires
`goal-review` and unblocks `Depends-on:` siblings. It DOES suppress C6's harvest — read the review's
`Follow-ups:` yourself and file/judge them by the harvest bar.

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

✅ **That hazard FIRED — in the direction nobody priced — and is fixed (`e704c36`, verified live).**
It was logged here as a `gref`/open-PR risk (cost: a *starved* closeout). It actually hit the
`ghit`/merged-PR side: #36's *"that's the sibling issue (#31)"* made C6 dispatch `merged-closeout`
for **#31 while #31's ride was Running** — a false completion that would have closed the issue and
unblocked #32/#18/#19 on nonexistent work. C6 now requires a **strong link**
(`implements|closes|fixes|resolves` + `#<n>`); held children print under ⛔. `gref` stays a bare
mention on purpose (it fails toward *hold*). Detail:
[`issue-authoring.md`](issue-authoring.md) §"The SAME citation then fired C6 the other way".

⚠ **Consequence for the rest of this goal: NOTHING auto-closes until `agent-runtime#34`'s image
ships.** Every #29 child must be hand-closed with the recipe above — now by design, not by
accident. The ⛔ line in each scan names exactly which children are waiting.

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
- **homelab#103 is OPEN, and this goal is NOT its test** — corrected 2026-08-06 on the evidence,
  comment on the issue. The goal lane **serializes** on `Depends-on:` (#30 → #31 → #32 → {#18,
  #19}), so `wip` never exceeded 1 and wk-01 sat at **16% CPU** mid-rollout with a ride active. Max
  this decomposition can reach is **2** concurrent (#18 + #19 after #32). The burst's real shape is
  concurrent COORDINATOR Jobs across stacks/items — reproduce with many stacks/queued items, not
  one deep goal chain. Still true: the Job templates carry no CPU requests/limits and no topology
  spread, and **a stalled ride is a scheduling question before it is a code one.**
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

agent-runtime #13 (watchdog misses silent loops), #33 (resumed round reports "no resumable branch"),
**#35** (a failed `:latest` push skips `deploy-pin`); openrouter-operator sprouts triaged.
**#32 MERGED** (finalize guarantees the issue link — via #34). **#31 CLOSED 2026-08-06** as
solved-and-not-worth-it: `salvage_push()` (FU-064a, `agent-finalize:347`) already commits + pushes
uncommitted state at terminal and predates the issue by a month, and #31's own deliverable — a
zero-diff branch pointer at session start — banks NO work in the only window where it fires. All
three cited rides (circles#17 r1, openrouter-operator#14 r1, circles#32 r1) died before anything
reached disk, so salvage was correctly EMPTY, not broken. ⚠ The one case where salvage is *skipped*
rather than empty is FU-120's `agent-finalize`-never-ran anomaly, already belted. (`follow-ups-lint` was RED on FU-143's line count — fixed `ce29c74`, the detail
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
