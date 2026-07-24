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
- **C6 close-the-loop** (MP-G03, manual by design): on PR merge → verify the linked issue
  closed → flip labels: remove `agent/in-progress`/`agent/queued`, add `agent/done`.
- **Operator-lane work** the loop CANNOT do: `.github/workflows/*` changes (worker recipes +
  tokens forbid them), cross-repo IaC (oracle-iac has no fixer), platform/homelab changes,
  Composition/XRD work, incident response. Do these directly, through PRs with auto-merge.
- **Breaker clears**: `agent/error` is human-first — investigate, verify the anomaly is
  benign/root-caused, fix the class, THEN clear the label with an audit comment.

## Bootstrap a fresh session (do this first, in order)

1. `tail -120 agents/coordinator/TICK-LOG.md` — the last 2-3 entries are the arc's state +
   doctrines. Do NOT skip; the current doctrines live there (exclude-and-count, pin-follow,
   symptoms-only alerts, launcher-owned dispatch, "a belt is not a guard").
2. Live board, per active repo (oracle-fleet, oracle-iac at minimum):
   `gh issue list --repo teststuffstash/<r> --state open --json number,title,labels`
   `gh pr list --repo teststuffstash/<r> --state open --json number,title,labels,reviewDecision,mergeStateStatus`
   Reconcile: any bot-APPROVED spec-touching PR waiting on the codeowner gate? Any merged PR
   missing its C6 flip? Any `agent/error` latched? Any `agent/blocked` needing a design decision?
3. Cluster: latest `coordinate-<stack>` tick logs (`kubectl -n <stack>-agents logs <newest
   coordinate pod> -c main`), running ride/reviewer pods, any Failed workflow pods in workload
   namespaces.
4. Re-arm the loop watch: `Monitor` (persistent) running `bash agents/meta-watch-loop.sh` —
   change-dedup'd scan ticks, ride/reviewer pods, open-PR set, 25-min stall clause. Probes must
   FAIL LOUDLY (rule #6; three dead-probe incidents in meta-9 alone).
5. Check in-flight operator chains: `docs/agents/meta-state.md` (if present) lists any pending
   pin-follow / acceptance-run chains with their next step. Update it when starting/finishing one.

## Standing mechanics (how the routine beats run)

- **Fix-cycle chain** (a worker fix merged, image repo): wait deploy bump PR in oracle-iac
  (verify the bump POST-DATES the merge — the chain once pinned a stale tag) → pin-follow PR
  bumping `oracle-fleet/infra/workflow-ert-*.yaml` image refs → ArgoCD sync → submit the
  verification run (`ert-pipeline` WorkflowTemplate; `start-from=build` for build-side
  iteration, scratchpad manifests in git under agents/meta/ if needed) → Monitor the run.
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

## Hard lines (unchanged from the platform rules)

- plan/review before apply; never `talosctl upgrade` nocloud VMs; prior-art grep (FU/ADR/TICK-LOG)
  before filing/creating ANYTHING named; next steps reported to the operator carry FU/issue ids;
  alert descriptions are symptoms; probes fail loudly; a belt is not a guard — predictable events
  get guards at the source, the anomaly breaker stays for anomalies.
