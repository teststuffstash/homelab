printf '%b' "$orphans" | sed 's/^/ORPHAN /'
printf '%b' "$units" | sed 's/^/UNIT /'
echo "REACHED: end"
[ -z "${um_lane_side:-}" ] || echo "LANE${um_lane_side}"
