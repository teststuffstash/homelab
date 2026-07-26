# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session meta-11 live 2026-07-26 (~15:30Z bootstrap; both standing watches armed):_

- **UC-1 agentic arc (operator directive: agent drives UC-1 — kind, then prod)**: fleet#83
  QUEUED 2026-07-26 with the queue-time shape ⚖ pre-decided in the issue (kind serve leg —
  fixture-corpus-through-real-publish for CI, real-digest override for manual; deterministic
  MCP-client UC-1 script into `devbox run e2e`; agentic `probe-e2e` task, never
  merge-blocking; Allure + UC-1-page evidence — the specs diff rides the codeowner gate,
  doubling as the operator prompt-corpus pass). NEXT: coordinator claim + worker ride
  (deadline ~30 min from queue, loop watch armed) → worker PR → codeowner gate → merge →
  **meta-coordinator runs the PROD leg** (real agent ride at mcp.oracle.teststuff.net;
  suspended `mcp-probe` CronWorkflow manifest in oracle-iac = operator lane). #84 (gap
  harvester → 🌱 sprouts) stays behind #83; #109 operator-paced. Prod baseline this session:
  initialize 200 in 0.6s.
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
  the skill + here: zsh no-word-split in inline Monitors, probe-the-pod-not-the-deploy,
  orphan monitors from dead sessions duplicate events — stop on sight; `mergeStateStatus:
  BLOCKED` is the NORMAL checks-pending state, not stuck (meta-11 false alarm — only DIRTY /
  closed-unmerged / deadline-passed are alarms). Noted benign single: coordinator dispatch
  pod-name (HHMMSS) collided with a <24h-old terminal same-name pod → one tick Error,
  level-trigger re-fired clean; file a class fix only if it recurs.
