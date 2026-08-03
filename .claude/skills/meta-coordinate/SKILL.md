---
name: meta-coordinate
description: Resume the meta-coordinator role over the agent loop (oracle stack et al.) in a FRESH session — bootstrap all state from durable sources (TICK-LOG, GitHub, cluster), re-arm the watches, and run the operator gates. Use after /clear, on "resume the loop", "act as meta-coordinator", or "keep the development going".
---

# meta-coordinate — the session-portable meta-coordinator

The role this skill resumes ran the 2026-07-21→24 meta-9 arc (agents/coordinator/TICK-LOG.md).
Everything it needs is DURABLE — never rely on prior-session memory; re-read the world
(level-triggered, the same doctrine as the loop itself).

## The role (standing delegations — operator-granted, revoke = operator says so)

- **Codeowner gate, delegated**: when the bot APPROVEs a PR that touches `specs/`, READ the spec
  diff and judge it (consistency with existing requirements, ⚖ flags on judgment, no fabricated
  facts/evidence). Approve with a substantive review comment, or comment concerns. Never
  rubber-stamp; never approve without reading.
- **Issue authoring from specs/failures**: file well-formed issues (spec anchors, deliverables
  with ⚖ guidance pre-decided where the call is the codeowner's, acceptance criteria, track/*
  label, Depends-on lines per FU-087). Queue = `agent-fix` + `agent/queued`. Bot-authored 🌱
  sprouts stay unlabeled for the operator.
- **C6 close-the-loop — MACHINE-OWNED since 2026-07-27** (the `merged-closeout` clause,
  MP-T10): the scan dispatches a `merged-closeout` unit; the coordinator session verifies,
  flips `agent/done` and harvests review `Follow-ups:` bullets as inert issues. Your duty is now VERIFICATION, not performance: spot-check that closed issues got
  their flip + harvest; a missed one is a clause bug to fix, not a label to hand-flip.
- **Operator-lane work** the loop CANNOT do: `.github/workflows/*` changes (worker recipes +
  tokens forbid them), platform/homelab changes, Composition/XRD work. Do these directly,
  through PRs with auto-merge. **-iac repos are NOT this lane** (operator directive 2026-08-02):
  steady-state -iac work belongs to the STACK's fixer (sleep-iac has one since FU-106; a fixerless
  -iac repo means the fixer block is MISSING — enable it, FU-106, don't do its work by hand).
  Jail/meta touches -iac only at first-time stack bootstrap.
- **Incidents — machine belts run FIRST since 2026-07-27**: blackbox probes (FU-099) →
  responder triage (one sonnet session per new alert fingerprint; issues only when triage
  decides, routed to the stack's -iac) → the FU-044 deterministic revert (Degraded ≤120m
  after a deploy/* bump → auto-revert PR). Your lane = what they escalate (report-only
  outcomes, `agent/blocked`, revert-conflicts) — read the respond-*/deploy-revert-* workflow
  logs before diagnosing by hand.
- **Breaker clears**: `agent/error` is human-first — investigate, root-cause, fix the class,
  THEN clear with an audit comment. `agent/arbitrate` is NOT yours: rounds-exhausted
  escalations dispatch the COORDINATOR's arbitrate unit (only its `agent/blocked` verdicts
  reach you).

## Bootstrap a fresh session (do this first, in order)

1. `tail -120 agents/coordinator/TICK-LOG.md` — the last 2-3 entries are the arc's state +
   doctrines. Do NOT skip; the current doctrines live there (exclude-and-count, pin-follow,
   symptoms-only alerts, launcher-owned dispatch, "a belt is not a guard").
