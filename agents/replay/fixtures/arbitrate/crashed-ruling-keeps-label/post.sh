# ── observation point ── not scan code. The belt accumulates into `units` / `orphans` as
# \n-joined strings; %b expands them so each emitted action lands as its own line.
printf '%b' "$units" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'UNIT %s\n' "$l"; fi
done
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
echo "REACHED: end"
