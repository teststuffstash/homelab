# ── observation point ── not scan code. The clause accumulates into `units` / `orphans` / `v2` as
# \n-joined strings; %b expands them so each emitted action lands as its own line and `diff` stays
# line-oriented. (`if` rather than `[ … ] && printf`: a trailing empty line would make the loop
# return 1 and take the whole composition down under `set -e`.)
#
# `INFEAS` is printed too, because the parked set is the clause's own answer to "which issues did
# the marker latch on" and every downstream exclusion keys off it — an empty `units` line proves
# suppression, this proves it was suppressed for the RIGHT reason.
printf 'INFEAS %s\n' "${infeas_done:-<empty>}"
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
