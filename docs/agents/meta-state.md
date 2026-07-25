# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session handoff 2026-07-25 ~09:00 (operator /clear; next session = meta-coordinate skill +
FU-015 as the opening task, operator-directed — FU-015 gates the sleep specs/kind work: CI too
slow otherwise):_

- **FU-015 (CI speedup) — THE OPENING TASK.** Measured: 454s of a 610s ci job is devbox
  install. Order: custom ARC runner image (xz/gh/nix/devbox + nixcache-VIP substituter) first,
  warm-store layer second. arc-runners.yaml runs the stock image; the scale set template gains
  the image override.
- **Oracle corpus rebuild chain — run `ert-pipeline-parse-c92h9` IN FLIGHT** (at handoff:
  parse 165k/252k, ~82min elapsed, RSS flat ~350Mi — the #119 fix holds; watchers died with
  the old session, RE-ARM a phase watcher). On Succeeded: (1) `release-corpus`
  workflow_dispatch in oracle-fleet (ADR-095 path; digest-verify vs the in-cluster build);
  (2) oracle-iac values digest bump (`values/oracle-fleet-ingester.yaml` mcpServer.corpus,
  auto-merge); (3) rollout → **re-run the #82 deliverable-3 acceptance** at
  mcp.oracle.teststuff.net (PS §1 2025-07-01 → 115052015002 WITH full text now; provision
  count 168 §§ per #117) → post on #82, C6 #116/#118; (4) roll back oracle-iac#173's 4Gi
  parse limit to sane numbers (#118 acceptance leg). If the run FAILED instead: read the step
  events; the #118 lesson set (retention vs size-profile) is on the issue.
- **Sleep stack — parity DONE 2026-07-25** (GitHub apply + claim labels + docker/kata posture
  + stacks.json mirror; FU-068 sleep leg closed). Next per operator sequencing: AFTER FU-015 —
  **the sleep first goal**: specs + evidence + Grafana-in-kind **"system testing"**
  (terminology ruled: system = logic with real components in kind; e2e = target environment;
  ADR-082 shape) — see FU-095's prereq block for the multi-LLM spec-creation directive. Then
  FU-044 → FU-080 graduation → FU-095 legs (c)→(b)→(a).
- **Standing watches to re-arm on session start** (they died with the old session): the loop
  monitor (`bash agents/meta-watch-loop.sh`) + the 2h heartbeat — see the skill's bootstrap.
