#!/bin/bash
# ── post ── verify the deps-resolve block handled the DUPLICATE blocker correctly
# when the canonical state read fails. The blocker must be held conservatively
# with a loud orphans line, and the scan pass must continue (RC 0, REACHED: end).

printf '%b\n' "$blocked" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'BLOCKED %s\n' "$l"; fi
done
printf '%b\n' "$stale" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'STALE %s\n' "$l"; fi
done
printf '%b\n' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
echo "REACHED: end"