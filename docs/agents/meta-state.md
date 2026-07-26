# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Updated 2026-07-26 ~01:15Z (meta-10 cont., same session as the 07-25 resume):_

- **Oracle corpus chain — REBUILD SUCCEEDED, acceptance #4 IS THE NEXT STEP.** cvkk8 went
  3/3 (parse 252,354 members; build 4.8h: 16,437,964 provisions, empty-body ratio 0.018 vs
  0.05 floor PASSED, corpus 6.0GB, digest baked; publish clean). Released
  `ert-corpus:2026-07-12 @ sha256:4d07f3e78749…` digest-verified; iac#205 bump auto-merging →
  mcp pods roll the new ImageVolume (watcher armed). **On rolled pods: run acceptance #4**
  (criteria unchanged: PS §1 full text, <1s, 168 §§; prior refusals: r1 transport, r2 42s+keys,
  r3 empty body_text). THEN: limits-trim leg (parse ~350Mi under 4Gi; build peaked ~785Mi under
  6Gi — trim both) + C6 flips for #125/#126. Filed en route: fleet#135 (build emits no progress
  events for the whole populate phase — regression vs pre-#127; loop owns it).
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
