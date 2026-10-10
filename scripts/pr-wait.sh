#!/usr/bin/env bash
# Wait a single PR through the bot-review cycle — the per-PR primitive of the subagent workflow
# (ADR-107 charter §build mode; the 2026-08-12 worktree protocol's "wait" leg made a script).
#
# The platform already does the hard half: on this repo an ARMED PR is picked up by the review
# edge (github-exporter → Sensor → reviewer) with no doorbell to ring — measured 2026-08-13 at
# ~5–9 min open→merged across five PRs. What a subagent (or a seat watch) needs is only a
# blocking wait with a TYPED outcome it can act on:
#
#   bash scripts/pr-wait.sh <pr> [<pr> …] [--repo owner/name] [--timeout s] [--interval s] [--no-arm]
#
# SEVERAL PRs = ONE call (2026-10-04): every PR is polled each round and the FIRST actionable
# outcome on ANY of them exits, prefixed `#<pr>`; a merged PR drops out, exit 0 only when ALL have
# merged. Never chain single waits (`pr-wait A; pr-wait B`) — the seat did, and #2207 sat CI-red
# unseen for the whole of A's wait. Run it in the background WITHOUT `| tail` — the per-poll
# lines are the liveness signal, and a tail hides them until exit.
#
#   exit 0  MERGED                  — done (all of them); caller returns to master
#   exit 2  CHANGES_REQUESTED       — newest review body printed between REVIEW-BEGIN/END
#                                     markers; caller fixes IN CONTEXT, pushes, re-invokes
#                                     (the new commit re-enters the reflex path by itself)
#   exit 3  CLOSED unmerged         — a human acted; caller stops and reports
#   exit 4  CI RED at head          — failing run id+name printed; `gh run view --log-failed <id>`;
#                                     or a failing COMMIT STATUS (management-sentinel et al.)
#   exit 5  timeout                 — nothing conclusive; caller reports, never spins
#   exit 6  MERGE CONFLICT          — `mergeable: CONFLICTING` on two consecutive polls (GitHub
#                                     says UNKNOWN while it recomputes); the reviewer never
#                                     re-reviews a dirty head, so without this the wait could only
#                                     time out (#2206, 2026-10-04: dirty the moment #2205 merged).
#                                     Caller rebases onto master, pushes, re-invokes.
#
# ⚠ PAT trap (memory: jail-pat-no-checks-permission): fine-grained PATs have NO Checks scope —
# `statusCheckRollup` in a `gh pr view --json` HARD-FAILS the whole call. CI state is read via
# `gh run list --commit <head>` (Actions:read) instead; never add statusCheckRollup here.
set -euo pipefail

usage='usage: pr-wait <pr> [<pr> …] [--repo owner/name] [--timeout s] [--interval s] [--no-arm]'
REPO="teststuffstash/homelab"; TIMEOUT=1800; INTERVAL=30; ARM=1; PRS=()
while [ $# -gt 0 ]; do case "$1" in
  --repo) REPO="$2"; shift 2;; --timeout) TIMEOUT="$2"; shift 2;;
  --interval) INTERVAL="$2"; shift 2;; --no-arm) ARM=0; shift;;
  [0-9]*) PRS+=("$1"); shift;;
  *) echo "pr-wait: unknown argument $1" >&2; echo "$usage" >&2; exit 64;;
