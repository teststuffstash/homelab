# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session handoff 2026-07-26 ~17:00Z (operator /clear; resume = /meta-coordinate):_

- **NEXT SESSION GOAL (operator directive): build oracle-fleet until an AGENT has driven the
  new MCP server and UC-1 WORKS — first in kind, then in the prod homelab cluster.**
  - Anchor issue: **fleet#83** (agentic MCP probe — harness-driven UC-1 prompts against the
    served corpus; track/server, NOT yet queued) and **#84** behind it (probe gaps → 🌱
    triage sprouts, the FU-090 surface). #109 (specs cleanup) stays operator-paced.
  - Shape to decide at queue time (⚖ pre-decide in the issue): the KIND leg extends the
    repo's `devbox run e2e` system-test gate — mcp server + corpus in kind, a DETERMINISTIC
    MCP-client UC-1 script there (no LLM spend in CI); the PROD leg is a real agent ride
    (retro-session/agent-session machinery, goose or claude cell) pointed at
    `https://mcp.oracle.teststuff.net` with UC-1 prompts, evidence harvested per #84's
    gap-report shape. Kind + ImageVolume: verified live on the CLUSTER (k8s 1.36 default
    gates); verify the kind node image supports it before assuming (fleet#106 notes).
  - Acceptance r4 (2026-07-26) is the baseline: transport + corpus PASS (PS §1 full text,
    p50 21ms, 168 §§, date-travel, normalized keys); the agent probe is the NEXT bar.
  - Relevant fresh platform state: workers CAN edit `.github/workflows/ci.yaml` under
    `track/chassis` (#145 carve-out + the App's workflows:write — live); FU-089 enforced
    (SA-bearer mandatory on /git-token); corpus parse-side fixes (#144 titles, #141
    casefold, #140 populate heartbeat) are LATENT until the next pipeline run — that run
    also re-verifies them.

- **Corpus pipeline limits-trim leg** (from the acceptance chain): parse peaked ~350Mi
  (limit 4Gi), build ~785Mi (limit 6Gi) — trim via oracle-iac workflow-ert yaml PR.
- **retro-session CronWorkflow** (FU-058) deployed SUSPENDED — first hand-fire wants: idle
  fixer queue, an ephemeral capped OpenRouterKey (param `retroKeySecret`), subscription
  headroom for cell A. Cross-review legs manual (`agents/retro-session.sh --review`).
- **FU-015**: observe Monday's automated cycle (lock bump 03:00 → image cron 06:00 →
  self-bump PR → roll; the self-bump is now fresh-master-rebased after the 2026-07-26
  workflow-file-check rejection) — then archive.
- **Sleep stack**: unchanged — sleep first goal (specs + evidence + Grafana-in-kind system
  testing, FU-095 prereq block); then FU-044 → FU-080 graduation → FU-095 (c)→(b)→(a).
- **New standing surfaces (2026-07-26, all verified live)**: `apps.teststuff.net/apps` —
  GitHub Apps declared-vs-live (HTML; /apps.md raw; SERVICES.md row); drift belt + rate-limit
  probes cover all six key-reachable Apps (drift 0 across the board); `github-app-bootstrap.sh
  <slug>` is the ONE App script. FU-084 + FU-098 archived complete.
- **Standing watches (die with the session — re-arm per the skill)**: meta-watch-loop.sh,
  2h heartbeat, plus any chain watchers the session needs. Probe lessons live in the skill +
  this file's history: zsh no-word-split in inline Monitors, probe-the-pod-not-the-deploy,
  orphan monitors from dead sessions duplicate events (5 killed across meta-10) — stop them
  on sight.
