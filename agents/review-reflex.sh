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
  # Fail LOUD, never swallow: a `gh pr list` error (e.g. the token lacking checks:read/statuses:read,
  # so `--json statusCheckRollup` 403s) must NOT collapse into an empty list — that silently makes every
  # green PR invisible and the reflex "sees nothing to review" forever. Abort so the pod Fails visibly.
  # --limit 40 (not 50): gh's fixed statusCheckRollup fragment is deep, and GraphQL bills the *static*
  # worst-case node count from the query's first:/last: args (independent of how many PRs actually exist).
  # At 50 that estimate is ~515k > GitHub's 500k cap → hard error; 40 (~412k) always clears it. Bump only
  # in lockstep with this ceiling. 40 open+auto-merge PRs/repo is far beyond anything the agent flow hits.
  errfile="$(mktemp)"
  if ! prs="$(gh pr list --repo "$slug" --state open --limit 40 \
      --json number,createdAt,isDraft,mergeStateStatus,reviewDecision,autoMergeRequest,statusCheckRollup,reviews,commits,labels \
      2>"$errfile")"; then
    log "[$repo] FATAL: gh pr list failed — aborting rather than silently reviewing nothing:"
    cat "$errfile" >&2
    rm -f "$errfile"
    exit 1
  fi
  rm -f "$errfile"

  # Reviewable = (armed ∨ `major`-labelled) ∧ not-behind ∧ not-conflicted ∧ GREEN
  #              ∧ ( unreviewed OR changes-requested-with-new-commits ) ∧ NOT `automerge`-labelled.
  #   green: every check present is a success-equivalent AND at least one check ran (never rubber-stamp a no-CI PR).
  #   BEHIND → updater's job; DIRTY → conflict (coordinator's job); APPROVED → already merging.
  #   `automerge` label = the MECHANICAL path (Renovate trivial/digest/dev-dep bumps auto-approved by the
  #   renovate-approve reflex, CI-only, no LLM). Skip them so the reviewer isn't burned on digest noise.
  #   Renovate's REVIEWABLE bumps carry `deps-review` (not `automerge`) → they fall through here and get
  #   the LLM reviewer like any agent PR (FU-046; docs/renovate.md + docs/agents/merge-path.md).
  #   `major` label (devbox-update.sh major gate, FU-022) = a HUMAN-GATED bump: deliberately NOT armed
  #   (a human merges), but it STILL needs the reviewer's migration investigation → we accept it here even
  #   un-armed. Its review documents the migration; approval does NOT merge it (no auto-merge armed).
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
      | select(([ .labels[]?.name ] | index("automerge")) | not)
      | select(.autoMergeRequest != null or (([ .labels[]?.name ] | index("major")) != null))
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
