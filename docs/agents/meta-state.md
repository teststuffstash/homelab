# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Updated 2026-07-26 ~01:15Z (meta-10 cont., same session as the 07-25 resume):_

- **Oracle corpus chain — ✅ ACCEPTANCE #4 PASSED 2026-07-26 ~01:30Z**, and ALL FIVE follow-on
  fixes (fleet#135 silent build, #136 casefold, #137→#143 coverage_end, #138→#144 titles,
  #139→#142 histogram) merged through ride→review→codeowner-gate by ~05:45Z; C6 flipped on
  all. Codeowner gate rejected #140 r1 on fabricated cadence arithmetic (fixed r2 with a
  time-throttle — better than asked). **Latent until the next pipeline run**: the parse-side
  fixes (#144 titles, #136 casefold, #140 populate heartbeat) only enter the corpus on the
  next build+release cycle — verify titles/casefold/heartbeat on that run, then acceptance
  criteria can grow (title in citation). **Remaining leg: limits-trim** — parse peaked
  ~350Mi (limit 4Gi), build ~785Mi (limit 6Gi): trim via oracle-iac workflow-ert yaml PR.
- **FU-089 — one flip left: `GIT_TOKEN_REQUIRE_AUTH=1` on the openrouter-proxy Deployment,
  ONLY at an idle window** (no agent-session pods running — the helper has no retry; a fetch
  during the proxy restart kills a ride). Evidence complete 01:12Z: a real ride's fetches
  served WITH TokenReview (SA bearer works); claude rides joined the broker path (6c3fd88,
  after the issue-135 tokenless-clone incident). After the flip: drop the standing-Secret
  fallback lines in agent-session.sh (they reference the deleted Secret).
- **F1 / fleet#134 — waiting on OPERATOR: homelab-agents App needs Workflows R/W** (UI +
  install approval). Then: add `workflows: write` to the `agent-git-<repo>-gen` blocks in the
  agentstack Composition, and add `agent/queued` to fleet#134.
- **FU-015**: complete; residual = renovate-tracked ARG pins (live) + observe one scheduled
  Monday cycle (lock bump 03:00 → image cron 06:00 → self-bump PR → roll), then archive.
- **retro-session CronWorkflow** (FU-058) deployed SUSPENDED — first hand-fire needs: idle
  fixer queue, an ephemeral capped OpenRouterKey (param `retroKeySecret`), subscription
  headroom for cell A. Cross-review legs manual (retro-session.sh --review).
- **Sleep stack**: unchanged — sleep first goal (specs + evidence + Grafana-in-kind system
  testing, FU-095 prereq block); then FU-044 → FU-080 graduation → FU-095 (c)→(b)→(a).
- **Standing watches (die with the session)**: meta-watch-loop.sh, 2h heartbeat, corpus-roll
  watcher. Probe lessons this session: inline Monitor scripts run under ZSH (no word-split —
  use functions, keep stderr visible); orphan monitors from dead sessions duplicate events —
  stop them on sight (4 killed this session).
