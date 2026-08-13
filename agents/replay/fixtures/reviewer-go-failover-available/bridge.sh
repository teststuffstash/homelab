#!/usr/bin/env bash
# ── bridge + drive — test the failover gate logic directly.
# The gate: if subscription-latch.sh fails, probe Go rail; if Go available, continue with kimi-k3.
set -euo pipefail

PROJECT="${PROJECT:-test-project}"
PR="${PR:-42}"
MODEL_SET_EXPLICIT="${MODEL_SET_EXPLICIT:-}"
MODEL="sonnet"
GO_SERVED=0

# subscription-latch.sh stub: returns 1 (Anthropic is latched)
subscription-latch.sh() {
  echo "subscription limited (FU-088, 429): utilization high — deferring subscription dispatch" >&2
  return 1
}

# Simulate the Go rail probe response (no real curl call - inline the response)
# This is the "available" case: Go rail returns {limited: false}
go_probe_available() {
  printf '{"limited": false, "semaphore": {"running": 1, "max": 10}}'
}

# The failover gate logic (from reviewer-session.sh lines 342-365)
# NOTE: We inline the Go probe response instead of calling curl to avoid network dependency
if ! subscription-latch.sh; then
  # Go rail probe (simulated - inline response for {limited: false})
  go_reply="$(go_probe_available)"
  go_limited="true"
  if [ -n "$go_reply" ]; then
    go_limited="$(printf '%s' "$go_reply" | jq -r '.limited // false' 2>/dev/null)" || go_limited="true"
  fi
  if [ "$go_limited" = "false" ]; then
    if [ -z "${MODEL_SET_EXPLICIT:-}" ]; then
      MODEL="opencode-go/kimi-k3"
      GO_SERVED=1
      echo "→ Anthropic latched — serving review of ${PROJECT}#${PR} from the Go rail (opencode-go/kimi-k3)"
      echo "GATE_CONTINUE"
      exit 0
    else
      echo "→ review of ${PROJECT}#${PR} deferred — subscription rate-limited (explicit --model=${MODEL} pinned, cannot failover to Go)"
      exit 0
    fi
  else
    echo "→ review of ${PROJECT}#${PR} deferred — subscription rate-limited (FU-088 latch)"
    exit 0
  fi
fi
echo "GATE_CONTINUE"
