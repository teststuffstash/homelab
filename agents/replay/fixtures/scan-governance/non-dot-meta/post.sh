# ── observation point ── not scan code. Reaching this line IS the dispatch: in the shipped script
# the governance block sits above the ADR-097 footprint hold, and every path out of it that does not
# `continue` falls through to the lines that append the unit to `$iss`.
  printf 'DISPATCH #%s (%s, declared: %s)\n' "$qnum" "$repo" "$qtouches"
done <<< "$CASES"
# `orphans` is a \n-joined string; %b expands it so each reported line lands on its own line and
# `diff` stays line-oriented.
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
echo "REACHED: end"