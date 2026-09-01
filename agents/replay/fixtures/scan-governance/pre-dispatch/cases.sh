# ── the queued units ── `repo|number|Touches|title`, one per line: the four loop variables the
# operator-lane block reads. `qtouches` carries the value the scan has ALREADY normalized (a missing
# `Touches:` line has become the `*` sentinel by this point, ADR-097), so #1003 is written as `*`.
CASES="homelab|993|agents/coordinator-scan.sh, agents/replay/|coordinator-scan: no operator-lane footprint check
homelab|1000|.github/workflows/ci.yaml|bump the checkout action version
homelab|1001|scripts/governance-lint.sh|widen the governance set
homelab|1002|argocd/resources/loki/|loki: raise the retention window
homelab|1003|*|a legacy issue with no Touches: line at all
homelab|1004|policy/|update the access policy
homelab|1005|devbox.json|add a new devbox tool
homelab|1006|CODEOWNERS|reassign ownership
homelab|1007|.agents/fix.yaml|update the fix recipe
oracle-fleet|1008|scripts/|a stack repo that happens to own a same-named path"
while IFS='|' read -r repo qnum qtouches qtitle; do
  [ -n "$qnum" ] || continue