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
  **#17 is labelled + queued and the scan now calls it ACTIONABLE; the ONLY thing holding it is
  `coordinator.enabled: false` on the claim — deliberate** (the seeding rule: merge-path proof +
  first supervised rides before any loop dispatch). Order to start: (1) trivial PR E2E through
  CI→review→auto-merge, (2) flip `enabled: true` in `circles-iac/circles/agent/agentstack.yaml`,
  (3) label #18/#19 (they carry `Depends-on: #17`). ⚠ TENSION to resolve: the merge-path proof
  merges to master, which the "nothing merges to master" rule forbids — a throwaway README PR
  satisfies both, but it is the operator's call.
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
- **openrouter-operator chain, machine-owned — VERIFY the end, don't perform the middle.** #10
  (GC timer) → PR#13 merged 09:59 → C6 verified working (flipped `agent/done`; harvest sprouted
  **#15**, unlabeled behind the FU-090 gate, operator triage). **#14 (chart RBAC `delete` verbs)
  dispatched 10:00 and is the fix that makes #10 REAL** — without it the merged timer 403s every
  15 min per CR and #10 reads as fixed while the litter grows. **Only remaining check, after its
  PR lands + the chart pin deploys:** `kubectl auth can-i delete openrouterkeys --all-namespaces
  --as=system:serviceaccount:openrouter-operator:openrouter-operator` → `yes` (same for
  `secrets`), then the expired CRs listed in #10 vanish with no 403 in the operator log.
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
- **Open, un-armed, not mine:** agent-runtime#29 (watchdog), the three FU-130 PRs (circles#15,
  sleep-tracking#115, agent-runtime#30), and openrouter-operator's guardrail policy call
  (`stack-lint` KEY-02 fails until decided).

## Re-arm on a fresh session (watches die with `/clear`)

- Loop watch: `STACK_NS=circles-agents RIDE_NS=circles REPO=teststuffstash/circles
  SCAN_PREFIX=coordinate-circles- BASE_EXPECT=research/issue-1-weave bash agents/meta-watch-loop.sh`
  (persistent) + `bash agents/meta-handoff-watch.sh` (persistent) + the 2h backstop heartbeat, each
  sweep running `agents/meta-alert-crosscheck.sh`. Re-arm fresh; don't trust old monitor ids.
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; never a bare
  `devbox run -- kubectl` with no subcommand (prints help into the captured var); watch the FAILURE
  signature explicitly; stop orphan monitors from dead sessions on sight.
