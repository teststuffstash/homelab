#!/bin/bash
# meta-watch-loop — liveness-aware watch of the ACTIVE agent loop (sleep stack, router live test).
# Emits ONLY on change: scan-tick summaries, agent pod lifecycle, PR review/commit state, stalls,
# proxy auth-circuit events. Override STACK_NS/RIDE_NS/REPO to point at another stack.
# Lessons wired in (2026-08-02): a redispatched ride pod REUSES its name — key pod state on
# startTime, not name; a ride nearing the 2h session-key window is a failure signal, not calm;
# an armed PR sitting BEHIND >15min means the updater backstop failed (FU-124).
cd /workspace/homelab || { echo "PROBE-FAIL: repo missing"; exit 1; }
K="devbox run -- kubectl --kubeconfig tofu/kubeconfig"
STACK_NS="${STACK_NS:-sleep-agents}"; RIDE_NS="${RIDE_NS:-sleep-tracking}"
REPO="${REPO:-teststuffstash/sleep-tracking}"; SCAN_PREFIX="${SCAN_PREFIX:-coordinate-sleep-}"
last_scan=""; last_pods=""; last_pr=""; last_emitted_sum=""; last_scan_seen=$(date +%s)
probe_fails=0; last_keywarn=""; behind_since=0; last_am=""
while true; do
  now=$(date +%s)
  # --- newest scan tick (pod name == workflow name) ---
  wf=$($K get pods -n "$STACK_NS" -o name 2>/dev/null | grep -o "${SCAN_PREFIX}[0-9]*" | sort | tail -1)
  if [ -z "$wf" ]; then
    probe_fails=$((probe_fails+1))
    [ "$probe_fails" -eq 3 ] && echo "PROBE-FAIL x3: cannot list $STACK_NS pods (kubectl/devbox dead — NOT 'no work')"
  else
    probe_fails=0
    if [ "$wf" != "$last_scan" ]; then
      last_scan="$wf"; last_scan_seen=$now
      sleep 45  # let the tick clone + finish writing
      sum=$($K logs -n "$STACK_NS" "$wf" -c main 2>/dev/null \
            | grep -E "actionable|spawn|dispatch|REPORT-ONLY|agent/error|WIP busy|probe FAILED|reaping|blocked" \
            | grep -vE "^time=" | head -8)
      # idle ticks are liveness-only; emit on CHANGE of the report block
      if [ "$sum" != "$last_emitted_sum" ]; then
        echo "scan tick ${wf##*-}: ${sum:-<no summary line — read logs>}"
        last_emitted_sum="$sum"
      fi
    fi
  fi
  if [ $((now - last_scan_seen)) -gt 1500 ]; then
    echo "STALL: no new ${SCAN_PREFIX}* tick observed in 25 min (last: $last_scan)"
    last_scan_seen=$now
  fi
  # --- ride/coordinator/reviewer pod lifecycle (startTime in the key: same-name redispatch emits) ---
  pods=$({ $K get pods -n "$RIDE_NS" -l app=agent-session \
             -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}@{.status.startTime}{"\n"}{end}' 2>/dev/null; \
           $K get pods -n "$STACK_NS" --no-headers 2>/dev/null | grep -E '^coordinator-' | awk '$3!="Completed"{print $1"="$3}'; \
           $K get pods -n agent-coordinator --no-headers 2>/dev/null | grep -E '^reviewer-' | awk '$3!="Completed"{print $1"="$3}'; } \
         | sort | tr '\n' ' ')
  if [ "$pods" != "$last_pods" ]; then
    echo "pods: ${pods:-<none>} (was: ${last_pods:-<none>})"
    last_pods="$pods"
  fi
  # --- ride age vs the 2h session-key window: >100min without a PR = expiry-death risk ---
  ride_start=$($K get pods -n "$RIDE_NS" -l app=agent-session \
      -o jsonpath='{.items[0].status.startTime}' 2>/dev/null)
  if [ -n "$ride_start" ]; then
    age=$(( now - $(date -d "$ride_start" +%s 2>/dev/null || echo "$now") ))
    if [ "$age" -gt 6000 ] && [ "$last_keywarn" != "$ride_start" ]; then
      echo "KEY-WINDOW: ride started $ride_start is ${age}s old — session key expires at 2h; no PR yet means an expiry death is near"
      last_keywarn="$ride_start"
    fi
  fi
  # --- Alertmanager firing set (AWARENESS only — the responder owns triage; this exists because
  #     dedup'd repeat fingerprints never re-escalate, so the meta session was blind to a live
  #     symptom unless the operator pasted it, 2026-08-02 egress-drop) ---
  am=$(curl -fsS --max-time 10 "${AM_URL:-http://192.168.40.14:9093}/api/v2/alerts?active=true&silenced=false&inhibited=false" 2>/dev/null \
       | jq -r '[.[].labels.alertname | select(. != "InfoInhibitor")] | unique | if length==0 then "NONE" else join(",") end')
  if [ -z "$am" ] && [ "$last_am" != "PROBE_FAILED" ]; then
    echo "PROBE-FAIL: Alertmanager unreachable (firing-set clause blind)"; last_am="PROBE_FAILED"
  elif [ -n "$am" ] && [ "$am" != "$last_am" ]; then
    echo "ALERTS firing set changed: [${am}] (was: [${last_am:-<none>}]) — check responder verdict before hand-triage"
    last_am="$am"
  fi
  # --- proxy auth-circuit events (rare, always actionable) ---
  circ=$($K -n agent-egress logs deploy/openrouter-proxy --since=3m 2>/dev/null | grep -E 'circuit OPEN|circuit.*close' | head -3)
  [ -n "$circ" ] && echo "PROXY: $circ"
  # --- open-PR set (jail PAT pool, ~30 req/h) + FU-124 armed-BEHIND clause ---
  pr=$(gh pr list --repo "$REPO" --state open \
        --json number,mergeStateStatus,reviewDecision,labels 2>/dev/null \
        | jq -c '[.[] | {n:.number, m:.mergeStateStatus, rd:.reviewDecision, l:[.labels[].name]}]')
  if [ -z "$pr" ]; then
    echo "PROBE-FAIL: gh pr list returned nothing"
  else
    [ "$pr" != "$last_pr" ] && { echo "open PRs: $pr"; last_pr="$pr"; }
    if jq -e '.[] | select(.m=="BEHIND" and .rd=="APPROVED")' >/dev/null 2>&1 <<<"$pr"; then
      [ "$behind_since" -eq 0 ] && behind_since=$now
      if [ $((now - behind_since)) -gt 900 ]; then
        echo "FU-124: an APPROVED PR has sat BEHIND >15min — the updater backstop likely missed; dispatch it by hand"
        behind_since=$now
      fi
    else
      behind_since=0
    fi
  fi
  sleep 90
done
