# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session meta-12 ENDED 2026-07-27 ~13:10Z (operator-directed stop; watches stopped). Sleep
`*.sleep` delegation applied+verified (64c781f); sleep spec-bug queue (#39-47) + sleep-iac#22
are the LOOP's lane; FU-088 latch lifted ~12:55Z (agent-runtime#24 review dispatched — FU-096
tail chain running, see its bullet); FU-108 filed (queue gauge blind to private repos — fix
before trusting AgentQueueStalled)._

- **FU-096 chain (ACTIVE)**: operator flipped both devbox-cache ghcr packages PUBLIC (verified
  by anonymous manifest probe 13:20Z — HTTP 200 on oracle-fleet + sleep-tracking). In-pod
  measure is BLOCKED on agent-runtime#24 (seed `cp -rf` fix) reaching the agent-base image:
  #23+#24 sit CI-green with auto-merge armed but review is DEFERRED by the FU-088 subscription
  latch (5h utilization 0.82 at 11:15Z tick — level-triggered, do NOT bypass/poll). Expected:
  once a review-platform tick shows utilization <0.80 → homelab-reviewer approves ≈15 min →
  auto-merge → agent-base image build (~20 min) → deploy-pin PR into homelab images.env (like
  #49) → THEN in-pod measure → roll to remaining stack repos → kata canary → archive FU-096.
  Per-heartbeat check: `gh pr list --repo teststuffstash/agent-runtime` + newest
  review-platform tick log.

- **UC-1 agentic arc + schema arc: CLOSED (2026-07-27 ~09:50Z).** Operator bar met kind+prod
  (TICK-LOG carries the full story). Roll 2 live: stamped corpus sha256:3e45daea… + current
  server g60ef627, no pins, #159 gate validating, replicas spread across nodes (6GB
  ImageVolume per node — rollouts ~15-20 min, size deadlines accordingly). #158 DELIVERED (#163
  merged; /healthz readiness verified LIVE in prod, 2/2 Ready) — ALL outage guards enforced. OPERATOR-PACED NEXT: triage 🌱#160 (title resolution) + #84
  prompt-corpus parameterization (the evidenced prerequisite for scheduled prod probing);
  after #84's corpus is prod-valid, the suspended mcp-probe CronWorkflow manifest in
  oracle-iac (operator lane) + #84's gap harvester. #109 operator-paced.
- **SLEEP ROLLOUT — FIRST UNSUPERVISED CYCLES OF THE NEW MACHINERY (role-build session,
  2026-07-27 ~15:30Z).** The sleep coordinator re-enabled (sleep-iac#27) over a queue that
  exercises everything built today: sleep-tracking#48 (system-test gate, lg, chart/.github
  authorized) dispatches FIRST → spec bugs #39-41/#44-47 (xs-sm; #42/#43 dep-held on #48) →
  sleep-iac#22/#25 through the NEW -iac dispatch class (sleep-iac is a fixer since FU-106).
  WATCH posture, not drive: every new clause pays a lesson on its first live run — C6
  merged-closeout+harvest fires on the first merge; arbitrate/ci-red-stale/infra-enrich on
  their triggers; the responder v2 + SLO teeth + deterministic revert run underneath. Sweep
  the platform queue (homelab 🚨 issues) FIRST and run `agents/meta-alert-crosscheck.sh` each
  heartbeat (it caught the multi-alert stdin bug on run 1). Known residuals: FU-095 legs
  a/b/c (evidence program; fusion canary queued as the audit-class candidate), FU-058 first
  hand-fire (wants idle fixer queue + headroom), FU-090 legs b/c, FU-086 compound + cron
  relax, FU-102 blocked on the UC-1 corpus (other lane). Remove this bullet when the first
  full cycle (issue→merge→C6→deploy) is observed clean.
- **⚠ CONCURRENT SESSION (operator, 2026-07-26 ~18:45Z)**: another session is rewriting
  agentstack under FU-080 — agentstack-shaped errors (loop SA/broker/CronWorkflow machinery,
  odd coordinate ticks) are THAT session's lane: observe, don't clear/fix from here; flag to
  the operator only if it looks like unnoticed real damage. Remove this bullet when FU-080
  lands.
- **retro-session CronWorkflow** (FU-058) deployed SUSPENDED — first hand-fire wants: idle
  fixer queue, an ephemeral capped OpenRouterKey (param `retroKeySecret`), subscription
  headroom for cell A. Cross-review legs manual (`agents/retro-session.sh --review`).
- **Sleep stack**: unchanged — sleep first goal (specs + evidence + Grafana-in-kind system
  testing, FU-095 prereq block); then FU-044 → FU-080 graduation → FU-095 (c)→(b)→(a).
- **Standing watches (die with the session — re-arm per the skill)**: meta-watch-loop.sh,
  2h heartbeat, plus chain watchers (this session: jbtlm run monitor). Probe lessons live in
  the skill + here: zsh no-word-split hits inline Monitors AND inline Bash — put probes in
  bash script files and DRY-RUN the exact probe under the same interpreter before arming
  (meta-11 burned two monitor generations on this + an invalid jsonpath together); kubectl
  jsonpath canNOT range Argo's .status.nodes (a map) — probe step pods via the
  `workflows.argoproj.io/workflow=<name>` label instead; probe-the-pod-not-the-deploy,
  orphan monitors from dead sessions duplicate events — stop on sight; `mergeStateStatus:
  BLOCKED` is the NORMAL checks-pending state, not stuck (meta-11 false alarm — only DIRTY /
  closed-unmerged / deadline-passed are alarms). Noted benign single: coordinator dispatch
  pod-name (HHMMSS) collided with a <24h-old terminal same-name pod → one tick Error,
  level-trigger re-fired clean; file a class fix only if it recurs.
