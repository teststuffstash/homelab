# ── observation point ── not scan code. The clause accumulates into `units` / `orphans` / `v2` as
# \n-joined strings; %b expands them so each emitted action lands as its own line and `diff` stays
# line-oriented. (`if` rather than `[ … ] && printf`: a trailing empty line would make the loop
# return 1 and take the whole composition down under `set -e`.)
#
# `RESUMABLE` is printed too, because the resumable set is the clause's own answer to "which issues
# had a strike + resumable branch" and every downstream dispatch keys off it.
printf 'RESUMABLE %s\n' "${resumable_branches:-<empty>}"
# ITEM_CLASS_ROWS: the per-pass accumulator. The no-strike world must verify that strike-held
# rows are pushed for undecidable C4/C5 goal children (FU-199 / #1240).
printf '%b' "$ITEM_CLASS_ROWS" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'CLASS %s\n' "$l"; fi
done
printf '%b' "$units" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'UNIT %s\n' "$l"; fi
done
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
printf '%s\n' "$v2" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'V2 %s\n' "$l"; fi
done
# The clause must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"