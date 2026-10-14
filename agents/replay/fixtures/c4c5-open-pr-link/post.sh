# ── observation point ── not scan code. The clause accumulates into `units` / `orphans` / `v2` as
# \n-joined strings; %b expands them so each emitted action lands as its own line and `diff` stays
# line-oriented. (`if` rather than `[ … ] && printf`: a trailing empty line would make the loop
# return 1 and take the whole composition down under `set -e`.)
#
# The UNIT line is the assertion the ruling turns on: a bare mention must EMIT it, a strong link
# must not. `V2` is printed beside it because the report line is the same predicate's second
# derivation — a row that emitted the unit but lost the report would be half-green.
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
