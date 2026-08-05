# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)

## Fresh-session pickup (2026-08-05)

- **circles is the live stack, and its work lands on a BRANCH, not master.** The woven spec
  contract is PR circles#16 (`research/issue-1-weave`, CI green, human-gated — never arm it). The
  three implementation goals circles#17/#18/#19 (`task/build`) declare that branch as their base,
  so the launcher forks from it and the PR must open against it. **Nothing merges to master while
  this holds.** The failure mode is not a launcher bug: `--base` reaches the ride as env-card
  PROSE, and `gh pr create` with no `--base` silently targets the default branch. The watch clause
  is `BASE_EXPECT` in `agents/meta-watch-loop.sh` (scoped to `^agent/` heads so the human-gated
  `research/*` PRs stay quiet). The four issue-1 arms (#2–#5) and the six comparison PRs (#7–#13)
  are the operator's to read/merge, not the loop's.
  **The loop is LIVE on circles since 2026-08-05** (`coordinator.enabled` + `loop.graduated` both
  true, `circles-iac af905ec`+`84e715a`). Rides verify correct: pod env carries
  `BASE_REF=research/issue-1-weave`, so the launcher honours the declared `Base:`. ⚠ the merge
  path stays UNEXERCISED until the weave lands on master (the seeding rule's proof was skipped
  knowingly — these rides are human-gated by construction, so nothing auto-merges).
  **#17 r1 FAILED with no deliverable** (`tencent/hy3`, $0.06, `blocked-deliberate`): burned its
  whole turn budget reading the 15-page/91-requirement contract, force-finalized before writing
  code, banked nothing. r2 running on `deepseek/deepseek-v4-flash`, again with NO `WORK_BRANCH`
  — it re-reads the whole contract and pays the tax again (that is agent-runtime#31).
  **OPERATOR CALL PENDING:** split #17 into bake/page/CI issues, or `modelDeny` the cheap tier on
  circles (deny DOES bind here — `routerMode: authoritative`, unlike the platform stack), or keep
  retrying at ~$0.06. #18/#19 are unlabelled and would hit the same wall.
  **Two silent walls behind that switch were removed 2026-08-05 (`84cc5f0`)** — do not
  re-introduce either: TRACKS rule 1 counted ALL open PRs though its rationale is updater churn
  and the updater only touches ARMED ones, so circles' 12 human-gated PRs held #17 out of dispatch
  forever; and FU-124's nudge selected on `mergeStateStatus` that was never in the `--json` list
  (gh omits unasked fields → jq null → never matched), so it had NEVER fired. Circles is smoking
  out a whole class: rules written when "open PR" implied "armed ride PR".
- **circles is the CHAINLESS pilot — do NOT "fix" a stuck ride by adding a chain.** The claim
  (`circles-iac/circles/agent/agentstack.yaml`) declares no `workerModel`/fallbacks on purpose and
  `routerMode: authoritative` makes the routed pick binding. If rounds get stuck on a flaky free
  model, the levers are `modelDeny` on the claim and the router's own strike/cooldown path — NOT a
  static chain. ⚠ `rotation_fallback` in `model-classes.json` is `{"coding": [], "reasoning": []}`,
  i.e. the git-curated belt is EMPTY, so there is nothing behind the live rotation universe.
- **The cross-jail handoff channel is armed** (`agents/meta-handoff-watch.sh`, new 2026-08-05).
  The circles jail has no homelab access, so it files tasks under `/workspace/.handoff/circles/
  inbox/`; `/handoff` is the mono-side procedure. One task processed so far (the base-branch
  launcher change, 4243bd9). Watch emits on new inbox files and on a `doing/` claim older than 45min.
- **openrouter-operator chain: COMPLETE + VERIFIED 2026-08-05.** #10 (GC timer, PR#13) + #14
  (chart RBAC `delete` verbs, PR#16) both merged, C6-closed `agent/done`, chart deployed via
  homelab#104 (`2026.8.5-g5c54eade1197` — ⚠ that PR's TITLE still named the older chart; the
  DIFF is what to read). End-state probed: `can-i delete openrouterkeys|secrets` → **yes**, the
  timer logs `gc_expired_keys succeeded` with no 403, ephemeral CRs **13 → 3** (the 3 are
  correctly retained: one inside its 24h grace, two unexpired). The 401 headroom floor is gone.
  Sprout **#15** (factor the incluster/kubeconfig fallback) is unlabeled behind the FU-090 gate —
  operator triage. ⚠ LESSON: a chart-pin PR can be opened from a sha that PREDATES the fix it is
  supposed to carry — #104 was created at 10:01 from the GC-timer commit and only re-pushed to
  the RBAC chart at 11:14. Read the diff, never the title.
- **LEG (c) — BUILT 2026-08-05 except the budget arithmetic** (operator un-deferred + ruled:
  both discriminators, non-dispatchable parent initially). Shipped: `goal-decompose` clause in
  `coordinator-scan.sh` (branches BEFORE recipe selection — a `goal` class would FATAL the
  launcher on a missing `.agents/goal.yaml`, which deliberately does not exist); the play in
  `agents/coordinator/README.md`; `task/goal` in the claim taxonomy; the launcher READS native
  parentage and injects a BOUNDED Goal+Acceptance card (1845c of a 4799c body on circles#17 —
  the whole parent is what killed r1); the scan carries the parent id as a 5th unit field, free
  (`parent` rides the existing `gh issue list` call), and the item brief tells the session to
  judge a child against the GOAL's acceptance. **REMAINING:** `Budget:` body line +
  Σ(child estimates) ≤ parent in the launcher pre-flight; a `goal-review` clause firing when a
  child closes. ⚠ Nothing wakes a goal on child traffic alone — that backstop is the
  meta-coordinator's by operator ruling (observe, then design the guard from evidence).
  Design: `docs/agents/issue-authoring.md` §Leg (c).
- **circles#21 is a FROZEN BENCHMARK** (`major/awaiting-human`, which excludes it from the
  `changes-requested` clause; the reviewer does NOT skip that label, so the one review still
  happens). It is the ONE-SHOT arm: what `deepseek/deepseek-v4-flash` produced against the whole
  of goal #17 in a single ride, base `research/issue-1-weave`, un-armed. The fan-out arm is the
  same goal decomposed once leg (c)'s remaining legs land. **Do not push to it, dispatch a fix
  round on it, or merge it** — a repair cycle destroys the comparison. r1 (`tencent/hy3`)
  produced nothing at all, so #21 is r2's work standing alone.
  ⚠ **The freeze has TWO doors and the label only guards one.** `major/awaiting-human` sits on the
  PR and guards the `changes-requested` clause; **C4/C5 keys on the ISSUE**. At 12:00 it emitted
  `c4c5-redispatch` for a round 3 because the scan links issue↔PR by matching `#<n>` in PR BODY
  TEXT and #21's body never named #17 (`build.yaml` has no linking rule — `fix.yaml` does; the gap
  is donor-inherited, circles AND sleep-tracking). Fixed truthfully: `Implements #17` prepended to
  the body (no code touched) and #17 moved to `agent/review`. Mechanism fix filed as
  agent-runtime#32 (finalize guarantees the link for every recipe). If #17 goes back to
  `agent/in-progress`, C4/C5 can re-fire — check the body link first.
