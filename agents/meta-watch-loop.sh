#!/bin/bash
# watch-oracle-loop — liveness-aware watch of the oracle agent loop around PR #60's fix round.
# Emits ONLY on change: scan-tick summaries, agent pod lifecycle, PR review/commit state, stalls.
cd /workspace/homelab || { echo "PROBE-FAIL: repo missing"; exit 1; }
K="devbox run -- kubectl --kubeconfig tofu/kubeconfig"
last_scan=""; last_pods=""; last_pr=""; last_scan_seen=$(date +%s); probe_fails=0
while true; do
  now=$(date +%s)
  # --- newest oracle scan tick (pod name == workflow name) ---
  wf=$($K get pods -n oracle-agents -o name 2>/dev/null | grep -o 'coordinate-oracle-[0-9]*' | sort | tail -1)
  if [ -z "$wf" ]; then
    probe_fails=$((probe_fails+1))
    [ "$probe_fails" -eq 3 ] && echo "PROBE-FAIL x3: cannot list oracle-agents pods (kubectl/devbox dead — NOT 'no work')"
  else
    probe_fails=0
    if [ "$wf" != "$last_scan" ]; then
      last_scan="$wf"; last_scan_seen=$now
      sleep 45  # let the tick clone + finish writing
      sum=$($K logs -n oracle-agents "$wf" --all-containers 2>/dev/null \
            | grep -E "stack oracle:|actionable|spawn|dispatch|REPORT-ONLY|agent/error|changes.requested|fix|trigger held" \
            | grep -vE "^time=" | head -8)
      # idle ticks are liveness-only, and an unchanged report block is idle too — emit on CHANGE
      case "$sum" in
        *ACTIONABLE*|*REPORT-ONLY*|*agent/error*|*"trigger held"*|"")
          if [ "$sum" != "$last_emitted_sum" ]; then
            echo "scan tick ${wf##*-}: ${sum:-<no summary line — read logs>}"
            last_emitted_sum="$sum"
          fi;;
      esac
    fi
  fi
  if [ $((now - last_scan_seen)) -gt 1500 ]; then
    echo "STALL: no new coordinate-oracle tick observed in 25 min (last: $last_scan)"
    last_scan_seen=$now
  fi
  # --- agent/reviewer pods in the loop's namespaces ---
  pods=$({ $K get pods -n oracle-fleet -l app=agent-session --no-headers 2>/dev/null; \
           $K get pods -n oracle-agents --no-headers 2>/dev/null | grep -E '^coordinator-'; \
           $K get pods -n agent-coordinator --no-headers 2>/dev/null | grep -E '^reviewer-'; } \
         | awk '$3!="Completed"{print $1"="$3}' | sort | tr '\n' ' ')
  if [ "$pods" != "$last_pods" ]; then
    echo "pods: ${pods:-<none>} (was: ${last_pods:-<none>})"
    last_pods="$pods"
  fi
  # --- open-PR set in the stack's main repo (jail PAT pool, ~30 req/h) ---
  pr=$(gh pr list --repo teststuffstash/oracle-fleet --state open \
        --json number,mergeStateStatus,reviewDecision,labels 2>/dev/null \
        | jq -c '[.[] | {n:.number, m:.mergeStateStatus, rd:.reviewDecision, l:[.labels[].name]}]')
  if [ -z "$pr" ]; then
    echo "PROBE-FAIL: gh pr list returned nothing"
  elif [ "$pr" != "$last_pr" ]; then
    echo "open PRs: $pr"
    last_pr="$pr"
  fi
  sleep 90
done
