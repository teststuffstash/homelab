# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session meta-11 live 2026-07-26 (~15:30Z bootstrap; both standing watches armed):_

- **UC-1 agentic arc (operator directive: agent drives UC-1 — kind, then prod)**: #83
  DELIVERED same-day — fleet#146 merged through the codeowner gate (gate comment = the
  operator prompt-corpus pass; concern noted on #84: two meta-prompt cases need per-corpus
  named provisions), #147 (evidence-link depth) merged. **fleet#148 IN FLIGHT** (watcher
  armed, 45-min deadline): CI e2e job now runs `scripts/e2e-serve.sh` — the serve leg's
  FIRST live exercise (the worker couldn't edit ci.yaml under track/server; operator wired
  uv 0.11.28 user-local + skopeo from the runner VM image + evidence merge/upload in
  allure-publish.sh). skopeo: live-converged on ci-runner-01 (1.9.3 via qm guest exec) +
  declared in cloud-init tftpl, tofu-applied (snippet only), homelab eb40c8e. NEXT after
  #148 green: **kind agentic leg** — `devbox run probe-e2e` needs docker (NOT the jail):
  run as an agent ride (dind) or on the VM runner with OPENROUTER key + PROBE_MODEL from
  registry pins; THEN the prod leg (MCP_ENDPOINT=https://mcp.oracle.teststuff.net/mcp real
  ride + suspended `mcp-probe` CronWorkflow in oracle-iac). #84 (gap harvester) next in
  queue order; #109 operator-paced. Prod baseline: initialize 200 in 0.6s.
- **Pipeline verification run `ert-pipeline-parse-jbtlm`** (submitted ~15:30Z, Monitor armed):
  re-verifies latent fleet#140/#141/#143/#144 + first exercise of the #140 build heartbeat +
  first run on the TRIMMED limits (iac#223 MERGED: pins → 2026.7.26-g52e1d41d74d0, parse
  1536Mi, build 2Gi — from cvkk8 peaks 350Mi/785Mi; OOM below = retention regression).
  Expect parse ~3h, build ~5h. NEXT on Succeeded: check build_progress heartbeat events
  fired, then decide the corpus release/digest-roll (titles now captured → a new release +
  iac ImageVolume roll is worthwhile); on Failed: read the step's own JSON events + traceback.
- **retro-session CronWorkflow** (FU-058) deployed SUSPENDED — first hand-fire wants: idle
  fixer queue, an ephemeral capped OpenRouterKey (param `retroKeySecret`), subscription
  headroom for cell A. Cross-review legs manual (`agents/retro-session.sh --review`).
- **FU-015**: observe Monday 2026-07-27's automated cycle (lock bump 03:00 → image cron
  06:00 → self-bump PR → roll; the self-bump is fresh-master-rebased) — then archive.
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
