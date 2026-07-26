# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Updated 2026-07-26 ~01:15Z (meta-10 cont., same session as the 07-25 resume):_

- **Oracle corpus chain — ✅ ACCEPTANCE #4 PASSED 2026-07-26 ~01:30Z** (PS §1 full text, p50
  21ms, 168/168 §§, date-travel + normalized keys correct; TICK-LOG has the arc). C6
  #125/#126 flipped. Acceptance anomalies filed+queued: fleet#136 (casefold) #137 (TsÜS
  coverage gap) #138 (titles) #139 (latency histogram); #135 (silent build) queued, its ride
  running. **Remaining leg: limits-trim** — parse peaked ~350Mi (limit 4Gi), build ~785Mi
  (limit 6Gi): trim via oracle-iac workflow-ert yaml PR when convenient.
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
