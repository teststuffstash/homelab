# ── the while loop open ── same `read` variables as the scan's queued dispatch loop.
# Uses `@tsv` + `IFS="$(printf '\t')"`, exactly as the scan does, to drive the real
# tab-delimited path. The jq below emits `-` placeholders for empty `qparent` and `qbase`
# to prevent POSIX `read` from collapsing consecutive empty fields and shifting values.
while IFS="$(printf '\t')" read -r qnum qtitle qtouches qdeps qpin qclass qparent qbase; do
  [ -n "$qnum" ] || continue
  [ "$qtouches" = "-" ] && qtouches="*"
  [ "$qdeps" = "-" ] && qdeps=""
  [ "$qparent" = "-" ] && qparent=""
  [ "$qbase" = "-" ] && qbase=""
  # TRACKS rule 1 per-base (homelab#849): absent `Base:` body line → default branch.
  [ -z "$qbase" ] && qbase="$default_branch"