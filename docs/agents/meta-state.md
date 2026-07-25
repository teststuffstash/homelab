# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Updated 2026-07-25 ~07:50Z (meta-10 session):_

- **FU-015 phase 1 DONE fleet-wide** (image + scale-set pin; all 6 repos slimmed+merged;
  homelab 70s, oracle-fleet 437s — tax moved into per-job closure realization). Remaining:
  phase 2 warm-store layer (the 135s target), agent-coordinator ci slim, renovate pins.
- **bash-logout class DONE** (ac#8 + ac#9 deploy-pin grep-sweep + homelab#33 rolled all pins;
  skip shape verified Succeeded on 2026.7.25-g141235c93140). Nothing pending.
- **Oracle corpus rebuild — parse CLEAN, build OOMKilled at 3Gi** (post-#116 full-subtree
  corpus; parse artifacts reusable). **iac#181 (build 3Gi→6Gi) auto-merge armed; background
  chain: merge → template sync → submit `start-from=build` → watch.** On build+publish
  Succeeded: (1) `release-corpus` dispatch in oracle-fleet (digest-verify vs in-cluster);
  (2) oracle-iac values digest bump (`values/oracle-fleet-ingester.yaml` mcpServer.corpus,
  auto-merge); (3) rollout → re-run #82 deliverable-3 acceptance at mcp.oracle.teststuff.net
  (PS §1 2025-07-01 → 115052015002 WITH full text; 168 §§ per #117) → post on #82, C6
  #116/#118; (4) THEN trim parse 4Gi AND build 6Gi to observed+margin (rollback leg, #118).
  If build OOMs at 6Gi: retention bug, file to the loop (parse precedent comment in the yaml).
- **Sleep stack**: AFTER FU-015 — the sleep first goal (specs + evidence + Grafana-in-kind
  system testing, FU-095 prereq block); then FU-044 → FU-080 graduation → FU-095 (c)→(b)→(a).
- **Standing watches re-armed this session** (die with it): meta-watch-loop.sh, 2h heartbeat,
  parse-c92h9 terminal watcher.
