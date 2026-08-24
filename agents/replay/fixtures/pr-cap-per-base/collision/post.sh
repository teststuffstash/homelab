# ── observation point ── not scan code.
printf 'DISPATCH #%s (%s, base=%s)\n' "$qnum" "$repo" "$qbase"
done <<< "$CASES"
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
echo "REACHED: end"