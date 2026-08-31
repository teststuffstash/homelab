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
#      park for ~14h (2026-08-09) — a dismissed approval reads DISMISSED, so reviews[] is safe.
#      Repos = the FULL require_code_owner_review=true set in tofu/github/variables.tf —
#      platform lane included since the 2026-08-11 bot-reviewer enable (see CODEOWNER_REPOS).
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
# require_code_owner_review=true repos (tofu/github/variables.tf) — clause 4. Since 2026-08-11
# this INCLUDES the platform lane: the bot reviewer is ON there (platform claim), so a homelab/
# agent-runtime/openrouter-operator/agent-coordinator PR now reaches bot-approved+REVIEW_REQUIRED
# — the park state clause 1 (no-review) can no longer see. The old "minus the platform lane"
# note assumed platform PRs never got a bot review; that assumption died with the enable.
CODEOWNER_REPOS="${CODEOWNER_REPOS:-oracle-fleet circles homelab agent-runtime openrouter-operator agent-coordinator}"
seen=""
# --once (meta-events.sh, FU-166(b)): run ONE pass and exit — the consolidated event loop absorbs
# this script as a source; the standing `while true` mode remains for a standalone Monitor.
ONCE=0; [ "${1:-}" = "--once" ] && ONCE=1
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
  # FU-166(a) 2026-08-12: Prometheus is PRIMARY for the park set — the exporter's
  # github_pull_request_codeowner_park series bakes the entire predicate (bot-approved +
  # REVIEW_REQUIRED + green + undrafted; reviews[] not latestReviews[]), so ONE instant query
  # replaces the per-repo gh walks this clause ran every 600s against FU-084's API pool (the
  # one-poller doctrine). The gh loop below is DEMOTED to the probe-fail belt: it runs only
  # when Prometheus is unreachable/unparseable — never both. CodeownerParkWaiting (>30m) is
  # the alert-side twin; this clause stays as the fast jail surface.
  # ⚠ "reachable + empty" is only trustworthy while the COLLECTOR proves itself: pre-#403 (or
  # across an exporter outage) the park series does not exist at all, and an empty answer read
  # as "no parks" made circles#80 FLAP clear/fire against the belt (2026-08-12 18:01 — partly
  # the shared-tree branch-hop executing two versions, but the pre-rollout hole was real). The
  # liveness key is a sibling series from the SAME collector walk (`github_pull_request_open` —
  # present whenever the walk ran): sibling absent → the empty park set is a claim about the
  # exporter, not the world → belt. The spend-probe probe_ok pattern, consumer-side.
  pk=$(curl -ksS --max-time 10 'https://prometheus.teststuff.net/api/v1/query' \
        --data-urlencode 'query=github_pull_request_codeowner_park or (count(github_pull_request_open) * 0)' 2>/dev/null)
  if [ -n "$pk" ] && jq -e '.status == "success" and (.data.result | length > 0)' >/dev/null 2>&1 <<<"${pk:-null}"; then
    pkl=$(jq -r '.data.result[]? | select(.metric.repo != null) | "NEEDS-META codeowner-gate: \(.metric.repo)#\(.metric.number) bot-approved + REVIEW_REQUIRED (workflows green) — a specs/.agents path needs the delegated codeowner read"' <<<"$pk" 2>/dev/null)
    [ -n "$pkl" ] && out="$out$pkl"$'\n'
  else
    echo "needs-meta: prometheus unreachable — clause 4 falling back to the direct gh walk (belt)" >&2
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
            # ⚠ jq precedence trap (caught live 2026-08-09, PR#256 park invisible ~1h45m): piping the
            # FILTERED array into `length == 0 and length > 0` tests BOTH lengths on the filtered
            # array — false forever, so every green PR fell into the red-path `continue` and clause 4
            # could never emit when workflows were readable. Keep the original array in $all.
            if jq -e '. as $all | [ $all[] | select(.status != "completed" or (.conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped")) ] | length == 0 and ($all | length) > 0' >/dev/null 2>&1 <<<"$cj"; then
              cstate="workflows green"
            elif jq -e 'length > 0' >/dev/null 2>&1 <<<"$cj"; then
              continue # red/pending workflows — auto-merge or the ci-red lane owns it, not a park
            else
              cstate="no workflow runs on head" # zero runs ≠ red: the park signature still emits
            fi
          fi
        fi
        out="$out""NEEDS-META codeowner-gate: ${r}#${n} bot-approved + REVIEW_REQUIRED (${cstate}) — a specs/.agents path needs the delegated codeowner read"$'\n'
      done
    done
  fi
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
                   | select(.body // "" | test("(^|\\n)alert-fp:") | not)
                   | select(.title | startswith("stint:") | not)
                   # CONTAINERS are label-inert BY DESIGN and legitimately long-lived — flagging
                   # them is the false-positive class the 2026-08-30/31 sessions logged nightly
                   # (#840/#787 post-launch buckets, #949/#1101 retro-batch parents). The
                   # sprout-report-skips-buckets exclusion ported (IL-T17: a bucket is a
                   # CONTAINER, not a work item; retro-batch = the observability-and-retro
                   # section-B2 shape). Lifecycle owners: the goal checkpoint and the retro
                   # predecessor-score sweep, never this triage clause. NO APOSTROPHES in this
                   # comment — it lives inside the single-quoted jq program.
                   | select(.title | startswith("post-launch:") | not)
                   | select(.title | startswith("retro-batch:") | not)
                   | "NEEDS-META triage: \($r)#\(.number) unlabeled >24h — invisible to every clause"' 2>/dev/null)
    [ -n "$unl" ] && out="$out$unl"$'\n'
  done
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$seen" in *"|$line|"*) ;; *) echo "$line"; seen="$seen|$line|";; esac
  done <<< "$out"
  [ "$ONCE" = 1 ] && exit 0
  sleep 600
done
