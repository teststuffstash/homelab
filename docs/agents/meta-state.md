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

## ✅ DONE — sleep-tracking harvested-follow-up drive (2026-07-31): 14/14 merged

All 14 merged (0 open PRs, 0 breakers). #77 finale needed a manual updater dispatch (FU-124). Left
for the operator's triage (unlabeled): **#92/#93/#96/#101/#102** (machine-harvested review-Follow-up
sprouts from the merged PRs) + **#99** (pinned-SHA-256 hardening, the accepted #98 follow-up). New FUs
this session: **FU-123** (in-pod arm fails, hypothesis), **FU-124** (last-PR-behind cron-backstop
unreliable). FU-122 filed+retracted. Poll 120→90 live. Detail: TICK-LOG 2026-07-31 (cont.) entries.
The rest of this file below is stale-but-harmless standing context; the drive section is retired.

## (retired) ACTIVE DRIVE — clear the sleep-tracking harvested-follow-up queue (operator ask 2026-07-31)

Operator: "pick any open sleep-tracking issue (not #16 dep-dashboard), label it, let the loop pick
it up. Keep going until the 14 issues are done or a major blocker appears." These 14 are all
bot-authored 🌱 harvested follow-ups sitting at the FU-090 human-triage gate — operator has
delegated adopting them. Sleep = ONE WIP slot (FU-042 per-stack), so queue in waves and let the
loop serialize. Label to adopt = `agent-fix` + `agent/queued` + `task/fix` (all are fixes/cleanups,
no build deliverables).

PROGRESS (source-of-truth = GitHub labels; this = live snapshot ~16:05Z):
- ✅ **MERGED (8):** #55, #50, #58, #60, #64, #51, #66, #68.
- 🔍 in review: #54(PR#91), #57(PR#94 — verified correct) · 🏗 riding: #69 · 📋 queued: #73, #74.
- **#77** still the HELD FINALE (see below). After #73/#74 land, queue #77 with detailed steering.
- **#57** (snore-only upsert clobber, SLP-ING-SRC-SNORE-ONLY) queued WITH ⚖ steering comment
  (COALESCE-guard band-owned cols on the snore-only path only + a decision-table test row).
- **#77** (datasource uid hardcode) = the HELD FINALE. Lane RESOLVED: `grafana/provisioning/
  datasources/sleep-notes.yaml` IS in the sleep-tracking repo (sleep-iac has no datasource
  provisioning) → **worker-doable, NOT cross-repo** (meta-16's operator-lane flag was on incomplete
  info). Two in-repo deliverables: (1) pin `uid: sleep-notes` in that provisioning YAML; (2) fix
  `assert_graph.py._query()` to read the panel's OWN datasource uid instead of hardcoding
  `sleepdbitest` — ⚠ NUANCE: must UNIFY the uid across panel + `tests/integration/manifests/
  grafana.yaml` (currently pins `sleepdbitest`) or the gate breaks. Touches the just-stabilized
  #42/#48/#71 gate → queue LAST, watch closely, post detailed ⚖ steering when queuing.

Pipeline pattern confirmed live: WIP=1 = one RUNNING worker pod (not one open PR) → multiple PRs
review concurrently; BEHIND PRs handled by the MP-T02 updater (proven); review edge = the exporter's
ADR-093 dispatch (POLL_INTERVAL=120s), NOT the coordinate cron. FU-122 was filed then RETRACTED
(already shipped as ADR-093+FU-115 — verified via exporter dispatch log; lesson: read the mechanism
before filing a latency FU).

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
