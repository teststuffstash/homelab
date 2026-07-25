# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Updated 2026-07-25 ~07:50Z (meta-10 session):_

- **FU-015 phase 1 LIVE** (image + scale-set pin + homelab ci slimmed, 70s green). In flight:
  slimming PRs oracle-fleet#120, oracle-iac#178, sleep-tracking#28, sleep-iac#20,
  openrouter-operator#7 — all auto-merge armed, each verifies on its own ci. Next: confirm
  merges + capture oracle-fleet post-fix ci timing (target ~135s); then agent-coordinator ci
  slim (after its #8), phase 2 warm-store layer later.
- **bash-logout class fix — agent-coordinator#8 auto-merge armed** (rm bash logout files;
  root cause of Failed review-* skips: login-shell exit runs clear_console, no tty → rc 1
  under set -e; only skip paths affected — normal path execs away). On merge: build-image CI
  → new tag → deploy.yaml opens homelab pin-bump PR (images.env + argo yamls) → after ArgoCD
  sync, re-run the skiptest repro on the NEW tag, expect main Succeeded.
- **Oracle corpus rebuild chain — `ert-pipeline-parse-c92h9` IN FLIGHT** (healthy: 215k/252k
  @33/s at 07:33Z, ETA ~07:52Z; #119 fix holds). On Succeeded: (1) `release-corpus`
  workflow_dispatch in oracle-fleet (digest-verify vs in-cluster); (2) oracle-iac values
  digest bump (`values/oracle-fleet-ingester.yaml` mcpServer.corpus, auto-merge);
  (3) rollout → re-run #82 deliverable-3 acceptance at mcp.oracle.teststuff.net (PS §1
  2025-07-01 → 115052015002 WITH full text; 168 §§ per #117) → post on #82, C6 #116/#118;
  (4) roll back oracle-iac#173's 4Gi parse limit (#118 acceptance leg). If FAILED: read step
  events; #118 lesson set on the issue.
- **Sleep stack**: AFTER FU-015 — the sleep first goal (specs + evidence + Grafana-in-kind
  system testing, FU-095 prereq block); then FU-044 → FU-080 graduation → FU-095 (c)→(b)→(a).
- **Standing watches re-armed this session** (die with it): meta-watch-loop.sh, 2h heartbeat,
  parse-c92h9 terminal watcher.
