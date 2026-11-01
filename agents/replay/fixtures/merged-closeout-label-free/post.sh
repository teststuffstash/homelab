# ── observation point ── not scan code. The C6 clause accumulates into `units`, `items`, and
# `orphans` as \n-joined strings; %b expands them so each emitted action lands as its own line
# and `diff` stays line-oriented.
printf '%b' "$units" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'UNIT %s\n' "$l"; fi
done
printf '%b' "$items" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ITEM %s\n' "$l"; fi
done
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
# The block must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"