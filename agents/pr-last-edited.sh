#!/usr/bin/env bash
# pr-last-edited.sh — THE read of `PullRequest.lastEditedAt` (the PR BODY's last edit) for the
# review edge's `reviewable_again` predicate. Sourced by every reader — agents/review-reflex.sh (the
# pick), agents/coordinator-scan.sh (the changes-requested hold) and agents/specs-reviewer-session.sh
# (the specs reviewer's skip) — so the fetch, the merge and the failure posture have one home (the
# changes-requested-body-edit and specs-review-body-edit replay families pin it).
#
#   pr_last_edited_merge <owner/repo> <prs-json-array> [<numbers>]
#       stdout = the array, each asked-about PR gaining .lastEditedAt ("" = never edited). Asked
#       about: the PRs whose .reviewDecision is CHANGES_REQUESTED — or, when <numbers> is passed
#       (whitespace-separated, possibly empty), exactly those: the specs reviewer names the PRs
#       whose live verdict OF ITS OWN is CHANGES_REQUESTED (a per-identity fact reviewDecision
#       cannot carry). Either way the set is PRs under a CHANGES_REQUESTED verdict.
#
# WHY GRAPHQL. `reviewable_again` re-reviews a CHANGES_REQUESTED PR when the newest non-merge commit
# OR the body edit is newer than the newest verdict (homelab#2168). #2333 put `lastEditedAt` into
# `gh pr list/view --json`, but gh has no such field — the call died `Unknown JSON field` and every
# stack's review tick aborted (2026-10-06 23:22Z, quickfix 914b2b3c dropped it), leaving the
# body-edit leg INERT: `.lastEditedAt // ""` was always "". GraphQL has the field; this reads it.
#
# BUDGET (the homelab-agents installation's shared GraphQL pool, FU-290; the specs reviewer spends
# its own installation's pool under the same bound): at most ONE extra query per repo per tick, and
# NONE when the list holds no CHANGES_REQUESTED PR (the only PRs the predicate asks about). One aliased query for exactly those numbers — `p<N>: pullRequest(number: N)` — selects
# only `number lastEditedAt`; no connection is paginated, so it bills the 1-point minimum whatever
# the PR count, and merging BY NUMBER cannot mis-join the way an ordering-dependent list would.
#
# FAILURE POSTURE: DEGRADE, LOUDLY. An unreadable lastEditedAt must not abort the tick — the
# commit-time leg of `reviewable_again` still works without it, and aborting would take the whole
# review edge down for a secondary signal (the 914b2b3c outage, again). So any failure (gh error,
# GraphQL errors, non-JSON) prints the array UNCHANGED (→ .lastEditedAt absent → "" → the
# commit-time rule alone), with one WARN line on stderr naming the degrade. Always exits 0.
pr_last_edited_merge() {
  local slug="$1" prs="$2" nums q raw map
  if [ "$#" -ge 3 ]; then
    # shellcheck disable=SC2086 # word-split on purpose: <numbers> is a whitespace-separated list
    nums="$(printf '%s\n' $3 | grep -E '^[0-9]+$' | sort -un)" || nums=""
  else
    nums="$(printf '%s' "$prs" | jq -r '[.[]? | select((.reviewDecision // "") == "CHANGES_REQUESTED") | .number] | unique | .[]' 2>/dev/null)" || nums=""
  fi
  if [ -z "$nums" ]; then printf '%s' "$prs"; return 0; fi
  q="query(\$owner: String!, \$name: String!) { repository(owner: \$owner, name: \$name) {"
  local n
  for n in $nums; do q="$q p$n: pullRequest(number: $n) { number lastEditedAt }"; done
  q="$q } }"
  if raw="$(gh api graphql -f query="$q" -f owner="${slug%%/*}" -f name="${slug#*/}" 2>&1)" \
     && map="$(printf '%s' "$raw" | jq -ce '
          select((.errors // []) == [] and (.data.repository | type) == "object")
          | [ .data.repository[] | select(. != null) | {key: (.number | tostring), value: (.lastEditedAt // "")} ]
          | from_entries' 2>/dev/null)"; then
    printf '%s' "$prs" | jq -c --argjson m "$map" \
      'map(if $m[(.number | tostring)] != null then .lastEditedAt = $m[(.number | tostring)] else . end)'
    return 0
  fi
  printf 'WARN [%s] lastEditedAt GraphQL read failed — body-edit re-review leg degraded to the commit-time rule this tick: %s\n' \
    "$slug" "$(printf '%s' "$raw" | tr '\n' ' ' | cut -c1-200)" >&2
  printf '%s' "$prs"
  return 0
}
