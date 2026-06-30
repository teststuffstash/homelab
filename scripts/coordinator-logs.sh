#!/usr/bin/env bash
# coordinator-logs — render the coordinator's interactive session transcript (its real "log").
#
# `kubectl logs` on a coordinator pod is empty: the interactive `claude` runs via `kubectl exec`,
# not as PID 1 (`sleep infinity`). Claude Code's transcript (~/.claude/projects/*.jsonl) is the full
# turn-by-turn record — read it here. Reads the latest jsonl from a RUNNING coordinator pod (the
# transcripts PVC also keeps them after the pod dies; to read those, exec a pod that mounts it).
#
#   bash scripts/coordinator-logs.sh                 # render the latest pod's latest session
#   bash scripts/coordinator-logs.sh <pod>           # a specific pod
#   bash scripts/coordinator-logs.sh [<pod>] --raw   # dump raw jsonl (for jq / re-analysis)
#   bash scripts/coordinator-logs.sh [<pod>] -f      # follow (tail -f) the live session
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KUBE="--kubeconfig ${HERE}/../tofu/kubeconfig"
KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="${HERE}/../.devbox/nix/profile/default/bin/kubectl"
[ -x "$KUBECTL" ] || KUBECTL="kubectl"
NS=agent-coordinator

POD=""; RAW=""; FOLLOW=""
while [ $# -gt 0 ]; do
  case "$1" in
    --raw) RAW=1; shift;;
    -f|--follow) FOLLOW=1; shift;;
    *) POD="$1"; shift;;
  esac
done
[ -n "$POD" ] || POD="$("$KUBECTL" $KUBE -n "$NS" get pod -l app=agent-coordinator \
  --sort-by=.status.startTime -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)"
[ -n "$POD" ] || { echo "no coordinator pod found in $NS" >&2; exit 1; }

# Newest transcript file in the pod.
F="$("$KUBECTL" $KUBE -n "$NS" exec "$POD" -- bash -lc \
  'find ~/.claude/projects -name "*.jsonl" -printf "%T@\t%p\n" 2>/dev/null | sort -rn | head -1 | cut -f2')"
[ -n "$F" ] || { echo "no transcript yet in $POD (session may not have started)" >&2; exit 1; }
echo "→ $POD : $F" >&2

CAT="cat"; [ -n "$FOLLOW" ] && CAT="tail -n +1 -f"
if [ -n "$RAW" ]; then
  exec "$KUBECTL" $KUBE -n "$NS" exec "$POD" -- bash -lc "$CAT \"$F\""
else
  "$KUBECTL" $KUBE -n "$NS" exec "$POD" -- bash -lc "$CAT \"$F\"" | python3 "${HERE}/render-transcript.py"
fi
