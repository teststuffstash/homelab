#!/usr/bin/env bash
# Wait a single PR through the bot-review cycle — the per-PR primitive of the subagent workflow
# (ADR-107 charter §build mode; the 2026-08-12 worktree protocol's "wait" leg made a script).
#
# The platform already does the hard half: on this repo an ARMED PR is picked up by the review
# edge (github-exporter → Sensor → reviewer) with no doorbell to ring — measured 2026-08-13 at
# ~5–9 min open→merged across five PRs. What a subagent (or a seat watch) needs is only a
# blocking wait with a TYPED outcome it can act on:
#
#   bash scripts/pr-wait.sh <pr> [--repo owner/name] [--timeout s] [--interval s] [--no-arm]
#
#   exit 0  MERGED                  — done; caller returns to master
#   exit 2  CHANGES_REQUESTED       — newest review body printed between REVIEW-BEGIN/END
#                                     markers; caller fixes IN CONTEXT, pushes, re-invokes
#                                     (the new commit re-enters the reflex path by itself)
#   exit 3  CLOSED unmerged         — a human acted; caller stops and reports
#   exit 4  CI RED at head          — failing run id+name printed; `gh run view --log-failed <id>`
#   exit 5  timeout                 — nothing conclusive; caller reports, never spins
#
# ⚠ PAT trap (memory: jail-pat-no-checks-permission): fine-grained PATs have NO Checks scope —
# `statusCheckRollup` in a `gh pr view --json` HARD-FAILS the whole call. CI state is read via
# `gh run list --commit <head>` (Actions:read) instead; never add statusCheckRollup here.
set -euo pipefail

PR="${1:?usage: pr-wait <pr-number> [--repo owner/name] [--timeout s] [--interval s] [--no-arm]}"; shift
REPO="teststuffstash/homelab"; TIMEOUT=1800; INTERVAL=30; ARM=1
while [ $# -gt 0 ]; do case "$1" in
  --repo) REPO="$2"; shift 2;; --timeout) TIMEOUT="$2"; shift 2;;
  --interval) INTERVAL="$2"; shift 2;; --no-arm) ARM=0; shift;;
  *) echo "pr-wait: unknown flag $1" >&2; exit 64;;
esac; done

# Arm idempotently — the reflex only reviews armed PRs, and forgetting this is the one silent
# way to wait forever. Failure is non-fatal (already armed / already merged).
[ "$ARM" = 0 ] || gh pr merge "$PR" --repo "$REPO" --auto --squash >/dev/null 2>&1 || true

deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  view="$(gh pr view "$PR" --repo "$REPO" --json state,reviewDecision,headRefOid 2>/dev/null)" \
    || { echo "pr-wait: gh pr view failed (auth? repo?)" >&2; exit 64; }
  state="$(printf '%s' "$view" | jq -r .state)"
  decision="$(printf '%s' "$view" | jq -r '.reviewDecision // ""')"
  head="$(printf '%s' "$view" | jq -r .headRefOid)"
  echo "pr-wait: $(date -u +%H:%M:%S) #${PR} ${state}/${decision:-—}"

  case "$state" in
    MERGED) echo "pr-wait: MERGED"; exit 0;;
    CLOSED) echo "pr-wait: CLOSED unmerged — a human acted; stop and report"; exit 3;;
  esac

  if [ "$decision" = "CHANGES_REQUESTED" ]; then
    echo "pr-wait: CHANGES_REQUESTED — newest review body follows"
    echo "----REVIEW-BEGIN----"
    gh api "/repos/${REPO}/pulls/${PR}/reviews?per_page=100" \
      --jq '[.[] | select(.state == "CHANGES_REQUESTED")] | last | .body' 2>/dev/null || true
    echo "----REVIEW-END----"
    exit 2
  fi

  # CI at head, via Actions:read (see the PAT trap above). in_progress/queued = keep waiting.
  red="$(gh run list --repo "$REPO" --commit "$head" \
          --json databaseId,name,status,conclusion \
          --jq '[.[] | select(.status == "completed" and .conclusion == "failure")] | first // empty' \
          2>/dev/null || true)"
  if [ -n "$red" ]; then
    echo "pr-wait: CI RED at head — $(printf '%s' "$red" | jq -r '"run \(.databaseId) (\(.name))"')"
    echo "pr-wait: read it with: gh run view --repo ${REPO} --log-failed $(printf '%s' "$red" | jq -r .databaseId)"
    exit 4
  fi

  [ "$(date +%s)" -lt "$deadline" ] || { echo "pr-wait: timeout after ${TIMEOUT}s — report, don't spin"; exit 5; }
  sleep "$INTERVAL"
done
