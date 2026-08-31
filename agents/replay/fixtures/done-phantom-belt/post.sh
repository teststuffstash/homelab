# ── observation point ── not scan code. The belt accumulates into `orphans` as \n-joined strings;
# %b expands them so each emitted action lands as its own line and `diff` stays line-oriented.
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
# The belt must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"