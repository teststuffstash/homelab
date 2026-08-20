#!/bin/bash
# meta-throughput — the fleet-throughput probe the 2026-08-09 stall exposed (operator: "it has
# 2 hour sweeps and it did not catch that it was doing nothing but burning tokens" — one 18-min
# worker ride in ~9h while sweeps checked chains and boards, and NOTHING asked whether any worker
# had actually ridden). Run once per heartbeat sweep, alongside meta-alert-crosscheck.sh.
#
# The doctrine it operationalizes: a steady-state COUNTER cannot separate "at capacity" from
# "cannot work" — throughput needs a MOVEMENT signal. The durable movement signal for a ride is
# its GitHub comment trail (ride pods/workflows are GC'd in minutes; comments are forever):
# "picking this up (round" at dispatch, the cost table ("| model |") or AGENT_STRIKE at the end.
#
# ⚠ TWO SIGNATURE ERAS, and BOTH must match or this probe reports a stall that is not one
# (ADR-103/#210). The dispatch notice and the run-stats table no longer add a comment: they append
# a line to ONE `<!-- agent-summary -->` comment per timeline, so the pre-#210 shapes stop appearing
# on new rides while the old ones stay valid on everything already in flight. Hence the union below,
# and hence `updated_at` — an edited summary comment's `created_at` is frozen at the FIRST machine
# touch, so reading it would peg every subsequent round to the age of round 1 and manufacture a
# THROUGHPUT-STALL on a fleet that is riding fine. `updated_at` is also what the REST `since=`
# filter keys on, so the page and the timestamp now agree.
#
# Output (level-triggered, no state):
#   THROUGHPUT: last ride evidence <ISO> (<m> min ago, <repo>#<issue>) | agent/queued=<n> | agent/in-progress=<n>
#   THROUGHPUT-STALL: ... — emitted when queued+in-progress work exists but no ride evidence for
#     >= STALL_MIN (default 120). That combination is an INCIDENT to root-cause NOW (dispatch
#     chain, capacity gate, router, reviewer cork, CI red — go find which), never a calm state.
# Empty queue + no rides = a genuinely idle fleet; that is NOT flagged.
#
# REST only (search + per-repo comments) — never the GraphQL pool (reflex lesson, 2026-07-17).
# Probe hygiene: any upstream failure prints PROBE-FAIL and exits 1 — absence of data is never
# reported as absence of work.
set -u
cd /workspace/homelab || { echo "PROBE-FAIL: repo missing"; exit 1; }
ORG="teststuffstash"
BOT="${BOT:-homelab-agents-1234}"
STALL_MIN="${STALL_MIN:-120}"
LOOKBACK_H="${LOOKBACK_H:-48}"
GH="devbox run -- gh"

# Every repo the loop rides, from the committed claims mirror (level-triggered, not memory).
repos=$(jq -r '.stacks[].repos[]' agents/stacks.json 2>/dev/null | sort -u)
[ -n "$repos" ] || { echo "PROBE-FAIL: no repos from agents/stacks.json"; exit 1; }

since=$(date -u -d "$LOOKBACK_H hours ago" +%Y-%m-%dT%H:%M:%SZ)
newest_ts=""; newest_where=""
for r in $repos; do
  # One REST page of newest comments per repo; ride signatures only. `direction=desc` gives the
  # newest first, so 100 covers far more than the lookback needs on any healthy day.
  rows=$($GH api "repos/$ORG/$r/issues/comments?since=$since&per_page=100&sort=created&direction=desc" 2>/dev/null) \
    || { echo "PROBE-FAIL: comments read failed for $r"; exit 1; }
  rows=$(printf '%s' "$rows" | tail -1)
  ts=$(printf '%s' "$rows" | jq -r --arg bot "$BOT" '
        [ .[] | select(.user.login == ($bot + "[bot]") or .user.login == $bot)
              | select(.body | test("<!-- agent-event |picking this up \\(round|\\| model \\||AGENT_STRIKE"))
              | .updated_at ] | max // empty' 2>/dev/null)
  if [ -n "$ts" ] && [ "$ts" \> "${newest_ts:-}" ]; then
    newest_ts="$ts"
    newest_where=$(printf '%s' "$rows" | jq -r --arg ts "$ts" --arg r "$r" '
        [ .[] | select(.updated_at == $ts) ][0] | "\($r)#\(.issue_url | sub(".*/";""))"' 2>/dev/null)
  fi
done

q_response=$($GH api "search/issues?q=org:$ORG+is:issue+is:open+label:agent/queued" 2>/dev/null) \
    || { echo "PROBE-FAIL: queued-count search failed"; exit 1; }
q=$(printf '%s' "$q_response" | tail -1 | jq -r '.total_count' 2>/dev/null)

p_response=$($GH api "search/issues?q=org:$ORG+is:issue+is:open+label:agent/in-progress" 2>/dev/null) \
    || { echo "PROBE-FAIL: in-progress-count search failed"; exit 1; }
p=$(printf '%s' "$p_response" | tail -1 | jq -r '.total_count' 2>/dev/null)
case "${q:-}" in ''|*[!0-9]*) echo "PROBE-FAIL: queued-count extraction failed"; exit 1;; esac
case "${p:-}" in ''|*[!0-9]*) echo "PROBE-FAIL: in-progress-count extraction failed"; exit 1;; esac

if [ -z "$newest_ts" ]; then
  age_min=$((LOOKBACK_H * 60)); agestr=">${LOOKBACK_H}h (none in lookback)"
else
  age_min=$(( ($(date -u +%s) - $(date -u -d "$newest_ts" +%s)) / 60 ))
  agestr="${age_min} min ago, ${newest_where:-?}"
fi
echo "THROUGHPUT: last ride evidence ${newest_ts:-none} ($agestr) | agent/queued=$q | agent/in-progress=$p"
if [ $((q + p)) -gt 0 ] && [ "$age_min" -ge "$STALL_MIN" ]; then
  echo "THROUGHPUT-STALL: $((q + p)) work item(s) carry a queue/ride label but no ride evidence for ${age_min} min (>=${STALL_MIN}) — the fleet is corked, root-cause the dispatch chain NOW (coordinator ticks, capacity gate, CI red, reviewer, router)"
  exit 2
fi
exit 0
