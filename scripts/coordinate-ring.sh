#!/usr/bin/env bash
# Ring the /coordinate doorbell for one or more stacks — the edge that wakes a per-stack scan
# NOW instead of waiting out the */15-30 cron (meta-coordinate skill §RING AFTER QUEUEING;
# operator catch 2026-08-09). ONE ring per invocation, never a loop.
#
# Usage: devbox run ring <stack> [<stack>...]        e.g. devbox run ring oracle platform
#
# Mirrors coordinator-session.sh's ring (the reference implementation):
#  - SKIPS while the subscription is latched — a woken scan could only dispatch work that
#    defers for the same reason, and the ring would feed the constraint it waits on
#    (the circles#31 spin, 2026-08-06). Fail-open: an unreadable latch rings anyway.
#  - Reaches the in-cluster EventSource via a short-lived port-forward (jail-side; in-cluster
#    callers hit the Service directly and don't need this script).
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KUBECTL="kubectl --kubeconfig ${HERE}/tofu/kubeconfig"

[ $# -ge 1 ] || { echo "usage: devbox run ring <stack> [<stack>...]" >&2; exit 2; }

if ! SUBSCRIPTION_TIER=dispatch bash "${HERE}/agents/subscription-latch.sh" 2>/dev/null; then
  echo "→ ring SKIPPED — subscription latched; a woken scan would only re-defer (cron backstop owns it)"
  exit 0
fi

$KUBECTL -n agent-coordinator port-forward svc/agent-loop-eventsource-svc 12099:12000 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
sleep 3

rc=0
for s in "$@"; do
  body="{\"stack\":\"${s}\",\"loop_ns\":\"${s}-agents\",\"unit\":\"-\"}"
  if curl -m 5 -s -X POST -H "Content-Type: application/json" -d "$body" \
       http://localhost:12099/coordinate >/dev/null 2>&1; then
    echo "→ doorbell rung: ${s}"
  else
    echo "RING FAILED: ${s} — check the port-forward and the EventSource pod" >&2
    rc=1
  fi
done
exit $rc
