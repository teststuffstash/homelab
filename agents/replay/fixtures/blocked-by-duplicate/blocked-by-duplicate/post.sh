#!/bin/bash
# ── post ── verify the deps-resolve block handled the DUPLICATE blocker correctly.
# The canonical issue is OPEN → the blocker is still blocking.

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