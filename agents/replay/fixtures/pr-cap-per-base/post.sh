# ── observation point ── not scan code. Reaching this line IS the dispatch: in the shipped script
# the pr-cap-per-base block that did not `continue` falls through to the lines that append the
# unit to `$iss`.
printf 'DISPATCH #%s (%s, base=%s)\n' "$qnum" "$repo" "$qbase"
done <<< "$CASES"
# `orphans` is a \n-joined string; %b expands it so each reported line lands on its own line and
# `diff` stays line-oriented.
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
echo "REACHED: end"