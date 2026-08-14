#!/usr/bin/env bash
# subscription-latch — the launcher-side probe of the FU-088(a) reactive 429 latch.
#
# The egress proxy latches on the first upstream 429 from the Anthropic subscription
# (argocd/resources/openrouter-proxy/openrouter-proxy.py — the choke point every subscription
# session flows through) and serves the state at GET /anthropic-limit. Every launcher that spawns
# a subscription pod (review-reflex tick, reviewer-session, coordinator-session, agent-session
# --harness claude) runs this first and defers while latched — a report-only line instead of a
# doomed spawn that burns a session on a rate-limited account.
#
# Two gates, both FU-088(a) — BOTH now answered server-side by the proxy (ADR-096 P2):
#   1. the proxy verdict (reactive 429 latch OR harvested utilization ≥ threshold). FU-109:
#      export SUBSCRIPTION_TIER=dispatch|heavy and the proxy applies the per-consumer threshold
#      (dispatch units defer later than heavy sessions; composed max(window, tier)).
#   2. the concurrency semaphore — the proxy counts Running subscription-session=claude pods
#      itself (reason "semaphore"). The local kubectl count below is now only the BELT for a
#      proxy that answered without a semaphore verdict (old script version) or not at all.
#
# exit 0 = clear to dispatch. exit 1 = deferred (reason printed to stderr).
# FAIL-OPEN by design: proxy unreachable (jail/manual run — the ClusterIP svc doesn't cross the
# BGP boundary), kubectl/RBAC missing, or a malformed reply reads as clear. Burn-saver, not a gate.
#
# --pick-rail mode (homelab#439): when the Anthropic subscription is latched (exit 1), probe the
# Go rail via ${PROXY}/opencode-limit and print the rail name if clear. Backward-compatible:
# no flag = boolean contract (exit 0 = clear, exit 1 = latched).
set -u
PROXY="${AGENT_EGRESS_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}"
TIER="${SUBSCRIPTION_TIER:-}"

# _anthropic_clear — the ENTIRE Anthropic probe (one home, reused by both modes).
# Returns 0 (clear) or 1 (latched), executing the full verdict logic (server semaphore,
# SUBSCRIPTION_MAX_RUNNING belt, tier semantics, fail-open). Pure function: no exit, callers decide.
_anthropic_clear() {
  local reply server_semaphore limited reason detail sem MAX running
  reply="$(curl -fsS --max-time 5 "$PROXY/anthropic-limit${TIER:+?tier=$TIER}" 2>/dev/null)" || reply=""
  server_semaphore="false"
  if [ -n "$reply" ]; then
    limited="$(printf '%s' "$reply" | jq -r '.limited // false' 2>/dev/null)" || limited="false"
    if [ "$limited" = "true" ]; then
      reason="$(printf '%s' "$reply" | jq -r '.reason // "?"' 2>/dev/null)"
      detail="$(printf '%s' "$reply" | jq -r '[.windows | to_entries[] | "\(.key)=\(.value.utilization)"] | join(" ")' 2>/dev/null)"
      sem="$(printf '%s' "$reply" | jq -r 'if .semaphore.running != null then " sem=\(.semaphore.running)/\(.semaphore.max)" else "" end' 2>/dev/null)"
      echo "subscription limited (FU-088, ${reason}${TIER:+, tier=$TIER}): utilization ${detail:-?}${sem} — deferring subscription dispatch (probe: ${PROXY}/anthropic-limit)" >&2
      return 1
    fi
    # ADR-096 P2: a reply carrying a semaphore verdict already counted the pods server-side.
    server_semaphore="$(printf '%s' "$reply" | jq -r 'if .semaphore.running != null then "true" else "false" end' 2>/dev/null)" || server_semaphore="false"
  fi
  # Semaphore belt: label-selector count of live subscription sessions.
  MAX="${SUBSCRIPTION_MAX_RUNNING:-5}"
  if [ "$server_semaphore" != "true" ] && [ "$MAX" -gt 0 ] 2>/dev/null && command -v kubectl >/dev/null 2>&1; then
    running="$(kubectl get pods -A -l homelab.teststuff.net/subscription-session=claude \
      --field-selector status.phase=Running --no-headers 2>/dev/null | wc -l)" || running=0
    if [ "${running:-0}" -ge "$MAX" ]; then
      echo "subscription semaphore (FU-088): ${running} subscription pods Running (max ${MAX}) — deferring dispatch (SUBSCRIPTION_MAX_RUNNING overrides)" >&2
      return 1
    fi
  fi
  return 0
}

# >>>REPLAY:pick-rail-ladder>>>
# --pick-rail mode: compose the ladder, print the rail name on success
if [ "${1:-}" = "--pick-rail" ]; then
  # First check Anthropic via the one-home function
  if _anthropic_clear; then
    # Anthropic clear → print "anthropic" and exit 0
    echo "anthropic"
    exit 0
  fi
  # Anthropic latched → probe Go rail
  go_reply="$(curl -fsS --max-time 5 "$PROXY/opencode-limit" 2>/dev/null)" || go_reply=""
  go_limited="true"
  if [ -n "$go_reply" ]; then
    go_limited="$(printf '%s' "$go_reply" | jq -r '.limited // false' 2>/dev/null)" || go_limited="true"
  fi
  if [ "$go_limited" = "false" ]; then
    # Go rail clear → print rail name, log to stderr, exit 0
    echo "opencode-go/deepseek-v4-flash"
    echo "→ Anthropic latched — Go rail clear (opencode-go/deepseek-v4-flash)" >&2
    exit 0
  fi
  # Both latched → exit 1 with stderr naming both
  if [ -n "$go_reply" ]; then
    echo "both rails latched (Anthropic: 429/utilization, Go: limited)" >&2
  else
    echo "both rails latched (Anthropic: 429/utilization, Go: unreachable)" >&2
  fi
  exit 1
fi
# <<<REPLAY:pick-rail-ladder<<<

# Flagless path: boolean contract, reuse the one-home probe
_anthropic_clear || exit 1
exit 0
