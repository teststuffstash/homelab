# ── observation point ── the two count tables, one line per base.
printf '%s\n' "$per_base_armed"     | sed 's/^/ARMED /'
printf '%s\n' "$per_base_blockpark" | sed 's/^/BLOCKPARK /'
echo "REACHED: end"
