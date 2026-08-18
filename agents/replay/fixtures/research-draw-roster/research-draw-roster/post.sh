# ── observation point ── not fanout code. The block's whole PRODUCT is the roster the dispatch
# loop then rides: (slot, model) pairs and the pool version they were drawn at. Rendered here so
# the fixture pins the roster itself, not just the lines the block happened to print.
for _i in "${!ROSTER_MODELS[@]}"; do
  printf "ARM slot=%s model=%s\n" "${ROSTER_SLOTS[$_i]}" "${ROSTER_MODELS[$_i]}"
done
printf "ROSTER drawn=%s asked=%s pool_version=%s\n" "$DRAWN" "$ARMS" "$POOL_VERSION"
# The block must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"
