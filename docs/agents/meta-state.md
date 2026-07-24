# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).
Convention introduced 2026-07-24 with the /meta-coordinate skill.

- **CORPUS RELEASED 2026-07-24 15:37**: `ert-corpus:2026-07-12@sha256:275471db…` pullable,
  digest-verified (ADR-095 Actions release path; 5 dispatch iterations: latest.json schema →
  untar chown → trust policy → preserve-digests). fleet#82 (serve) QUEUED. Release settled →
  tree-move + FU-015 both unblocked.
- **specs/docs tree move (operator-approved 2026-07-24)**: PENDING until the corpus release
  settles → then a spec-hygiene PR in oracle-fleet: conventions.md + TRACKS.md + README.md →
  docs/process/ (CODEOWNERS extended to the new path IN THE SAME PR — the gate travels with the
  files), domain.md → docs/, glossary STAYS in specs/ (it is contract). Reviewer rubric updated
  for the new layout.
- **FU-015 execution (operator-approved direction 2026-07-24)**: AFTER the corpus release
  settles — custom ARC runner image (xz/gh/nix/devbox + nixcache substituter, then warm-store
  layer); measured: 454s/610s ci job is devbox install; target ~135s.
- **Post-corpus arc** (gated, no action until the corpus image exists): oracle-iac#82 ghcr write
  cred → fleet#82 serve → #83 agentic probe → #84 gap sprouts.
- **FU-093**: Garage metrics (ServiceMonitor) became URGENT after this incident — the third
  capacity tier to fail dark (bulk pool math → longhorn-scratch → LMDB meta).
