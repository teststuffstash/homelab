#!/usr/bin/env bash
# review-reflex — the deterministic SCHEDULER half of the merge path (FU-041, docs/agents/merge-path.md
# §Chosen design ▸3). NOT a second controller: it is the coordinator subsystem's mechanical transition
# "PR is green + current + unapproved → dispatch a reviewer", extracted so it never costs an LLM turn.
#
# Runs on a ~5-min CronJob in ns agent-coordinator (agents/coordinator/review-reflex.yaml). Each tick,
# LEVEL-TRIGGERED (re-lists the world; holds no state):
#   1. reap finished reviewer pods (restartPolicy: Never leaves them Completed/Failed).
#   2. per repo, pick the OLDEST PR that is armed ∧ green ∧ not-behind ∧ not-conflicted ∧ reviewable
#      (unreviewed, OR changes-requested with new commits since the last review).
#   3. dispatch reviewer-session.sh for it — ONE per repo (reviews serialize within a repo so a merge
#      never stales a sibling's fresh approval; see merge-path.md §Why update-before-review), capped at
#      K concurrent reviewer pods GLOBALLY (protects the shared operator subscription quota).
# Anything it can't mechanically progress (conflict, changes-requested-no-new-commits, red) it leaves for
# the updater workflow or the coordinator — it only ever dispatches a review, never merges or decides.
#
# Idempotency: a reviewer pod carries labels app=agent-reviewer,project=<repo>,pr=<n> (set by
# reviewer-session.sh). We skip a PR that already has a live reviewer pod, and reviewer Jobs are the
# unit of at-most-once dispatch (concurrencyPolicy: Forbid on the CronJob prevents overlapping ticks).
#
#   Env (all optional): AGENT_REPOS="sleep-tracking snore-recorder"  ORG=teststuffstash
#                       REVIEW_CONCURRENCY=2  REVIEWER_NS=agent-coordinator
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ORG="${ORG:-teststuffstash}"
REPOS="${AGENT_REPOS:-sleep-tracking snore-recorder}"
K="${REVIEW_CONCURRENCY:-2}"
NS="${REVIEWER_NS:-agent-coordinator}"
KUBECTL="$(command -v kubectl || echo kubectl)"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# 1. Reap finished reviewer pods so the "already under review?" check below stays accurate and the
#    namespace doesn't fill up (a completed pod's verdict already lives in the PR's state).
for phase in Succeeded Failed; do
  "$KUBECTL" -n "$NS" delete pod -l app=agent-reviewer \
    --field-selector "status.phase==${phase}" --ignore-not-found >/dev/null 2>&1 || true
done

dispatch=()   # "repo pr" pairs, at most one per repo per tick

for repo in $REPOS; do
  slug="$ORG/$repo"
  prs="$(gh pr list --repo "$slug" --state open --limit 50 \
      --json number,createdAt,isDraft,mergeStateStatus,reviewDecision,autoMergeRequest,statusCheckRollup,reviews,commits \
      2>/dev/null || echo '[]')"

  # Reviewable = armed ∧ not-behind ∧ not-conflicted ∧ GREEN ∧ ( unreviewed OR changes-requested-with-new-commits ).
  #   green: every check present is a success-equivalent AND at least one check ran (never rubber-stamp a no-CI PR).
  #   BEHIND → updater's job; DIRTY → conflict (coordinator's job); APPROVED → already merging.
  pick="$(printf '%s' "$prs" | jq -r '
    def green:
      ([ .statusCheckRollup[]? | (.conclusion // .state // "") ]) as $c
      | ($c | length) > 0
        and ([ $c[] | select(. != "SUCCESS" and . != "NEUTRAL" and . != "SKIPPED") ] | length) == 0;
    def newest_review_at:
      ([ .reviews[]? | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") | .submittedAt ] | max) // "";
    def newest_commit_at:
      ([ .commits[]?.committedDate ] | max) // "";
    def reviewable_again:
      (.reviewDecision == "CHANGES_REQUESTED") and (newest_commit_at > newest_review_at);
    [ .[]
      | select(.isDraft | not)
      | select(.autoMergeRequest != null)
      | select(.mergeStateStatus != "BEHIND" and .mergeStateStatus != "DIRTY")
      | select(green)
      | select((.reviewDecision // "") != "APPROVED")
      | select(((.reviewDecision // "") != "CHANGES_REQUESTED") or reviewable_again)
    ] | sort_by(.createdAt) | (.[0].number // empty)
  ')"

  [ -n "$pick" ] || { log "[$repo] nothing to review"; continue; }

  if "$KUBECTL" -n "$NS" get pods -l "app=agent-reviewer,project=${repo},pr=${pick}" \
        --no-headers 2>/dev/null | grep -q .; then
    log "[$repo] PR #$pick already under review — skip"
    continue
  fi

  dispatch+=("$repo $pick")
done

[ "${#dispatch[@]}" -gt 0 ] || { log "no PRs to dispatch this tick"; exit 0; }

# Dispatch, capped at K concurrent reviewer sessions globally. reviewer-session.sh blocks until its pod
# finishes (~4-8 min), so background them and gate with `wait -n`.
running=0
for pair in "${dispatch[@]}"; do
  # shellcheck disable=SC2086
  set -- $pair; repo="$1"; pr="$2"
  log "→ dispatch reviewer: ${repo} #${pr}"
  bash "$HERE/reviewer-session.sh" "$repo" "$pr" &
  running=$((running + 1))
  if [ "$running" -ge "$K" ]; then wait -n || true; running=$((running - 1)); fi
done
wait
log "reflex tick done"
