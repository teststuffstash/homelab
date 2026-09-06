# ── observation point ── not scan code. `orphans` is a \n-joined string; %b expands it so each
# reported line lands on its own line and `diff` stays line-oriented. `busy_fps` is the newline
# list the ADR-097 hold reads — printed with its issue's position so the twin rows are readable.
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
printf '%s' "$busy_fps" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'FOOTPRINT %s\n' "$l"; fi
done
echo "REACHED: end"
