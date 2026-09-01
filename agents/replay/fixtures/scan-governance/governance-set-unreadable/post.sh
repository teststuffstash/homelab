# ── observation point ── reach here means dispatch; break (continue) means hold
  printf 'DISPATCH #%s (%s, declared: %s)\n' "$qnum" "$repo" "$qtouches"
done <<< "$CASES"
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
echo "REACHED: end"
