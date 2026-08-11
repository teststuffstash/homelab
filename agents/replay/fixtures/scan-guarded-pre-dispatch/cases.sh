# ── the queued units ── `repo|number|Touches|title`, one per line: the four loop variables the
# guarded block reads. `qtouches` carries the value the scan has ALREADY normalized (a missing
# `Touches:` line has become the `*` sentinel by this point, ADR-097), so #402 is written as `*`.
CASES="homelab|299|agents/coordinator/|goal child: the OpenRouterKey manifest + the SCOUT_MCP_KEY env line
homelab|309|agents/coordinator-scan.sh, agents/replay/|scan: no pre-dispatch check that an issue's Touches hits GUARDED
homelab|400|argocd/platform/openrouter-operator.yaml|openrouter-operator: add a syncPolicy retry backoff
homelab|401|argocd/resources/loki/|loki: raise the retention window
homelab|402|*|a legacy issue with no Touches: line at all
homelab|403|**/*.yaml|a glob that defeats prefix reasoning
oracle-fleet|404|agents/coordinator/|a stack repo that happens to own a same-named path
homelab|405|argocd/platform/|split the platform app-of-apps directory"
while IFS='|' read -r repo qnum qtouches qtitle; do
  [ -n "$qnum" ] || continue
