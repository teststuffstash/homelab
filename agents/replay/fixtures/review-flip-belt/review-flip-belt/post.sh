# ── observation point ── not scan code. The clause accumulates into `orphans` as \n-joined
# strings; %b expands them so each emitted action lands as its own line and `diff` stays
# line-oriented. (`if` rather than `[ … ] && printf`: a trailing empty line would make the loop
# return 1 and take the whole composition down under `set -e`.)
#
# `FLIP` is printed too, because the flipped set is the clause's own answer to "which issues did
# the belt move" — an empty `units` proves no dispatch, and the flip set proves the label writes
# are the whole extent of the belt's effect.
printf 'FLIP %s\n' "${flip_done:-<empty>}"
printf '%b' "$units" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'UNIT %s\n' "$l"; fi
done
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
# The clause must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"
