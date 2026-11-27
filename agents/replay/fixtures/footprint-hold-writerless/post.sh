  # ── observation point ── not scan code. Reaching this line IS the dispatch: in the shipped
  # script a footprint-hold block that did not `continue` falls through to the unit append.
  printf 'DISPATCH #%s (%s, class=%s, declared: %s)\n' "$qnum" "$repo" "$qclass" "$qtouches"
done <<< "$CASES"
printf '%b' "$ITEM_CLASS_ROWS" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'CLASS %s\n' "$l"; fi
done
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
echo "REACHED: end"
