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
# Circuit breaker (2026-07-12, after the oracle-fleet#13 loop): PRs labelled `agent/error` are
# invisible to the reflex, and the reflex itself trips that label (+ an AGENT_ERROR comment) when a
# picked PR carries verdict counts no legitimate pick can have — see the breaker block below. A
# human removes the label to resume. Independent backstop: the github-exporter's AgentReviewLoop /
# AgentErrorFlagged Prometheus alerts (argocd/resources/github-exporter/).
#
#   Env (all optional): AGENT_REPOS="sleep-tracking snore-recorder"  ORG=teststuffstash
#                       REVIEW_CONCURRENCY=2  REVIEWER_NS=agent-coordinator  REVIEWER_LOGIN=homelab-reviewer
#                       REVIEW_ROUNDS_MAX=8
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ORG="${ORG:-teststuffstash}"
# Repos: explicit AGENT_REPOS wins; else derive ALL stack repos from agents/stacks.json —
# the reflex runs from a fresh homelab clone each tick, so the stack list is always current
# (found live: PR oracle-fleet#5 sat green+armed+unapproved for 90min because this list was
# hardcoded to the sleep repos; TICK-LOG 2026-07-09).
if [ -n "${AGENT_REPOS:-}" ]; then
  REPOS="$AGENT_REPOS"
