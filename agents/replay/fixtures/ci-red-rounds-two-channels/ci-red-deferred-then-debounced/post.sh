# ── observation point ── not scan code. The clause accumulates into `orphans` as a \n-joined
# string; %b expands it so each emitted action lands as its own line in the action stream and
# `diff` stays line-oriented.
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
# The clause must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"