# ── bridge ── the two variables retro-argo.yaml's retro-cell sets immediately above the block:
# the ride-log path (also the template's output-artifact path) and the cell it was dispatched as.
# $PWD is the fixture directory — run.sh cds into it — so the committed log stands in for the one
# `tee` wrote in the pod.
RIDE_LOG="$PWD/ride.log"
CELL="goose:deepseek/deepseek-v4-pro"
