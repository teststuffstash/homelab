# ── the queued units ── same format as the sibling fixture. Two cases: one homelab issue that
# would be dispatched if the set were readable, and one oracle-fleet issue that should dispatch
# regardless (the set is homelab's CI's, not a stack repo's).
CASES="homelab|1002|argocd/resources/loki/|loki: raise the retention window
oracle-fleet|1008|argocd/resources/loki/|a stack repo with a non-governance footprint"
while IFS='|' read -r repo qnum qtouches qtitle; do
  [ -n "$qnum" ] || continue