# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).
Convention introduced 2026-07-24 with the /meta-coordinate skill.

- **Garage LMDB out-of-space incident (2026-07-24)**: `garage-data-old` PVC deleted
  (operator-confirmed) → NEXT: verify `meta-garage-0` expansion to 10Gi completed
  (`kubectl get pvc -n garage`), garage-0 healthy, then re-run the failed CI on fleet PR #94
  (multipart fix) and resume its review → merge → pin-follow → `start-from=build` attempt 7.
- **Post-corpus arc** (gated, no action until the corpus image exists): oracle-iac#82 ghcr write
  cred → fleet#82 serve → #83 agentic probe → #84 gap sprouts.
- **FU-093**: Garage metrics (ServiceMonitor) became URGENT after this incident — the third
  capacity tier to fail dark (bulk pool math → longhorn-scratch → LMDB meta).
