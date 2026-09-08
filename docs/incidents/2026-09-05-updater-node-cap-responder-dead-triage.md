# 2026-09-05 — the updater red for 65h on a GraphQL node cap, the responder's triage dead for ≥7 days, the retro's cells dead on `set -u` — and one belt fired, into a dead responder

Three machine-lane failures found in one read on 2026-09-08 (operator: "look at the failing argo
workflows in agent-coordinator"). Each was a different failure shape; none was seen by the lane
that exists to see it, and the one belt that did fire (`ArgoWorkflowsFailing`) handed the alert
to a responder whose every triage session had been dying at launch.

## Timeline (UTC)

- **≤ 2026-08-29** — last issue the responder filed from a triage (homelab#1013, `🚨
  GarageTableEmpty`). Every later `alert-fp:` hit is a Goal/theme body, not a triage.
- **2026-09-01 19:24** — Loki's 7-day horizon: the first retained responder session, already dead
  at model selection. All 132 `resolve-model(responder)` lines since read `router=dispatch
  model=claude/sonnet`; all 156 sessions since print `triage session failed`.
- **2026-09-05 22:23** — PR#1465 merges (`updater: leg 1 brings a PR current only when
  MERGE-READY`), adding `commits,reviews` to the leg-1 `gh pr list --limit 100`.
- **2026-09-05 22:30** — first `update-pr-branch-cron` tick after the merge fails on every repo:
  `GraphQL: … requesting up to 1,000,000 possible nodes which exceeds the maximum limit of
  500,000`. Every edge and cron pass after it fails the same way (Loki: nothing but this error
  and `Cloning into` from any updater pod since).
- **2026-09-05 10:27** (earlier the same day) — PR#1386 ships the context bundle as a ConfigMap
  and initializes `PF_CM_MOUNT`/`PF_CM_VOLUME`/`PF_CM_CREATED` inside the issue-* preflight arm.
- **2026-09-07 05:00** — the weekly platform retro fires; both cells die before their pod exists
  (`agent-session.sh: line 2368: PF_CM_MOUNT: unbound variable` → `PREFLIGHT REFUSED` → `HARVEST
  FAILED: no cell produced a report`). `RetroReportOverdue` fires 05:31.
- **2026-09-08 11:31, 14:31** — the responder rides `RetroReportOverdue` twice; both sessions die
  at launch (the second is a same-day dedup skip).
- **2026-09-08 15:16** — `ArgoWorkflowsFailing` crosses 40/6h (the updater's edge burst on a busy
  master afternoon finally lifts the fleet count); 15:31 the responder rides it — dead session;
  the WARN says "refire re-triages tomorrow".
- **2026-09-08 15:4x–16:3x** — operator read; the three fixes: PR#1521 (updater), PR#1522
  (responder), PR#1523 (agent-session).

## Root causes

1. **Updater (PR#1465):** gh expands `--json commits` to `commits(first:100){authors(first:100)}`;
   at `--limit 100` the query costs 1,000,000 possible nodes against GitHub's 500,000 cap and is
   rejected before a single PR is read (`--limit 50` still costs 505,050). `reviews` alone lists
   fine. The replay stub answers `gh pr list` from a recorded world, so a query GitHub itself
   refuses is invisible to the harness by construction — the field change was a live-API contract
   change that shipped with no live `gh pr list` run.
2. **Responder (since ≤ 09-01):** `resolve-model.sh` returns the router's rail-prefixed id
   (`claude/sonnet`); the responder passed it verbatim to `claude --model`, which takes the bare
   alias (`There's an issue with the selected model (claude/sonnet)`). The coordinator hit the
   identical bug on 2026-08-23 and was fixed (FU-127, PR#813: parse through `model_id.py`);
   the responder's call site, wired the same day (#788), was not. The trigger — when the router
   began answering `dispatch` for the responder role — was not identified (the last successful
   filing is 08-29; Loki starts 09-01).
3. **Retro cells (PR#1386):** the pod manifest expands the bundle variables for every task shape,
   but they were initialized only in the issue-* arm; any non-issue task (the retro cells, an
   ad-hoc run) died under `set -u` at `volumeMounts:`.

## Why nothing alerted (the belt audit)

- **A template failing 100% of its runs sits under the fleet threshold.** `ArgoWorkflowsFailing`
  is fleet-wide (the controller's counter has no workflow namespace/template) and tuned to 40/6h;
  the updater's steady state is 4 cron + a few edge failures per 6h. It stayed under the line for
  65 hours and crossed it only on the afternoon PR burst.
- **A green workflow can carry a dead ride.** The responder's triage session is
  `claude … || echo WARN`; the workflow Succeeds, the budget ledger counts a spawn, the dashboard
  shows "8/12 spawned today". Nothing distinguishes a session that investigated from one that
  died at its first line — the exact "liveness ≠ output-watching" shape, one layer up again.
- **The belt that fired was answered by the dead lane.** `RetroReportOverdue` and
  `ArgoWorkflowsFailing` both routed to the responder as designed; the responder's own failure
  mode is the one it cannot report on.
- **The merge path stalling has no alert of its own.** With the updater down, a merge-ready PR
  that goes BEHIND waits for a human; `CodeownerParkWaiting` fires for parked PRs, not for
  "armed + approved + BEHIND and nobody is updating it".

## Fix

- **PR#1521** — `reviews` stays in the snapshot; leg 1 probes `gh pr view --json commits` per
  candidate, and only for a candidate whose snapshot reviews carry a bot APPROVED at all (the
  unreviewed-BEHIND population costs no call). Unreadable probe → HOLD line (rule #6). The
  updater replay family gains the probe CALLs and per-row `pr-view-<n>.json` overlays (17/17);
  verified live on homelab and oracle-fleet with the jail token.
- **PR#1522** — the responder parses the routed id through `model_id.py --shell` and takes
  `MODEL_MODEL` (the coordinator's FU-127 move).
- **PR#1523** — the three bundle variables are initialized to empty before the issue-* arm.

## Residuals

- **FU-227** — the two belt gaps above: a 100%-red template under the fleet threshold, and a
  triage session that dies inside a green workflow. Candidate shapes are in the item.
- **Live-API contract changes in `gh … --json` field lists** are not something the replay
  harness can see. The reviewer rubric's own-fix-completeness read is the only gate; a `gh pr
  list` field change deserves one live run in the PR body. Recorded here, not filed — the next
  instance decides whether it becomes a rubric line.
- The retro report for the week of 2026-09-07 is produced by resubmitting `cronwf/retro-session`
  after PR#1523 merges (also the end-state check for that fix).
