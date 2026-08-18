# ── observation point ── not scan code. Reaching this line IS the dispatch: in the shipped script
# the session-belt-queued block sits above the TRACKS rule-1 hold, and every path out of it that
# does not `continue` falls through to the queued-dispatch unit emission.
  printf 'DISPATCH #%s (%s, %s)\n' "$qnum" "$repo" "$qtitle"
done <<< "$CASES"
# `orphans` is a \n-joined string; %b expands it so each reported line lands on its own line.
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
echo "REACHED: end"
