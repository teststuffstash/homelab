# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session meta-11 live 2026-07-26 (~15:30Z bootstrap; both standing watches armed):_

- **UC-1 agentic arc + schema arc: CLOSED (2026-07-27 ~09:50Z).** Operator bar met kind+prod
  (TICK-LOG carries the full story). Roll 2 live: stamped corpus sha256:3e45daea… + current
  server g60ef627, no pins, #159 gate validating, replicas spread across nodes (6GB
  ImageVolume per node — rollouts ~15-20 min, size deadlines accordingly). IN THE LOOP:
  fleet#158 (chart /healthz probe) QUEUED — watch it flow (touches chart+tests only, no
  codeowner gate expected). OPERATOR-PACED NEXT: triage 🌱#160 (title resolution) + #84
  prompt-corpus parameterization (the evidenced prerequisite for scheduled prod probing);
  after #84's corpus is prod-valid, the suspended mcp-probe CronWorkflow manifest in
  oracle-iac (operator lane) + #84's gap harvester. #109 operator-paced.
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
