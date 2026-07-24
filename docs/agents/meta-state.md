# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done (TICK-LOG carries history — this file carries only what a fresh session must pick up).
Convention introduced 2026-07-24 with the /meta-coordinate skill.

- **CORPUS MILESTONE 2026-07-24**: attempt 8 (`ert-pipeline-build-9phj5`) ran
  build→publish clean — image `ert-corpus:2026-07-12` digest `sha256:275471db…`, 215MB OCI
  archive at `image/2026-07-12/…/corpus-image.oci.tar`, `push_skipped` by design. → NEXT: the
  ghcr WRITE cred (oracle-iac#82 follow-up) → `PUBLISH_PUSH=1` → image pullable → fleet#82
  (serve) unblocks.
- **Post-corpus arc** (gated, no action until the corpus image exists): oracle-iac#82 ghcr write
  cred → fleet#82 serve → #83 agentic probe → #84 gap sprouts.
- **FU-093**: Garage metrics (ServiceMonitor) became URGENT after this incident — the third
  capacity tier to fail dark (bulk pool math → longhorn-scratch → LMDB meta).
