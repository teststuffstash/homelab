# ── the queued units ── same format as the sibling fixture. Two cases: one homelab issue with a
# non-❌ footprint (should dispatch — CODEOWNERS unreadable defaults to machine-merge), and one
# homelab issue with a ❌ footprint (should hold — the ❌ set is hardcoded in classify_touches()).
CASES="homelab|1002|argocd/resources/loki/|loki: raise the retention window
homelab|1005|devbox.json|add a new devbox tool"
while IFS='|' read -r repo qnum qtouches qtitle; do
  [ -n "$qnum" ] || continue