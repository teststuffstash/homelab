# ── the queued units ── `repo|number|Touches|title`. Both declare the SAME unguarded footprint on
# purpose: the only thing separating their outcomes is which repo the unreadable set belongs to.
CASES="homelab|401|argocd/resources/loki/|loki: raise the retention window
oracle-fleet|404|argocd/resources/loki/|loki: raise the retention window"
while IFS='|' read -r repo qnum qtouches qtitle; do
  [ -n "$qnum" ] || continue
