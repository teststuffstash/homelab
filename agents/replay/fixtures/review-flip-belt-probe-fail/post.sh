# ── observation point ── identical to the sibling fixture's: the flip set, the units, the
# orphans, then REACHED. `FLIP <empty>` proves the hold wrote nothing.
printf 'FLIP %s\n' "${flip_done:-<empty>}"
printf '%b' "$units" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'UNIT %s\n' "$l"; fi
done
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
# The clause must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"
