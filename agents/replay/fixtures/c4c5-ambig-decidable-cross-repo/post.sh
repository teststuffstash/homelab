# ── observation point ── not scan code. The clause accumulates into `units` / `orphans` / `v2` as
# \n-joined strings; %b expands them so each emitted action lands as its own line and `diff` stays
# line-oriented. (`if` rather than `[ … ] && printf`: a trailing empty line would make the loop
# return 1 and take the whole composition down under `set -e`.)
#
# `RESUMABLE` is printed too, because the resumable set is the clause's own answer to "which issues
# had a strike + resumable branch" and every downstream dispatch keys off it. The set is
# NEWLINE-separated (FU-199, folded in 2026-09-20 — the dispatch loop reads it with `IFS= read -r`
# so a value carrying whitespace or a glob character can neither word-split nor expand), so each
# entry lands on its own line.
if [ -n "${resumable_branches:-}" ]; then
  printf '%b' "$resumable_branches" | while IFS= read -r l; do
    if [ -n "$l" ]; then printf 'RESUMABLE %s\n' "$l"; fi
  done
else
  printf 'RESUMABLE <empty>\n'
fi
printf '%b' "$units" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'UNIT %s\n' "$l"; fi
done
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
# Combine v2 from both passes (pass 0 saved in v2_pass0 by bridge.sh, pass 1 in v2)
for v2_src in "${v2_pass0:-}" "${v2:-}"; do
  printf '%s\n' "$v2_src" | while IFS= read -r l; do
    if [ -n "$l" ]; then printf 'V2 %s\n' "$l"; fi
  done
done
# The clause must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"