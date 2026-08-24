# ── the while loop open ── same `read` variables as the scan's queued dispatch loop.
# Uses `|` as delimiter (jq's join("|") instead of @tsv) to avoid bash `read`
# collapsing consecutive empty fields — a pre-existing issue in the scan that
# would shift `qbase` into `qparent` when `qparent` is empty.
while IFS='|' read -r qnum qtitle qtouches qdeps qpin qclass qparent qbase; do
  [ -n "$qnum" ] || continue
  [ "$qtouches" = "-" ] && qtouches="*"
  [ "$qdeps" = "-" ] && qdeps=""
  # TRACKS rule 1 per-base (homelab#849): absent `Base:` body line → default branch.
  [ -z "$qbase" ] && qbase="$default_branch"