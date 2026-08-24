# ── the queued units ── `repo|qnum|qtitle|qclass|qparent|qbase`, one per line.
# qbase carries the `Base:` body line value the scan has ALREADY extracted (empty = no Base: line,
# which the bridge sets to default_branch before the block fires).
#
# Cases:
#   #849a  master-based issue (no Base:)  with 3 armed PRs against master → HELD
#          (same-base, ≥ cap)
#   #849b  goal/**-based issue (Base:)     with 3 armed PRs against master → DISPATCHED
#          (cross-base: master PRs do not hold goal/** issues)
#   #849c  goal/**-based issue (Base:)     with 1 armed PR against goal/29  → DISPATCHED
#          (same-base, under cap)
CASES="homelab|849a|master-based issue with 3 master PRs|fix||master
homelab|849b|goal-based issue with 3 master PRs|fix||goal/29-p0-complete
homelab|849c|goal-based issue with 1 goal PR|fix||goal/29-p0-complete"
while IFS='|' read -r repo qnum qtitle qclass qparent qbase; do
  [ -n "$qnum" ] || continue