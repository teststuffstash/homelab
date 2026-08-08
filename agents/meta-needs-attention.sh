#!/bin/bash
# meta-needs-attention — the QUIET meta watch (2026-08-08, replaces the firehose loop watches as
# the default standing monitor; operator: "too many monitors"). Emits ONLY states that require
# META JUDGMENT and that no machinery announces:
#   1. A platform-lane PR sitting CI-green with no review — platform repos have NO bot approver
#      by design, so nothing else will ever pick it up (PR#123 sat 1.5h unseen; the gap that
#      motivated this script).
#   2. An open `agent/blocked` issue anywhere — a recorded human gate. NB the label OUTLIVES its
#      gate (circles#29 kept it after the budget was raised): treat each emission as "re-check
#      the gate this label recorded", not as noise, and clear it with an audit comment when the
#      gate is resolved.
#   3. An UNLABELED issue on a platform repo older than a day — invisible to every clause (the
#      loop dispatches on agent-fix∧agent/queued; the debounce rings on responder verdict lines;
#      neither ever sees it). Five agent-runtime issues sat this way for up to a MONTH
#      (2026-08-08, operator catch) because only homelab's board got swept. Emission = triage it.
# Each distinct line emits once per process lifetime; restart the monitor to re-baseline.
# Poll is 10 min — this watches for HUMAN-latency states, not machine ones.
cd /workspace/homelab || { echo "PROBE-FAIL: repo missing"; exit 1; }
PLATFORM_REPOS="${PLATFORM_REPOS:-homelab agent-runtime agent-coordinator openrouter-operator}"
seen=""
while true; do
  out=""
  for r in $PLATFORM_REPOS; do
    rows=$(devbox run -- gh pr list -R "teststuffstash/$r" --state open \
             --json number,reviewDecision,statusCheckRollup,isDraft 2>/dev/null | tail -1 \
           | jq -r --arg r "$r" '.[] | select(.isDraft|not)
               | select(.reviewDecision == "REVIEW_REQUIRED" or .reviewDecision == null)
               | select([.statusCheckRollup[]? | select(.conclusion != null
                   and .conclusion != "SUCCESS" and .conclusion != "NEUTRAL"
                   and .conclusion != "SKIPPED")] | length == 0)
               | select((.statusCheckRollup | length) > 0)
               | "NEEDS-META review: \($r)#\(.number) CI-green, no reviewer will come"' 2>/dev/null)
    [ -n "$rows" ] && out="$out$rows"$'\n'
  done
  blocked=$(devbox run -- gh api "search/issues?q=org:teststuffstash+is:issue+is:open+label:agent/blocked" 2>/dev/null | tail -1 \
    | jq -r '.items[]? | "NEEDS-META blocked: \(.repository_url | sub(".*/";""))#\(.number) \(.title[:60])"' 2>/dev/null)
  [ -n "$blocked" ] && out="$out$blocked"$'\n'
  # Clause 3: unlabeled platform-repo issues >24h — no agent-* label at all means no clause can
  # ever reach them. Renovate's dashboard issue is the one legitimate permanent resident.
  for r in $PLATFORM_REPOS; do
    unl=$(devbox run -- gh issue list -R "teststuffstash/$r" --state open \
            --json number,title,labels,createdAt 2>/dev/null | tail -1 \
          | jq -r --arg r "$r" --arg cutoff "$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
              '.[] | select([.labels[].name | select(startswith("agent"))] | length == 0)
                   | select(.createdAt < $cutoff)
                   | select(.title != "Dependency Dashboard")
                   | "NEEDS-META triage: \($r)#\(.number) unlabeled >24h — invisible to every clause"' 2>/dev/null)
    [ -n "$unl" ] && out="$out$unl"$'\n'
  done
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$seen" in *"|$line|"*) ;; *) echo "$line"; seen="$seen|$line|";; esac
  done <<< "$out"
  sleep 600
done
