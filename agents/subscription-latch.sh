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
# Two gates, both FU-088(a):
#   1. the proxy verdict (reactive 429 latch OR harvested utilization ≥ threshold, default 80%)
#   2. the concurrency semaphore — count Running pods labelled subscription-session=claude
#      across namespaces and defer at ≥ SUBSCRIPTION_MAX_RUNNING (default 3: one coordinator
#      tick + the reflex's two reviewers; claude-tier workers share the same pool). This is the
#      proactive half: it prevents the burst that CAUSES the 429.
#
# exit 0 = clear to dispatch. exit 1 = deferred (reason printed to stderr).
# FAIL-OPEN by design: proxy unreachable (jail/manual run — the ClusterIP svc doesn't cross the
# BGP boundary), kubectl/RBAC missing, or a malformed reply reads as clear. Burn-saver, not a gate.
set -u
PROXY="${AGENT_EGRESS_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}"
reply="$(curl -fsS --max-time 5 "$PROXY/anthropic-limit" 2>/dev/null)" || reply=""
if [ -n "$reply" ]; then
  limited="$(printf '%s' "$reply" | jq -r '.limited // false' 2>/dev/null)" || limited="false"
  if [ "$limited" = "true" ]; then
    reason="$(printf '%s' "$reply" | jq -r '.reason // "?"' 2>/dev/null)"
    detail="$(printf '%s' "$reply" | jq -r '[.windows | to_entries[] | "\(.key)=\(.value.utilization)"] | join(" ")' 2>/dev/null)"
    echo "subscription limited (FU-088, ${reason}): utilization ${detail:-?} — deferring subscription dispatch (probe: ${PROXY}/anthropic-limit)" >&2
    exit 1
  fi
fi

# Semaphore: label-selector count of live subscription sessions. Launchers stamp the label
# (homelab.teststuff.net/subscription-session=claude) on every pod that draws on the operator
# plan. Needs cluster-wide pod list; a denied/absent kubectl fails open.
MAX="${SUBSCRIPTION_MAX_RUNNING:-3}"
if [ "$MAX" -gt 0 ] 2>/dev/null && command -v kubectl >/dev/null 2>&1; then
  running="$(kubectl get pods -A -l homelab.teststuff.net/subscription-session=claude \
    --field-selector status.phase=Running --no-headers 2>/dev/null | wc -l)" || running=0
  if [ "${running:-0}" -ge "$MAX" ]; then
    echo "subscription semaphore (FU-088): ${running} subscription pods Running (max ${MAX}) — deferring dispatch (SUBSCRIPTION_MAX_RUNNING overrides)" >&2
    exit 1
  fi
fi
exit 0
