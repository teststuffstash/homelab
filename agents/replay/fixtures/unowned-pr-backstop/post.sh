# the first (label-free) backstop line is appended to the report far below the block — show it as-is
printf '%s\n' "$orph" | sed '/^$/d; s/^/ORPH /'
printf '%b' "$orphans" | sed 's/^/ORPHAN /'
echo "REACHED: end"
