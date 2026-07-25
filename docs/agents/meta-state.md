# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session handoff 2026-07-25 ~17:15Z (operator /clear; resume = /meta-coordinate):_

- **FU-015 DONE through phase 2** (warm-store image live: homelab ci 38s vs 180-210s
  baseline). Pending on OPERATOR: install homelab-renovate App on oracle-fleet/oracle-iac/
  agent-coordinator, then add them to runner-image.yaml repositories + rebuild → oracle-fleet
  warm measurement (~135s target). Renovate-track image pins = minor residual.
- **bash-logout class DONE** (ac#8 + ac#9 deploy-pin grep-sweep + homelab#33 rolled all pins;
  skip shape verified Succeeded on 2026.7.25-g141235c93140). Nothing pending.
- **Oracle corpus chain — release SHIPPED, acceptance REFUSED (3rd): #125 + #126 queued.**
  Full pipeline green (build ≈757Mi / publish ≤1Gi streaming), `ert-corpus:2026-07-12 @
  sha256:366d65f1…` released digest-verified, iac#190 rolled, ImageVolume verified. Acceptance:
  windows/citations CORRECT, rows exist — but body_text EMPTY for ALL 15,087,110 provisions
  (#125, extract-at-parse + empty-body build gate ⚖) and lookups ~42s warm at 15M rows (#126,
  build-time indexes ⚖, explain-query-plan first). Loop owns both; both re-verify on ONE
  `start-from=parse` rebuild — BOTH MERGED (fleet#127 text-capture+gate; fleet#128
  digest-at-build — the 42s was per-query re-digest of the 1.83GB corpus, not an index scan).
  Deploy gfc4b53737b1a → iac#196 bump + iac#197 pin-follow merged; **FULL rebuild `ert-pipeline-parse-cvkk8` IN FLIGHT** (at handoff ~17:15Z: 90k/252k @50.6/s,
  ETA parse ~18:10Z; RE-ARM a terminal watcher on session start) (~2h total: parse re-extract → build under the 5% empty-body floor →
  publish). On Succeeded: release-corpus dispatch → digest bump → acceptance #4 (criteria
  unchanged: PS §1 full text, <1s, 168 §§) → THEN the limits-trim leg (parse ~350Mi under
  4Gi, build ~757Mi under 6Gi) + C6 #125/#126. C6 #116/#118/#121/#123 already flipped.

- **Sleep stack**: AFTER FU-015 — the sleep first goal (specs + evidence + Grafana-in-kind
  system testing, FU-095 prereq block); then FU-044 → FU-080 graduation → FU-095 (c)→(b)→(a).
- **Standing watches re-armed this session** (die with it): meta-watch-loop.sh, 2h heartbeat,
  parse-c92h9 terminal watcher.
