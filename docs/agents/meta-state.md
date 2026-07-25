# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Updated 2026-07-25 ~07:50Z (meta-10 session):_

- **FU-015 DONE through phase 2** (warm-store image live: homelab ci 38s vs 180-210s
  baseline). Pending on OPERATOR: install homelab-renovate App on oracle-fleet/oracle-iac/
  agent-coordinator, then add them to runner-image.yaml repositories + rebuild → oracle-fleet
  warm measurement (~135s target). Renovate-track image pins = minor residual.
- **bash-logout class DONE** (ac#8 + ac#9 deploy-pin grep-sweep + homelab#33 rolled all pins;
  skip shape verified Succeeded on 2026.7.25-g141235c93140). Nothing pending.
- **Oracle corpus rebuild — BUILD LEG DONE, publish = fleet#123 (queued)**: #121 fix
  (fleet#122, codeowner-gated + merged) verified on run rr65f — bound HELD (peak ≈757Mi,
  full corpus: 15,087,110 provisions, corpus.sqlite 1.83GB in Garage, digest 1dd2b7ef…);
  publish then OOMKilled at 1Gi (corpus 8.5× bigger; streaming publish = #123, ⚖ stream
  don't size-up, third leg of the retention doctrine). Loop owns #123; on its fix merge:
  deploy bump (iac, auto) → pin-follow workflow-ert refs → sync → `start-from=build`
  verification run (publish completes ≤1Gi). Limits-trim data: parse ~350Mi under 4Gi,
  build ~757Mi under 6Gi. On build+publish Succeeded: (1) `release-corpus` dispatch in oracle-fleet (digest-verify vs in-cluster);
  (2) oracle-iac values digest bump (`values/oracle-fleet-ingester.yaml` mcpServer.corpus,
  auto-merge); (3) rollout → re-run #82 deliverable-3 acceptance at mcp.oracle.teststuff.net
  (PS §1 2025-07-01 → 115052015002 WITH full text; 168 §§ per #117) → post on #82, C6
  #116/#118; (4) THEN trim parse 4Gi AND build 6Gi to observed+margin (rollback leg, #118).
  If build OOMs at 6Gi: retention bug, file to the loop (parse precedent comment in the yaml).
- **Sleep stack**: AFTER FU-015 — the sleep first goal (specs + evidence + Grafana-in-kind
  system testing, FU-095 prereq block); then FU-044 → FU-080 graduation → FU-095 (c)→(b)→(a).
- **Standing watches re-armed this session** (die with it): meta-watch-loop.sh, 2h heartbeat,
  parse-c92h9 terminal watcher.
