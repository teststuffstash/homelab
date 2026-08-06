#!/bin/bash
# meta-ride-edge-probe — measure the RIDE-COMPLETION edge for the work-vs-wait ledger
# (docs/agents/observability-and-retro.md §Part A″).
#
# Why this exists: `agent-session.sh` rings `/coordinate` at the END of its run, but that code
# runs in the LAUNCHER — inside the coordinator item-session pod. On 2026-08-06 that pod
# (coordinator-081840) EXITED while its ride was still Running, which would orphan the ring and
# leave a finished PR waiting for the `*/30` cron. This probe settles it with timestamps instead
# of reasoning: ride ends → PR appears → next scan tick. The gap between the last two IS the ⏳.
#
# Emits one line per transition and exits when the scan is seen (or at the deadline). Every probe
# failure is LOUD — an unreadable pod must never read as "finished" (rule #6).
#
#   RIDE=agent-circles-issue-30-r1 bash agents/meta-ride-edge-probe.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
K=".devbox/nix/profile/default/bin/kubectl --kubeconfig tofu/kubeconfig"
RIDE="${RIDE:?set RIDE=<ride pod name>}"
RIDE_NS="${RIDE_NS:-circles}"
STACK_NS="${STACK_NS:-circles-agents}"
REPO="${REPO:-teststuffstash/circles}"
BASE="${BASE:-goal/29-p0-complete}"
DEADLINE=$(( $(date +%s) + 5400 ))

scan_before="$($K -n "$STACK_NS" get pods -o name 2>/dev/null | grep -c coordinate- || true)"
ride_end=""; pr_seen=""; fails=0

while :; do
  now=$(date +%s); ts=$(date -u +%H:%M:%S)

  if [ -z "$ride_end" ]; then
    phase="$($K -n "$RIDE_NS" get pod "$RIDE" -o jsonpath='{.status.phase}' 2>/dev/null)"
    if [ -z "$phase" ]; then
      fails=$((fails+1))
      [ "$fails" -ge 3 ] && { echo "PROBE-FAIL x3: ride $RIDE phase unreadable — probe dead, NOT finished"; exit 1; }
    else
      fails=0
      case "$phase" in
        Succeeded|Failed) ride_end=$now; echo "[$ts] RIDE ENDED phase=$phase — the completion edge starts here";;
      esac
    fi
  fi

  if [ -z "$pr_seen" ]; then
    pr="$(gh pr list --repo "$REPO" --state open --base "$BASE" --json number,autoMergeRequest,createdAt 2>/dev/null)"
    if [ -n "$pr" ] && [ "$pr" != "[]" ]; then
      pr_seen=$now
      echo "[$ts] PR OPEN on $BASE: $(printf '%s' "$pr" | jq -c '[.[]|{n:.number, armed:(.autoMergeRequest!=null), at:.createdAt}]')"
    fi
  fi

  if [ -n "$pr_seen" ]; then
    scan_now="$($K -n "$STACK_NS" get pods -o name 2>/dev/null | grep -c coordinate- || true)"
    if [ "${scan_now:-0}" -gt "${scan_before:-0}" ]; then
      gap=$(( now - pr_seen ))
      echo "[$ts] SCAN WOKE — $(( gap / 60 ))m$(( gap % 60 ))s after the PR opened. ⏳ if this is ~cron-length, the ride-completion doorbell did not ring."
      exit 0
    fi
  fi

  [ "$now" -ge "$DEADLINE" ] && { echo "PROBE DEADLINE: ride_end=${ride_end:-none} pr_seen=${pr_seen:-none} — investigate by hand"; exit 1; }
  sleep 30
done
