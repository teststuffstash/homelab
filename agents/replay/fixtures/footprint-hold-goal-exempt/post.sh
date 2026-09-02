# ── observation point ── not scan code. Reaching this line IS the dispatch: in the shipped script
  # the footprint-hold block that did not `continue` falls through to the lines that append the
  # unit to `$iss`.
  printf 'DISPATCH #%s (%s, class=%s, declared: %s)\n' "$qnum" "$repo" "$qclass" "$qtouches"
done <<< "$CASES"
# ITEM_CLASS_ROWS: the per-pass accumulator. Verify that footprint-held rows are pushed
# for footprint-conflict-held items (FU-199 / #1240).
printf '%b' "$ITEM_CLASS_ROWS" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'CLASS %s\n' "$l"; fi
done
# `orphans` is a \n-joined string; %b expands it so each reported line lands on its own line and
# `diff` stays line-oriented.
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
echo "REACHED: end"