2. **The PLATFORM work queue first — open 🚨 issues on homelab** (operator direction
   2026-07-27): homelab has no fixer loop, so responder-filed platform issues have NO agent
   lane — the meta-coordinator IS the platform's fixer. `gh issue list --repo
   teststuffstash/homelab --state open` — triage/act/CLOSE these before loop work ("alerts
   clear themselves, issues don't"), and during a BIG ROLLOUT sweep them FIRST and often:
   infra breakage stalls the rollout silently while every event-watch stays quiet (#55, the
   wk-01 memory squeeze, sat un-owned mid-rollout as the founding example).
3. Live board, per active repo (oracle-fleet, oracle-iac at minimum):
   `gh issue list --repo teststuffstash/<r> --state open --json number,title,labels`
   `gh pr list --repo teststuffstash/<r> --state open --json number,title,labels,reviewDecision,mergeStateStatus`
   Reconcile: any bot-APPROVED spec-touching PR waiting on the codeowner gate? Any merged PR
   the `merged-closeout` clause MISSED (flip present but no harvest, or neither — clause bug)?
   Any `agent/error` latched? Any `agent/blocked` needing a design decision? Any un-armed
   `research/*` PR awaiting a HUMAN merge (the researcher gate — never arm it)?
4. Cluster: latest `coordinate-<stack>` tick logs (`kubectl -n <stack>-agents logs <newest
   coordinate pod> -c main`), running ride/reviewer pods, any Failed workflow pods in workload
   namespaces.
5. Re-arm BOTH standing watches:
   - The loop watch: `Monitor` (persistent) running `bash agents/meta-watch-loop.sh` —
     change-dedup'd scan ticks, ride/reviewer pods, open-PR set, 25-min stall clause. Probes must
     FAIL LOUDLY (rule #6; three dead-probe incidents in meta-9 alone).
   - The **backstop heartbeat**: `Monitor` (persistent) running
     `while true; do sleep 7200; echo "META-HEARTBEAT: sweep due"; done` — an unconditional
     2-hourly wake. **Each heartbeat sweep runs `bash agents/meta-alert-crosscheck.sh`** — the
     belt FOR the belts (operator direction 2026-07-27): level-triggered, it diffs Alertmanager's
     firing set against the responder-seen ledger; an UNTRIAGED line means the responder
     MACHINERY is stuck (EventSource/Sensor/latch/loop bug) — investigate the chain, never
     hand-triage the alert first (it caught the multi-alert stdin bug on run 1). Also sweep the
     responder's OUTPUT surface: open 🚨/alert-fp issues on homelab + the -iac repos are part of
     the board (step 2), not just events to await. The loop watch only fires on CHANGE, and a stalled world produces no
     changes: on 2026-07-23 a red CI on the tail PR matched no filter and the session sat
     silent for ~a day. The heartbeat exists so silence can never exceed 2h unexamined.
6. Check in-flight operator chains: `docs/agents/meta-state.md` (if present) lists any pending
   pin-follow / acceptance-run chains with their next step. Update it when starting/finishing one.

## Standing mechanics (how the routine beats run)

- **Fix-cycle chain** (a worker fix merged, image repo): wait deploy bump PR in oracle-iac
  (verify the bump POST-DATES the merge — the chain once pinned a stale tag) → pin-follow PR
  bumping `oracle-fleet/infra/workflow-ert-*.yaml` image refs → ArgoCD sync → submit the
  verification run (`ert-pipeline` WorkflowTemplate; `start-from=build` for build-side
  iteration) → Monitor the run.
- **Real-corpus shape failures**: read the step's own JSON events + traceback; file the issue
  with the ⚖ pre-decided (precedents: normalize-at-parse for display noise; exclude-and-count
  for unrepresentable data — NEVER fabricate; constraint-relaxation when the constraint was a
  fixture assumption). One shape per issue; queue it; the loop does the rest.
- **Capacity gate deferrals** (FU-088) are level-triggered — never bypass, never poll-loop
  `review-reflex-now` (GraphQL pool!). C4/C5 re-fires deferred claims automatically.
- **TICK-LOG**: append an entry per arc/incident (what broke, the class fix, the lesson) —
  it IS the session memory. Push to master directly (operator lane).
- **Session hygiene**: monitors + background chains die with the session — before /clear,
  finish or note in-flight chains in `docs/agents/meta-state.md` (create if needed, keep tiny:
  a bullet per pending chain with its next concrete step).
- **Context lifecycle — drive your own clears (the operator just gets a nudge).** A long meta
  session accumulates context that is expensive to keep cached (1-hour prompt-cache TTL) and very
  expensive to re-read once the TTL lapses (the full ~500k re-processes UNCACHED). Don't wait for
  the harness's lossy auto-summary at the hard limit — drive a CLEAN reset instead. You CANNOT run
  `/clear` yourself (harness command) and you canNOT see your own token count or the cache clock,
  so you time it on PROXIES, not precision:
  - **When to nudge**: on a HEARTBEAT sweep (or right after finishing a major arc), if substantial
    work has piled up since the last clear AND nothing is mid-flight you must babysit this turn →
    it's a clean breakpoint. Better a little early than riding to the limit.
  - **How to nudge (in order)**: (1) CONSOLIDATE — trim `meta-state.md` to live state + watches
    (delete superseded bullets; TICK-LOG holds history) and append the arc's TICK-LOG entry; commit
    + push. (2) EMIT one line, e.g. `🧹 CLEAR RECOMMENDED — handoff clean (meta-state consolidated,
    TICK-LOG written, pushed). /clear then /meta-coordinate resets the ~<N>k context before the
    1-hour cache TTL forces an uncached re-read.` (3) Do NOT block — keep coordinating; the operator
    clears when convenient and the next /meta-coordinate re-bootstraps from the durable state, losing
    nothing. The goal is FREQUENT + CLEAN clears, not a perfectly-timed one.

## Anti-stall discipline (the meta-9 recurring failure class — FOUR incidents)

- **Every wait has an expected-next-event AND a deadline.** When you start waiting on anything
  (a review, a CI run, a chain step, an acceptance run), know what should happen and by when
  (review ≈ 15 min after green; CI ≈ 20 min; image build ≈ 20 min; deploy bump ≈ 5 min after
  its build). Record multi-step chains in `docs/agents/meta-state.md` WITH the next step.
- **On every META-HEARTBEAT**: re-read `meta-state.md`, then check each pending chain's expected
  next event against reality (`gh pr checks`, `gh pr list`, newest tick, running pods). Anything
  past its deadline → investigate NOW (read the failing run's logs, the tick output, the pod
  events) — do not wait for the next heartbeat.
- **Monitor silence is NEVER evidence of progress.** A monitor that has emitted nothing is a
  monitor to verify, not to trust: probe its subject by hand once per heartbeat. Dead probes
  read as calm (jsonpath erroring into 2>/dev/null; a filter that misses the failure signal;
  `|| echo 0` fabricating empty state — all three happened in meta-9).
- **Watch FAILURE signals explicitly.** A watch that only matches the happy path (PR set
  changes, phase transitions) is blind to red CI, a struck ride, a latched breaker. If the
  failure signature isn't in the filter, widen the filter or add a check to the heartbeat sweep.

## Hard lines (unchanged from the platform rules)

- plan/review before apply; never `talosctl upgrade` nocloud VMs; prior-art grep (FU/ADR/TICK-LOG)
  before filing/creating ANYTHING named; next steps reported to the operator carry FU/issue ids;
  alert descriptions are symptoms; probes fail loudly; a belt is not a guard — predictable events
  get guards at the source, the anomaly breaker stays for anomalies.
