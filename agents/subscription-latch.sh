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
# exit 0 = clear to dispatch. exit 1 = latched (reason printed to stderr).
# FAIL-OPEN by design: proxy unreachable (jail/manual run — the ClusterIP svc doesn't cross the
# BGP boundary) or a malformed reply reads as clear. The latch is a burn-saver, not a gate.
set -u
PROXY="${AGENT_EGRESS_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}"
reply="$(curl -fsS --max-time 5 "$PROXY/anthropic-limit" 2>/dev/null)" || exit 0
limited="$(printf '%s' "$reply" | jq -r '.limited // false' 2>/dev/null)" || exit 0
[ "$limited" = "true" ] || exit 0
remaining="$(printf '%s' "$reply" | jq -r '.remaining_s // "?"' 2>/dev/null)"
echo "subscription 429-latched (FU-088): Anthropic account rate limit hit — deferring subscription dispatch ~${remaining}s (probe: ${PROXY}/anthropic-limit)" >&2
exit 1
