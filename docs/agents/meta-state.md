# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session meta-11 live 2026-07-26 (~15:30Z bootstrap; both standing watches armed):_

- **UC-1 agentic arc — OPERATOR BAR MET IN BOTH ENVIRONMENTS (2026-07-27 ~03:45Z).**
  Kind: deterministic leg CI-gated + agentic leg passed (fixture corpus). Prod: agentic
  spot-check PASSED on the real corpus — goose+deepseek-v4-flash resolved PS §1 dated
  01.07.2025 → akt_viide 115052015002, correct window + verbatim text (evidence on fleet#84;
  session export in the jail scratchpad). En route the probes caught + the loop fixed a real
  silent outage (schema skew; guards #154/#156/#157/#159 ALL merged same night) and two
  findings landed: the PROMPT CORPUS IS FIXTURE-SHAPED (AndTS is a fictional act — per-corpus
  parameterization is the #84 prerequisite, evidenced) and 🌱#160 (act resolution is
  lyhend-only; titles don't resolve — operator triage). Roll 1 LIVE: jbtlm corpus
  (sha256:75a7cfc4…, casefold+titles) + server pinned gc019e15 (newest pre-#159). VM + keys
  cleaned. REMAINING CHAIN: **rsd7z** (start-from=build on the stamping builder g60ef627,
  Monitor armed, ~5h) → release-corpus workflow_dispatch → ROLL 2 iac PR (new digest + DELETE
  the values tag pin — server current, schema gate live E2E) → verify (tools/call via jq,
  NEVER grep — the roll-1 verifier false-greened on a mangled grep pattern) → QUEUE fleet#158
  (chart /healthz probe) → then the suspended mcp-probe CronWorkflow manifest (operator lane,
  wants the parameterized prompt corpus first) + #84 harvester via the loop. #109/#160
  operator-paced.
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
