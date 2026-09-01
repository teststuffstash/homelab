# ── the queued units ── same format as the sibling fixture. Three cases: a homelab issue with a
# non-❌ UNGOVERNED footprint (held anyway — the governance set is unreadable, rule #6), a homelab
# issue with a ❌ footprint (held by the hardcoded operator-lane set, CODEOWNERS unreadable or
# not), and an oracle-fleet issue that dispatches regardless (both holds are this repo's).
CASES="homelab|1002|argocd/resources/loki/|loki: raise the retention window
homelab|1005|devbox.json|add a new devbox tool
oracle-fleet|1008|argocd/resources/loki/|a stack repo with a non-governance footprint"
while IFS='|' read -r repo qnum qtouches qtitle; do
  [ -n "$qnum" ] || continue
