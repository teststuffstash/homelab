# ── observation point ── not scan code. The clause accumulates into `units` / `orphans` as
# \n-joined strings; %b expands them so each emitted action lands as its own line in the action
# stream and `diff` stays line-oriented.
#
# `if` rather than `[ ... ] && printf`: the loop's exit status is its last command's, so a trailing
# empty line would return 1 and take the whole composition down under `set -e` — a harness bug that
# would read as a clause failure.
printf '%b' "$units" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'UNIT %s\n' "$l"; fi
done
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
# The clause must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"