else
  _HERE=$(cd "$(dirname "$0")" && pwd)
  REPOS=$(jq -r '.stacks[].repos[]' "$_HERE/stacks.json" 2>/dev/null | sort -u | tr '
' ' ')
  REPOS="${REPOS:-sleep-tracking snore-recorder}"
fi
K="${REVIEW_CONCURRENCY:-2}"
NS="${REVIEWER_NS:-agent-coordinator}"
REVIEWER_LOGIN="${REVIEWER_LOGIN:-homelab-reviewer}"   # the reviewer App's bot identity
ROUNDS_MAX="${REVIEW_ROUNDS_MAX:-8}"                   # circuit breaker: max bot verdicts per PR, ever
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

  # Reviewable = armed ∧ not-conflicted ∧ GREEN ∧ ( unreviewed OR changes-requested-with-new-commits )
  #              ∧ NOT `automerge`-labelled ∧ ( not-BEHIND unless it's a RE-review ).
  #   green: every check present is a success-equivalent AND at least one check ran (never rubber-stamp a no-CI PR).
  #   BEHIND → updater's job; DIRTY → conflict (coordinator's job); APPROVED → already merging.
  #   "unreviewed" means THE REVIEWER BOT hasn't approved the current head — NOT reviewDecision !=
  #   APPROVED. On code-owner-gated repos (oracle-fleet: /specs/ + /.agents/ gate on Rasmus,
  #   tofu/github/variables.tf) reviewDecision stays REVIEW_REQUIRED after a bot approval, waiting
  #   for the human; conflating the two re-dispatched a reviewer EVERY tick — 12 duplicate approvals
  #   in 90 min on oracle-fleet#13 until the subscription session limit cut it off (2026-07-12).
  #   A bot approval OLDER than the newest commit doesn't count (new push → genuine re-review), and
  #   a DISMISSED approval doesn't either — so a human can dismiss the bot's review to force one.
  #   BEHIND *re-review* exception (deadlock found live on oracle-fleet#6, 2026-07-09): the adRise
  #   updater refuses any PR with a changes-requested review, so CHANGES_REQUESTED + fix pushed +
  #   master moved = updater waits for the review, reflex waited for the updater — forever. A
  #   re-review may proceed on a BEHIND branch (the verdict is about the fix, not currency);
  #   approval clears changesRequestedReviews → updater updates → fresh CI → auto-merge.
  #   `automerge` label = the MECHANICAL path (Renovate trivial/digest/dev-dep bumps auto-approved by the
  #   renovate-approve reflex, CI-only, no LLM). Skip them so the reviewer isn't burned on digest noise.
  #   Renovate's REVIEWABLE bumps carry `deps-review` (not `automerge`) → they fall through here and get
  #   the LLM reviewer like any agent PR (FU-046; docs/renovate.md + docs/agents/merge-path.md).
  #   ARMING IS THE BOUNDARY: this reflex only ever touches auto-merge-armed PRs. Un-armed `major` devbox
  #   bumps (devbox-update.sh gate, FU-022) are HUMAN-GATED and COORDINATOR-owned — the coordinator
  #   dispatches their investigation review directly (even while red) and hands off to a human; the reflex
  #   must NOT reach across the arming wall for them, or the two would fight over one PR. See merge-path.md.
  pick="$(printf '%s' "$prs" | jq -r --arg bot "$REVIEWER_LOGIN" '
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
    def bot_approved_head:
      ([ .reviews[]?
         | select(((.author.login // "") | sub("\\[bot\\]$"; "")) == $bot)
         | select(.state == "APPROVED")
         | .submittedAt ] | max // "") > newest_commit_at;
    [ .[]
      | select(.isDraft | not)
      | select(([ .labels[]?.name ] | index("automerge")) | not)
      | select(([ .labels[]?.name ] | index("agent/error")) | not)
      | select(.autoMergeRequest != null)
      | select(.mergeStateStatus != "DIRTY")
      | select((.mergeStateStatus != "BEHIND") or reviewable_again)
      | select(green)
      | select((.reviewDecision // "") != "APPROVED")
      | select(((.reviewDecision // "") != "CHANGES_REQUESTED") or reviewable_again)
      | select(bot_approved_head | not)
    ] | sort_by(.createdAt) | .[0] // empty
    # CIRCUIT-BREAKER TELEMETRY rides along with the pick: the bot verdict counts, recomputed from
    # the RAW fields on purpose — the breaker must not share code (or bugs) with the defs above.
    # A stateless level-triggered reflex turns any predicate bug into an infinite dispatcher (the
    # 2026-07-12 oracle-fleet#13 loop: 12 duplicate approvals), so the shell trips agent/error
    # instead of dispatching when the counts are impossible for a legitimate pick.
    | ([ .commits[]?.committedDate ] | max // "") as $head
    | ([ .reviews[]?
         | select((.author.login // "") | startswith($bot))
         | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") ]) as $verdicts
    | ($verdicts | map(select(.submittedAt > $head))) as $at_head
    | "\(.number) \($verdicts | length) \($at_head | length) \([ $at_head[] | select(.state == "APPROVED") ] | length)"
  ')"

  [ -n "$pick" ] || { log "[$repo] nothing to review"; continue; }
  read -r pick v_total v_head v_head_approved <<<"$pick"

  # Breaker: a legit pick has ZERO bot approvals at head (the predicate filters those), <2 bot
  # verdicts at head, and fewer than ROUNDS_MAX verdicts ever (beyond that it's a worker↔reviewer
  # flip-flop — merge-path.md escalation table). Any of these ⇒ label agent/error + one AGENT_ERROR
  # comment, never dispatch. Labelled PRs are filtered before the pick, so this fires ONCE; a human
  # removes the label to resume automation. Label add failing (missing label/scope) is logged loud
  # every tick on purpose — the dispatch is still skipped, and the exporter's AgentReviewLoop alert
  # (github_pull_request_reviews_recent) is the independent backstop.
  if [ "$v_head_approved" -ge 1 ] || [ "$v_head" -ge 2 ] || [ "$v_total" -ge "$ROUNDS_MAX" ]; then
    log "[$repo] BREAKER on #$pick (verdicts: total=$v_total at-head=$v_head approved-at-head=$v_head_approved, max=$ROUNDS_MAX) — agent/error, NOT dispatching"
    if gh pr edit "$pick" --repo "$slug" --add-label "agent/error" >/dev/null 2>&1; then
      gh pr comment "$pick" --repo "$slug" --body "AGENT_ERROR: review-reflex circuit breaker tripped — this PR was selected for review with an impossible state (bot verdicts: ${v_total} total, ${v_head} since the newest commit, ${v_head_approved} of those approvals; rounds cap ${ROUNDS_MAX}). Automation now skips this PR. A human: inspect the review thread + reflex logic, then remove the \`agent/error\` label to resume." >/dev/null 2>&1 \
        || log "[$repo] WARN: breaker comment on #$pick failed"
    else
      log "[$repo] WARN: could not add agent/error to #$pick (label missing on repo? token scope?) — dispatch still skipped"
    fi
    continue
  fi

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
