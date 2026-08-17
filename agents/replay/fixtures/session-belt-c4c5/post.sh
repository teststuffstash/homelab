# ── observation point ── not scan code. `sess_nums` is printed because the exclusion in C4C5_SEL
# keys off it, and a fixture that proved suppression without showing what fed it would not have
# proven the right mechanism. `units` / `orphans` / `v2` are \n-joined strings; %b expands them so
# each emitted action lands as its own line and `diff` stays line-oriented.
printf 'SESS_NUMS %s\n' "${sess_nums:-<none>}"
printf '%b' "$units" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'UNIT %s\n' "$l"; fi
done
printf '%b' "$orphans" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'ORPHAN %s\n' "$l"; fi
done
printf '%s\n' "$v2" | while IFS= read -r l; do
  if [ -n "$l" ]; then printf 'V2 %s\n' "$l"; fi
done
echo "REACHED: end"