- **⚠ GitHub caps label descriptions at 100 chars**, and `IssueLabels` is authoritative over a
  repo's whole label set — so one over-long description freezes the taxonomy for EVERY claim-owned
  repo (11/12 went ReconcileError on my 113-char `task/goal` text, 2026-08-05). Fixed to 85;
  `openrouter-operator-labels` was still retrying on backoff at hand-off — verify it reached
  `Synced=True`, and that `task/goal` exists on that repo.
- **Platform work queue: DRAINED 2026-08-05.** homelab#63/65/78/94/98/99/100/101 + #103 closed with
  live-verified evidence (optane0 now 0 replicas / tags `fast`-only; wk-02 single-tier `bulk`;
  mirror-ghcr 33% after the 20→40Gi bump; wk-02 allocatable 9.9Gi of 11.66Gi = FU-139 reservation
  applied). **Only homelab#97 stays open, `agent/blocked` on FU-142** — homelab is a dispatch
  target with no `.agents/fix.yaml`, so the launcher refuses before a pod exists. That recipe is
  the next structural win: it converts platform issues from meta hand-work into loop work.
- **Soak watches, not actions** (each gates a later operator flip): iac-sentinel shadow
  violations (→ G01 enforcement flip, FU-106), router shadow decisions + capability-floor skips
  (→ P4 flip, FU-095), native blockedBy edges in scan logs (→ FU-111 body-line retirement),
  Monday 05:00 retro fire (= FU-058 run 3) + the first 05:47 janitor ticks. Three Phase-3 legs
  wait on a first real event: the `subject:` correlation key, `Touches:`, and the homelab revert
  path. ⚠ Garage still has no offsite backup (FU-137) and now carries tofu state too.
- **Cleared 2026-08-05:** agent-runtime#29 + #30 and all three FU-130 PRs (circles#15,
  sleep-tracking#115) are MERGED; openrouter-operator's guardrail came off (f45801f). The old
  "open, un-armed" bullet was stale — verify before chasing.
- **Two agent-runtime findings from today's failed rides, operator-lane (no fixer there):**
  **#31 (new)** — a ride that dies before its FIRST commit banks nothing, because the recipes'
  incremental-push rule fires *after* that commit; hit twice today in two repos on two models
  (circles#17 turn-budget stop, openrouter-operator#14 goose truncation — the latter had already
  made the correct edit to `chart/templates/rbac.yaml` when it was cut off). Fix: entrypoint
  pushes the work branch at session start. **#13 (evidence added)** — the repetition watchdog
  from #29 IS in the deployed image and still missed a textbook loop (8 completions pinned at
  the 16384 max_tokens floor, 38 min, zero output, stopped by hand); its detector keys on a
  repeated LINE in run.log and this loop was silent. Suggested signal: N consecutive near-max
  completions with no tool progress — proxy-side, so it survives a pod kill.

## Re-arm on a fresh session (watches die with `/clear`)

- Loop watch: `STACK_NS=circles-agents RIDE_NS=circles REPO=teststuffstash/circles
  SCAN_PREFIX=coordinate-circles- BASE_EXPECT=research/issue-1-weave bash agents/meta-watch-loop.sh`
  (persistent) + `bash agents/meta-handoff-watch.sh` (persistent) + the 2h backstop heartbeat, each
  sweep running `agents/meta-alert-crosscheck.sh`. Re-arm fresh; don't trust old monitor ids.
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; never a bare
  `devbox run -- kubectl` with no subcommand (prints help into the captured var); watch the FAILURE
  signature explicitly; stop orphan monitors from dead sessions on sight.
