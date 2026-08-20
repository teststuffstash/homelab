# ── observation point ── not scan code. `orphans` is a \n-joined string; %b expands it so each
# reported line lands on its own line and `diff` stays line-oriented.
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
echo "REACHED: end"