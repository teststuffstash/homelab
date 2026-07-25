# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).

_Session resumed 2026-07-25 ~17:20Z via /meta-coordinate (fresh session, meta-10 cont.):_

- **FU-015 COMPLETE 2026-07-25** (App installed by operator; oracle trio warmed in
  `2026.7.25-g171a704c735d`; oracle-fleet ci warm = 297s, decomposition in the FU entry;
  devbox-update matrix extended). Only residual: renovate-track the image pins.
- **Oracle corpus chain — #125+#126 merged, FULL rebuild `ert-pipeline-parse-cvkk8` IN
  FLIGHT** (at 17:15Z: 95k/252k @~47/s, parse ETA ~18:15Z; then build under the 5% empty-body
  floor at 6Gi → publish; terminal watcher armed). On Succeeded: release-corpus dispatch →
  digest bump → acceptance #4 (criteria unchanged: PS §1 full text, <1s, 168 §§) → THEN the
  limits-trim leg (parse ~350Mi under 4Gi, build ~757Mi under 6Gi) + C6 #125/#126
  (both CLOSED, still `agent/in-progress` — flip after acceptance passes). C6
  #116/#118/#121/#123 already flipped. Context: the 42s was per-query re-digest of the 1.83GB
  corpus (fleet#128 digest-at-build); body_text was empty for all 15M rows (fleet#127
  text-capture+gate). Deploy gfc4b53737b1a via iac#196+#197.

- **Sleep stack**: AFTER FU-015 — the sleep first goal (specs + evidence + Grafana-in-kind
  system testing, FU-095 prereq block); then FU-044 → FU-080 graduation → FU-095 (c)→(b)→(a).
- **Standing watches re-armed this session** (die with it): meta-watch-loop.sh, 2h heartbeat,
  cvkk8 terminal watcher (v3 + arm-time self-test). Probe lesson: inline Monitor scripts run
  under ZSH — `$K` command-in-a-var does NOT word-split (`cmd --flag` execs as one filename);
  use a shell function, and keep probe stderr visible (v1's 2>/dev/null hid exactly this).
- Board hygiene done on resume: two `wip(salvage)` fleet branches deleted (125741 = fix.yaml
  scratch; 145644 = the retro report already harvested as r2-nemotron-super-free-2 — its
  self-declared "gemini-2.5-pro" header was a wrong-header ride).
