# ── observation point ── not cell code. In retro-argo.yaml the block is the LAST thing the
# retro-cell container runs, so continuing past it is exactly "the step exits 0 and the DAG marks
# this cell Succeeded". Its ABSENCE from the action stream is the assertion.
echo "REACHED: cell exits 0 — the DAG marks this cell Succeeded"