esac; done
[ ${#PRS[@]} -gt 0 ] || { echo "$usage" >&2; exit 64; }
GH="${PR_WAIT_GH:-gh}"   # seam for scripts/pr-wait-test.sh — never a behaviour switch

# Arm idempotently — the reflex only reviews armed PRs, and forgetting this is the one silent
# way to wait forever. Failure is non-fatal (already armed / already merged).
if [ "$ARM" = 1 ]; then for pr in "${PRS[@]}"; do "$GH" pr merge "$pr" --repo "$REPO" --auto --squash >/dev/null 2>&1 || true; done; fi

deadline=$(( $(date +%s) + TIMEOUT ))
declare -A fails=() dirty=()

# check_pr <pr> → rc 0 merged · 1 still waiting · 2/3/4/6 actionable (the exit codes above) ·
# 64 the poll itself failed 5x in a row. Prints its own lines, prefixed with the PR.
check_pr() {
  local pr="$1" view state decision head mergeable review head_at review_at red
  # One transient gh/API failure must not kill a 20-minute wait (proven live 2026-08-13: a
  # single blip at poll ~4 exited a healthy watch with 64 while the PR went on to a verdict).
  # Consecutive failures are the real signal; a success resets the count.
  if ! view="$("$GH" pr view "$pr" --repo "$REPO" --json state,reviewDecision,headRefOid,mergeable 2>/dev/null)"; then
    fails[$pr]=$(( ${fails[$pr]:-0} + 1 ))
    [ "${fails[$pr]}" -lt 5 ] || { echo "pr-wait: #${pr} gh pr view failed ${fails[$pr]}x consecutively (auth? repo?)" >&2; return 64; }
    echo "pr-wait: $(date -u +%H:%M:%S) #${pr} poll failed (${fails[$pr]}/5) — retrying" >&2
    return 1
  fi
  fails[$pr]=0
  state="$(printf '%s' "$view" | jq -r .state)"
  decision="$(printf '%s' "$view" | jq -r '.reviewDecision // ""')"
  head="$(printf '%s' "$view" | jq -r .headRefOid)"
  mergeable="$(printf '%s' "$view" | jq -r '.mergeable // ""')"
  echo "pr-wait: $(date -u +%H:%M:%S) #${pr} ${state}/${decision:-—}${mergeable:+/$mergeable}"

  case "$state" in
    MERGED) echo "pr-wait: #${pr} MERGED"; return 0;;
    CLOSED) echo "pr-wait: #${pr} CLOSED unmerged — a human acted; stop and report"; return 3;;
  esac

  if [ "$mergeable" = CONFLICTING ]; then
    dirty[$pr]=$(( ${dirty[$pr]:-0} + 1 ))
    if [ "${dirty[$pr]}" -ge 2 ]; then
      echo "pr-wait: #${pr} MERGE CONFLICT with its base — rebase onto it, push, re-invoke (no review comes for a dirty head)"
      return 6
    fi
  else
    dirty[$pr]=0
  fi

  if [ "$decision" = "CHANGES_REQUESTED" ]; then
    # ⚠ reviewDecision does NOT clear on a push — a CHANGES_REQUESTED verdict survives new
    # commits until the bot re-reviews, so the primary caller loop (fix → push → re-invoke)
    # would otherwise be handed its own already-addressed feedback on the first poll. Same
    # staleness class review-reflex.sh guards with `reviewable_again` (reviewer catch, PR#412
    # r1): a verdict is actionable only if it was submitted AFTER the current head's commit.
    review="$("$GH" api "/repos/${REPO}/pulls/${pr}/reviews?per_page=100" \
      --jq '[.[] | select(.state == "CHANGES_REQUESTED")] | last | {submitted_at, body}' 2>/dev/null || true)"
    head_at="$("$GH" api "/repos/${REPO}/commits/${head}" --jq '.commit.committer.date' 2>/dev/null || true)"
    review_at="$(printf '%s' "$review" | jq -r '.submitted_at // ""' 2>/dev/null || true)"
    if [ -n "$review_at" ] && [ -n "$head_at" ] && [ "$review_at" \> "$head_at" ]; then
      echo "pr-wait: #${pr} CHANGES_REQUESTED (verdict ${review_at} > head ${head_at}) — review body follows"
      echo "----REVIEW-BEGIN----"
      printf '%s' "$review" | jq -r '.body // ""'
      echo "----REVIEW-END----"
      return 2
    fi
    echo "pr-wait: #${pr} stale CHANGES_REQUESTED (verdict ${review_at:-?} ≤ head ${head_at:-?}) — re-review pending, waiting"
  fi

  # CI at head, via Actions:read (see the PAT trap above). in_progress/queued = keep waiting.
  red="$("$GH" run list --repo "$REPO" --commit "$head" \
          --json databaseId,name,status,conclusion \
          --jq '[.[] | select(.status == "completed" and .conclusion == "failure")] | first // empty' \
          2>/dev/null || true)"
  if [ -n "$red" ]; then
    echo "pr-wait: #${pr} CI RED at head — $(printf '%s' "$red" | jq -r '"run \(.databaseId) (\(.name))"')"
    echo "pr-wait: read it with: gh run view --repo ${REPO} --log-failed $(printf '%s' "$red" | jq -r .databaseId)"
    return 4
  fi
  # COMMIT STATUSES at head too (2026-10-04): `management-sentinel` (the box) and the other
  # required non-Actions gates post a STATUS, not a run — `gh run list` never sees them, and the
  # drill PR #2209 sat APPROVED + BLOCKED on a red sentinel for this script's whole hour.
  # `|| sred=""`, never `|| true` inside the substitution: on an API error (a 403 rate limit) gh
  # prints the error JSON on STDOUT and exits non-zero, and `|| true` kept that text as a "red
  # status" — two false exit-4 terminals in one seat-subagent run on 2026-10-10 (#2433, #2439).
  # An unreadable status is "not known red": keep waiting, the next poll re-reads.
  sred="$("$GH" api "/repos/${REPO}/commits/${head}/status" \
          --jq '[.statuses[] | select(.state == "failure" or .state == "error")] | first // empty | "\(.context): \(.description)"' \
          2>/dev/null)" || sred=""
  if [ -n "$sred" ]; then
    echo "pr-wait: #${pr} STATUS RED at head — ${sred}"
    echo "pr-wait: read it with: gh pr view ${pr} --repo ${REPO} --comments (the gate's own comment carries the detail)"
    return 4
  fi
  return 1
}

while :; do
  left=()
  for pr in "${PRS[@]}"; do
    rc=0; check_pr "$pr" || rc=$?
    case "$rc" in
      0) ;;                                   # merged — drops out of the set
      1) left+=("$pr") ;;
      *) [ ${#PRS[@]} -gt 1 ] && echo "pr-wait: stopping on #${pr} (exit $rc); still open: $(printf '#%s ' "${PRS[@]}" | sed 's/ $//')"
         exit "$rc" ;;
    esac
  done
  [ ${#left[@]} -gt 0 ] || { [ ${#PRS[@]} -gt 0 ] && echo "pr-wait: MERGED"; exit 0; }
  PRS=("${left[@]}")
  # The deadline is honoured on every round, including rounds that were only poll retries
  # (reviewer catch, PR#427 r1: intermittent failures must not spin past TIMEOUT).
  [ "$(date +%s)" -lt "$deadline" ] || { echo "pr-wait: timeout after ${TIMEOUT}s on $(printf '#%s ' "${PRS[@]}" | sed 's/ $//') — report, don't spin"; exit 5; }
  sleep "$INTERVAL"
done
