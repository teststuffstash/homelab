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
#   4. A STACK-repo PR parked on the codeowner gate: bot APPROVED at head + CI green, yet
#      reviewDecision still REVIEW_REQUIRED — that combination means require_code_owner_review
#      matched a CODEOWNERS path (specs/ or .agents/) and only the delegated codeowner read
#      unparks it. The review reflex correctly refuses to re-review an approved head, so NO
#      machinery announces this state: oracle-fleet#217 sat 17h (2026-08-08) with every reviewer
#      tick logging "nothing to review". ⚠ reviews[], NOT latestReviews[]: a bot that APPROVEs
#      and then posts a COMMENTED aside makes its latest review non-APPROVED and hid PR#235's
#      park for ~14h (2026-08-09) — a dismissed approval reads DISMISSED, so reviews[] is safe. Repos = the require_code_owner_review=true set in
#      tofu/github/variables.tf minus the platform lane (which clauses 1/park cover).
#   3. An UNLABELED issue on a platform repo older than a day — invisible to every clause (the
#      loop dispatches on agent-fix∧agent/queued; the debounce rings on responder verdict lines;
#      neither ever sees it). Five agent-runtime issues sat this way for up to a MONTH
#      (2026-08-08, operator catch) because only homelab's board got swept. Emission = triage it.
#      ⚠ Responder alert-record issues (body carries 'alert-fp:') are EXCLUDED: unlabeled is
#      their design and the fp/subject belts own their whole lifecycle — clause 3 flagged the
#      reopened #108 on its first day and would re-flag every report-only record forever.
# Each distinct line emits once per process lifetime; restart the monitor to re-baseline.
# Poll is 10 min — this watches for HUMAN-latency states, not machine ones.
cd /workspace/homelab || { echo "PROBE-FAIL: repo missing"; exit 1; }
PLATFORM_REPOS="${PLATFORM_REPOS:-homelab agent-runtime agent-coordinator openrouter-operator}"
# Clause-1 split — delegated to agents/reviewer-optout.sh, THE one read of the stack-level
# `spec.reviewer.enabled` knob (homelab#204/#212). This file briefly carried its own inline jq
# derivation (2026-08-09 morning, replacing a stale static split that had hidden PR#54 for 10h)
# — making it the THIRD independent reader of the knob on the day the shared read merged; the
# #212 reviewer's follow-up caught it. `--filter` prints the repos a reviewer IS coming for;
# GATED = everything else. The shared read is fail-CLOSED (unknown is not permission), which
# lands here as ALL-GATED on a claims probe failure — a false flag costs a glance, a false
# exemption cost 10 hours; both tools want the same direction.
GATED_REPOS=""
LANE_REPOS=""
derive_split() {
  local enabled
  enabled=$(bash "$(dirname "$0")/reviewer-optout.sh" --filter $PLATFORM_REPOS 2>/dev/null)
  GATED_REPOS=""; LANE_REPOS=""
  for r in $PLATFORM_REPOS; do
    case " $(printf '%s' "$enabled" | tr '\n' ' ') " in
      *" $r "*) LANE_REPOS="$LANE_REPOS $r";;
      *) GATED_REPOS="$GATED_REPOS $r";;
    esac
  done
}
# require_code_owner_review=true stack repos (tofu/github/variables.tf) — clause 4.
CODEOWNER_REPOS="${CODEOWNER_REPOS:-oracle-fleet circles}"
seen=""
while true; do
  out=""
  derive_split
  for r in $GATED_REPOS; do
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
  for r in $LANE_REPOS; do
    # Green-checks filter added after the first live emission (PR#44, 2026-08-08): approved with
    # CI still RUNNING is auto-merge doing its job, not a park — only approved+green+still-open
    # means the codeowner gate is what's holding it.
    rows=$(devbox run -- gh pr list -R "teststuffstash/$r" --state open \
             --json number,latestReviews,statusCheckRollup,isDraft 2>/dev/null | tail -1 \
           | jq -r --arg r "$r" '.[] | select(.isDraft|not)
               | select([.latestReviews[]? | select(.state == "APPROVED")] | length > 0)
               | select([.statusCheckRollup[]? | select(.status != "COMPLETED")] | length == 0)
               | select([.statusCheckRollup[]? | select(.conclusion != null
                   and .conclusion != "SUCCESS" and .conclusion != "NEUTRAL"
                   and .conclusion != "SKIPPED")] | length == 0)
               | "NEEDS-META codeowner-park: \($r)#\(.number) bot-approved, CI green, waiting on the human gate"' 2>/dev/null)
    [ -n "$rows" ] && out="$out$rows"$'\n'
  done
  # Clause 4: stack-repo codeowner park — approved head + rd STILL REVIEW_REQUIRED is the
  # require_code_owner_review signature (a bot approval never satisfies it). reviews[] scanned in
  # FULL: an approve-then-comment bot sequence makes latestReviews non-APPROVED and hid PR#235's
  # park ~14h; a dismissed approval reads DISMISSED, so the full scan stays safe.
  # ⚠ CHECKS ARE READ VIA THE ACTIONS API, NEVER statusCheckRollup (PR#250 sat unflagged,
  # operator catch 2026-08-09): requesting statusCheckRollup in the SAME query hard-fails the
  # whole call on oracle-fleet — fine-grained PATs have NO Checks permission AT ALL (operator:
  # "we have been down this road multiple times"), app-created check runs are unreadable by
  # construction, and gh exits 1 with zero stdout, so the clause saw NO PRs (the 403 read as
  # "no parks": the dead-probe class inside the park-catcher). What the PAT DOES have is
  # Actions:read, and every required check here IS a workflow run — so the head sha's state
  # comes from `gh run list --commit`. The park signature alone is strong enough to emit; the
  # run state is an ANNOTATION, and an unreadable one says so instead of suppressing.
  for r in $CODEOWNER_REPOS; do
    parks=$(devbox run -- gh pr list -R "teststuffstash/$r" --state open \
             --json number,reviewDecision,reviews,isDraft 2>/dev/null | tail -1 \
           | jq -r '.[] | select(.isDraft|not)
               | select(.reviewDecision == "REVIEW_REQUIRED")
               | select([.reviews[]? | select(.state == "APPROVED")] | length > 0)
               | .number' 2>/dev/null)
    for n in $parks; do
      cstate="run state unreadable"
      hsha=$(devbox run -- gh pr view "$n" -R "teststuffstash/$r" --json headRefOid 2>/dev/null | tail -1 | jq -r '.headRefOid // ""' 2>/dev/null)
      if [ -n "$hsha" ]; then
        cj=$(devbox run -- gh run list -R "teststuffstash/$r" --commit "$hsha" --json status,conclusion 2>/dev/null | tail -1)
        if [ -n "$cj" ] && jq -e . >/dev/null 2>&1 <<<"$cj"; then
          if jq -e '[.[] | select(.status != "completed" or (.conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped"))] | length == 0 and length > 0' >/dev/null 2>&1 <<<"$cj"; then
            cstate="workflows green"
          else
            continue # red/pending workflows — auto-merge or the ci-red lane owns it, not a park
          fi
        fi
      fi
      out="$out""NEEDS-META codeowner-gate: ${r}#${n} bot-approved + REVIEW_REQUIRED (${cstate}) — a specs/.agents path needs the delegated codeowner read"$'\n'
    done
  done
  blocked=$(devbox run -- gh api "search/issues?q=org:teststuffstash+is:issue+is:open+label:agent/blocked" 2>/dev/null | tail -1 \
    | jq -r '.items[]? | "NEEDS-META blocked: \(.repository_url | sub(".*/";""))#\(.number) \(.title[:60])"' 2>/dev/null)
  [ -n "$blocked" ] && out="$out$blocked"$'\n'
  # Clause 3: unlabeled platform-repo issues >24h — no agent-* label at all means no clause can
  # ever reach them. Renovate's dashboard issue is the one legitimate permanent resident.
  for r in $PLATFORM_REPOS; do
    unl=$(devbox run -- gh issue list -R "teststuffstash/$r" --state open \
            --json number,title,labels,createdAt,body 2>/dev/null | tail -1 \
          | jq -r --arg r "$r" --arg cutoff "$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
              '.[] | select([.labels[].name | select(startswith("agent"))] | length == 0)
                   | select(.createdAt < $cutoff)
                   | select(.title != "Dependency Dashboard")
                   | select(.body | contains("alert-fp:") | not)
                   | "NEEDS-META triage: \($r)#\(.number) unlabeled >24h — invisible to every clause"' 2>/dev/null)
    [ -n "$unl" ] && out="$out$unl"$'\n'
  done
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$seen" in *"|$line|"*) ;; *) echo "$line"; seen="$seen|$line|";; esac
  done <<< "$out"
  sleep 600
done
