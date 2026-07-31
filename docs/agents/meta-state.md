# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid.)

## Live world state (2026-07-31)

- **World ENABLED.** `coordinate-sleep` + `review-sleep` CronWorkflows live (10-min cadence,
  not suspended), ticking green. Sleep worker = `claude/haiku`, coordinator/reviewer = sonnet.
- **Infra hardening landed TODAY (07-31, operator session)** — `devbox run ci` + `devbox run
  test-integration` now work both in-ride and in CI for sleep; sleep's agent-stack ≈ oracle-fleet.
  FU-118/119/120 done. No structural blockers outstanding. (Detail: TICK-LOG 2026-07-31 entry.)

## ACTIVE DRIVE — clear the sleep-tracking harvested-follow-up queue (operator ask 2026-07-31)

Operator: "pick any open sleep-tracking issue (not #16 dep-dashboard), label it, let the loop pick
it up. Keep going until the 14 issues are done or a major blocker appears." These 14 are all
bot-authored 🌱 harvested follow-ups sitting at the FU-090 human-triage gate — operator has
delegated adopting them. Sleep = ONE WIP slot (FU-042 per-stack), so queue in waves and let the
loop serialize. Label to adopt = `agent-fix` + `agent/queued` + `task/fix` (all are fixes/cleanups,
no build deliverables).

THE 14 (excl. #16). Status source-of-truth = GitHub labels; this list = my dispatch order/notes:
- **#55** dedup log always 0 — QUEUED first (pipeline-validation lead; real self-contained bug).
- #60 log warning-not-info · #66 nights.yaml stray blank lines · #64 vitals comment · #50 GLOSSARY
  stale · #51 README stale topology · #58 snore-only count list-scan · #68 dup SQL query · #69
  fixture→conftest · #73 _chmod_tree over-chmod · #74 frser download checksum · #54 is_nap tz test-gap
  — clean cleanups/refactors/docs; queue in waves after #55 proves the pipeline.
- **#57** snore-only upsert clobbers band cols (SLP-ING-SRC-SNORE-ONLY) — REAL bug, spec anchor;
  read spec + pre-decide ⚖ before queuing.
- **#77** datasource uid hardcode — ⚠ CARE: meta-16 flagged this as the dominant prod-blank cause,
  needs cross-repo confirmation of WHERE prod provisions the datasource (sleep-iac / chart has no
  datasource template). May be OPERATOR-LANE (cross-repo). Read fully before queuing; don't hand a
  worker an unverifiable cross-repo task. Queue LAST.

Wave discipline: verify #55 lands green end-to-end (dispatch → CI gate → review → merge) FIRST —
infra changed today, so prove the pipeline before mass-queuing. Then feed waves of ~3.

## Standing / parked (compressed — detail in TICK-LOG or the FU)

- **FU-117** (context architecture) — DELIBERATE let-it-pile-up (operator's grow-then-refactor).
  Note sightings; don't refactor yet.
- **Dep-gate fragility**: a markdown-bullet `- Depends-on:` slips the `^[ \t]*depends-on:` scan
  regex. Write Depends-on lines UNBULLETED until FU-111 (native `blockedBy`) lands.
- Worker git tokens CAN push `.github/workflows/*` (homelab-agents App has `workflows:write`, proven
  PR#80). Workflow-only issues ARE worker-doable. Branch-protection RULE edits stay repo-admin/tofu.
- **FU-058 retro-session** deployed SUSPENDED (hand-fire). **Oracle/UC-1** operator-paced (its lane).

## Re-arm on a fresh session (watches die with `/clear`)

- Loop watch (`bash agents/meta-watch-loop.sh`, persistent) + 2h backstop heartbeat (each sweep runs
  `agents/meta-alert-crosscheck.sh`). Re-arm fresh; don't trust old monitor ids.
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; never a bare
  `devbox run -- kubectl` with no subcommand (prints help into the captured var); watch the FAILURE
  signature explicitly; stop orphan monitors from dead sessions on sight.
