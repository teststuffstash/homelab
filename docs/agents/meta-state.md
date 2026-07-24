# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).
Convention introduced 2026-07-24 with the /meta-coordinate skill.

- **Garage LMDB incident RESOLVED 2026-07-24**: meta-garage-0 expanded 1Gi→10Gi (old volume's
  full deletion chain: mig-copy pod → PVC → Retained PV → Longhorn CR; meta replicas rotated to
  thinkcentre + wk-metal-01 — the general pool is over-promised, see FU-093). → NEXT: fleet PR
  #94 CI retriggered (empty commit) as the Garage write test → review → merge → pin-follow →
  `start-from=build` attempt 7.
- **Post-corpus arc** (gated, no action until the corpus image exists): oracle-iac#82 ghcr write
  cred → fleet#82 serve → #83 agentic probe → #84 gap sprouts.
- **FU-093**: Garage metrics (ServiceMonitor) became URGENT after this incident — the third
  capacity tier to fail dark (bulk pool math → longhorn-scratch → LMDB meta).
