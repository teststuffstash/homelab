# ── the queued units ── `repo|qnum|qtitle|qclass|qparent|qbase`, one per line.
#
# #849d  master-based issue (no Base:)  with 1 armed PR against master → DISPATCHED
#        (collision test: awk picks `master|1`, not `big-master|7`)
CASES="homelab|849d|master-based issue with collision base|fix||master"
while IFS='|' read -r repo qnum qtitle qclass qparent qbase; do
  [ -n "$qnum" ] || continue