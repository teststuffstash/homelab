printf '%b' "$orphans" | sed 's/^/ORPHAN /'
printf '%b' "$units" | sed 's/^/UNIT /'
echo "REACHED: end"
