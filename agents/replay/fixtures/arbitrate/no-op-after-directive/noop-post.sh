# ── observation point ── not scan code. The clause accumulates into `units` / `orphans` / `items`
# as \n-joined strings; %b expands them so each lands as its own line in the action stream.
for _acc in units orphans items; do
  printf '%b' "${!_acc}" | while IFS= read -r l; do
    if [ -n "$l" ]; then printf '%s %s\n' "$(printf '%s' "$_acc" | tr 'a-z' 'A-Z')" "$l"; fi
  done
done
# The clause must run to completion under `set -euo pipefail`, not merely produce the right lines.
echo "REACHED: end"
