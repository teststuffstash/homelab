# agents/renovate-currency.sh — the ONE reader of "whose currency is this Renovate PR" (ADR-153),
# sourced by both update-branch call sites that meet Renovate PRs: agents/update-pr-branch.sh (leg 1 +
# leg 2, identity homelab-merge) and coordinator-scan.sh's FU-124 nudge (identity coordinator-git).
# They used to carry two copies of the predicate; the 2026-10-20 zombies (homelab#2754,
# sleep-tracking#203) were made by the NUDGE copy, which the updater-side fix (#2881) did not reach.
#
# THE PREDICATE. A Renovate-authored PR is Renovate's to keep current (rebaseWhen behind-base-branch
# is the org default) while it is UNTOUCHED — every non-merge commit Renovate's — EXCEPT when it is
# merge-ready (armed + approved + GREEN: currency is the only gap, the fast path takes it). A branch a
# worker pushed to is the updater's. And the hand-back: an untouched PR that carries a non-Renovate
# MERGE commit (only an update-branch call writes those) has ALREADY been disowned by Renovate — its
# edited-PR rule counts merge commits — so when it is not merge-ready the caller ticks Renovate's
# rebase/retry box instead of skipping (`renovate_handback`); Renovate's next run rebuilds the branch
# from master + its change and owns the PR again. Same box as the scan's merge-conflict rebase-tick
# (homelab#1977).
#
# THE PROBE IS REST FOR CHECKS (2026-10-24). `gh pr view --json statusCheckRollup` also selects
# `checkSuite.workflowRun`, which needs `actions: read`; homelab-merge carries checks+statuses read
# only, so on every PRIVATE repo the probe failed whole ("Resource not accessible by integration",
# 93–236 "commit probe unreadable" HOLD lines a day in Loki, 10-17 → 10-24) and the updater never
# saw a Renovate PR's checks there. `commits/<sha>/check-runs` (checks: read) + `commits/<sha>/status`
# (statuses: read) are the permissions the App already holds, and they ride the REST pool, not the
# GraphQL one (the FU-290 drain class). The probe emits the rollup shape the predicates read:
# `{commits, statusCheckRollup: [{name, conclusion} | {context, state}]}`, values UPPERCASE; a
# check-run still running reports its status (QUEUED/IN_PROGRESS) as its conclusion — not green.
#
# Callers set nothing; every function takes the repo slug explicitly.

RENOVATE_LOGIN_JQ='def renovate_login: (. // "") | sub("^app/"; "") | sub("\\[bot\\]$"; "") | startswith("homelab-renovate");'

renovate_author() {   # renovate_author <pr-json> → 0 when the PR author is Renovate (every branch, ADR-153)
  jq -e "$RENOVATE_LOGIN_JQ"' (.author.login | renovate_login)' <<<"$1" >/dev/null 2>&1
}

# renovate_probe <slug> <number> <head-oid> → the probe JSON on stdout; non-zero when ANY leg is
# unreadable (the caller HOLDS — rule #6; a half-read is never "not green").
renovate_probe() {
  local commits runs statuses
  commits="$(gh pr view "$2" --repo "$1" --json commits 2>/dev/null)" && jq -e '.commits | type == "array"' <<<"$commits" >/dev/null 2>&1 || return 1
  [ -n "$3" ] || return 1
  runs="$(gh api "repos/$1/commits/$3/check-runs?per_page=100" \
    --jq '[.check_runs[]? | {name, conclusion: ((.conclusion // .status // "") | ascii_upcase)}]' 2>/dev/null)" \
    && jq -e 'type == "array"' <<<"$runs" >/dev/null 2>&1 || return 1
  statuses="$(gh api "repos/$1/commits/$3/status" \
    --jq '[.statuses[]? | {context, state: ((.state // "") | ascii_upcase)}]' 2>/dev/null)" \
    && jq -e 'type == "array"' <<<"$statuses" >/dev/null 2>&1 || return 1
  jq -cn --argjson c "$commits" --argjson r "$runs" --argjson s "$statuses" '{commits: $c.commits, statusCheckRollup: ($r + $s)}'
}

# renovate_green <probe-json> → 0 when every check concluded clean (absent = not green). A CANCELLED
# entry is dropped when a same-named sibling outlives it — a superseded duplicate run (two
# `synchronize` events on one update) is not a red check (#2754's rollup: ci CANCELLED + ci SUCCESS).
renovate_green() {
  jq -e '[ .statusCheckRollup[]? | { k: (.name // .context // ""), c: ((.conclusion // .state) // "") } ]
         | group_by(.k)
         | map(if any(.c != "CANCELLED") then map(select(.c != "CANCELLED")) else . end | .[].c) | flatten as $c
         | ($c | length) > 0 and ([ $c[] | select(. != "SUCCESS" and . != "NEUTRAL" and . != "SKIPPED") ] | length) == 0' <<<"$1" >/dev/null 2>&1
}

renovate_untouched() {   # renovate_untouched <json with commits> → 0 when no foreign non-merge commit
  jq -e "$RENOVATE_LOGIN_JQ"' [ .commits[]? | select(((.messageHeadline // "") | startswith("Merge branch ")) | not)
           | .authors[]? | .login ] | all(renovate_login)' <<<"$1" >/dev/null 2>&1
}

renovate_merged_into() {   # renovate_merged_into <json with commits> → 0 when a non-Renovate MERGE commit is on the branch
  jq -e "$RENOVATE_LOGIN_JQ"' [ .commits[]? | select((.messageHeadline // "") | startswith("Merge branch "))
           | .authors[]? | .login | renovate_login | not ] | any' <<<"$1" >/dev/null 2>&1
}

# renovate_handback <slug> <number> <log-prefix> — tick Renovate's rebase/retry box. FRESH REST body
# read right before the full-body overwrite (Renovate regenerates bodies on its runs — the #2055
# stale-copy finding); REST both ways, never `gh pr edit` (GraphQL — the #2476 drain class). A ticked
# box is left alone (Renovate's next run is the mover); a body without the box, an unreadable body or
# a refused write is a line, never fatal (rule #6; the next pass retries).
renovate_handback() {
  local body new
  if ! body="$(gh api "repos/$1/pulls/$2" --jq '.body // ""' 2>/dev/null)"; then
    echo "$3 #$2 Renovate-authored, merged into, not merge-ready — body unreadable, HOLDING the hand-back (rule #6; the next pass retries)"
    return 0
  fi
  if grep -q -- '- \[x\] <!-- rebase-check -->' <<<"$body"; then
    echo "$3 #$2 Renovate-authored, merged into, not merge-ready — rebase already requested (box ticked); Renovate's next run takes it back"
    return 0
  fi
  if ! grep -q -- '- \[ \] <!-- rebase-check -->' <<<"$body"; then
    echo "$3 #$2 Renovate-authored, merged into, not merge-ready — no rebase checkbox in the body; human check (close + delete the branch, docs/renovate.md)"
    return 0
  fi
  new="$(printf '%s' "$body" | sed 's/- \[ \] <!-- rebase-check -->/- [x] <!-- rebase-check -->/')"
  if gh api -X PATCH "repos/$1/pulls/$2" -f body="$new" >/dev/null 2>&1; then
    echo "$3 #$2 Renovate-authored, merged into, not merge-ready — handed back to Renovate (rebase box ticked; its next run rebuilds the branch)"
  else
    echo "$3 #$2 Renovate-authored, merged into, not merge-ready — could not tick the rebase box; the next pass retries"
  fi
}
