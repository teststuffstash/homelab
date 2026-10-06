# ── observation point ── not scan code. The FU-143 goal-child block accumulates into `c6g` (the
# closeout set, `number|base` \n-joined), `c6g_nums` (the same numbers, space-joined) and `orphans`
# as \n-joined strings; %b expands them so each emitted action lands as its own line and `diff`
# stays line-oriented. `c6g` is the block's own answer to "which goal children are finished work
# the keyword could not close" — the C6 clause downstream turns each into a merged-closeout unit.
printf 'C6G [%s]\n' "$(printf '%b' "${c6g:-}" | tr '\n' ',' | sed 's/,$//')"
printf 'C6G_NUMS [%s]\n' "$(printf '%s' "${c6g_nums:-}" | sed 's/[[:space:]]*$//')"
printf '%b' "${orphans:-}" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
# The block must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"
