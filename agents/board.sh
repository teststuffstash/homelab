#!/usr/bin/env bash
# board — the operator's who-acts todo view (platform pilot, 2026-08-17).
#
# A DETERMINISTIC, read-only jail tool (zero LLM; `gh`/`kubectl` reads only) that
# lists ONLY human-actionable items across a stack's repos, grouped by the action
# the operator takes, with ages. Standing backlog renders as AGGREGATE count+oldest
# lines so the same items never re-scroll (operator ruling 2026-08-17); the
# individually-listed classes are those genuinely awaiting the operator's hands.
# No "parking" concept anywhere: `agent/blocked` means technically-blocked (list it),
# suitable-unqueued is ordinary backlog (aggregate it).
#
# Usage: bash agents/board.sh [stack] [--full]
#   stack  — AgentStack name (default: platform)
#   --full — expand the BACKLOG aggregate into per-issue lines
#
# Stack → repo resolution mirrors coordinator-scan.sh: the cluster AgentStack claim
# (.spec.repos[].name) first, agents/stacks.json as the probe-failed belt (one loud
# WARN when the fallback is taken). Repo owner is $ORG (teststuffstash) when an entry
# is bare. Read-only by construction — mutating gh/kubectl verbs are forbidden (the
# repo's scan discipline: GraphQL is a shared rate pool, so exactly one issues list +
# one PR list per repo, never a loop-poll).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
ORG="${ORG:-teststuffstash}"
STACKS_FILE="${STACKS_FILE:-$HERE/stacks.json}"

stack="platform"; full=0
for arg in "$@"; do
  case "$arg" in
    --full) full=1 ;;
    -*) echo "board: unknown flag: $arg" >&2; exit 2 ;;
    *) stack="$arg" ;;
  esac
done

# kubectl discovery (mirrors coordinator-scan.sh): point at the repo kubeconfig when
# present, binary via PATH with a devbox-profile fallback.
if [ -f "$ROOT/tofu/kubeconfig" ]; then KUBE="--kubeconfig $ROOT/tofu/kubeconfig"; else KUBE=""; fi
KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="$ROOT/.devbox/nix/profile/default/bin/kubectl"

# ── stack → repo list ─────────────────────────────────────────────────────────
repos=""
if [ -n "$KUBECTL" ]; then
  kubeout="$($KUBECTL $KUBE get "agentstacks.platform.teststuff.net/$stack" -o json 2>/dev/null)" || kubeout=""
  if [ -n "$kubeout" ]; then
    repos="$(printf '%s' "$kubeout" | jq -r '[.spec.repos[]?.name] | .[]' 2>/dev/null || true)"
  fi
fi
if [ -z "$repos" ]; then
  echo "WARN board: agentstacks read PROBE-FAILED — repos from $STACKS_FILE only" >&2
  repos="$(jq -r --arg s "$stack" '.stacks[] | select(.name==$s) | .repos[]?' "$STACKS_FILE" 2>/dev/null || true)"
fi
if [ -z "$repos" ]; then
  avail="$(jq -r '[.stacks[].name] | join(" ")' "$STACKS_FILE" 2>/dev/null || true)"
  echo "board: unknown stack '$stack' — available stacks: ${avail:-<unreadable stacks.json>}" >&2
  exit 2
fi

# ── per-repo fetch + classification ───────────────────────────────────────────
# jq preamble prepended to every classification filter (age/label/bot logic in one
# place). jq takes ONE program string, so the filter text is concatenated after it.
JQ='def agedays: ((now - (.createdAt | fromdateiso8601)) / 86400 | floor);
def age: agedays as $d | if $d < 1 then "<1d" else "\($d)d" end;
def lab: [.labels[]?.name];
def haslab($l): lab | index($l) != null;
def isbot: (.author.is_bot == true) or (.author.login | test("\\[bot\\]")) or (.author.login | startswith("app/"));
'

sec_review=""; sec_solve=""; sec_triage=""; sec_verdict=""; sec_backlog=""; nback=0; nfail=0
for repo in $repos; do
  case "$repo" in */*) slug="$repo";; *) slug="$ORG/$repo";; esac
  issues="$(gh issue list --repo "$slug" --state open --limit 200 --json number,title,labels,createdAt,author 2>/dev/null)" || issues=""
  jq -e . >/dev/null 2>&1 <<<"${issues:-null}" || issues=""
  if [ -z "$issues" ]; then
    echo "WARN board: $slug issue list PROBE-FAILED — repo skipped (an empty board can be a probe, not a clean queue)" >&2
    issues='[]'; nfail=$((nfail + 1))
  fi
  prs="$(gh pr list --repo "$slug" --state open --limit 100 --json number,title,labels,createdAt,reviewDecision,isDraft,autoMergeRequest,latestReviews 2>/dev/null)" || prs=""
  jq -e . >/dev/null 2>&1 <<<"${prs:-null}" || prs=""
  if [ -z "$prs" ]; then
    echo "WARN board: $slug PR list PROBE-FAILED — repo skipped (an empty board can be a probe, not a clean queue)" >&2
    prs='[]'; nfail=$((nfail + 1))
  fi

  # § REVIEW — bot-approved head still on the human gate (require_code_owner_review
  # holds), plus PRs explicitly parked `major/awaiting-human`.
  rline="$(printf '%s' "$prs" | jq -r --arg repo "$repo" "$JQ"'[
      .[] | select(.isDraft == false) | select(
        ((.reviewDecision == "REVIEW_REQUIRED")
         and ([.latestReviews[]? | select(.state == "APPROVED" and (.author.login | startswith("homelab-reviewer")))] | length > 0))
        or (haslab("major/awaiting-human")))
      | "\($repo)#\(.number) \(.title) (\(age))" ] | unique | .[]')"
  [ -n "$rline" ] && sec_review="${sec_review}${rline}"$'\n'

  # § SOLVE — agent/error anomaly breakers (issues + PRs, FU-069 human-first) and
  # agent/blocked gates (issues); a blocked issue already flagged agent/error shows ⛔ only.
  eline="$(printf '%s' "$issues" | jq -r --arg repo "$repo" "$JQ"'[
      .[] | select(haslab("agent/error")) | "⛔ \($repo)#\(.number) \(.title) (\(age))" ] | unique | .[]')"
  [ -n "$eline" ] && sec_solve="${sec_solve}${eline}"$'\n'
  eline="$(printf '%s' "$prs" | jq -r --arg repo "$repo" "$JQ"'[
      .[] | select(haslab("agent/error")) | "⛔ \($repo)#\(.number) \(.title) (\(age))" ] | unique | .[]')"
  [ -n "$eline" ] && sec_solve="${sec_solve}${eline}"$'\n'
  errn="$(printf '%s' "$issues" | jq -c "$JQ"'[ .[] | select(haslab("agent/error")) | .number ]')"
  bline="$(printf '%s' "$issues" | jq -r --arg repo "$repo" --argjson errn "${errn:-[]}" "$JQ"'[
      .[] | select(haslab("agent/blocked")) | select(.number as $n | ($errn | index($n)) == null)
      | "⏸ \($repo)#\(.number) \(.title) (\(age))" ] | unique | .[]')"
  [ -n "$bline" ] && sec_solve="${sec_solve}${bline}"$'\n'

  # § TRIAGE — bot-authored without agent-fix (🌱), plus zero-label non-bot strays
  # older than a day. `post-launch:` goal buckets are containers, not work — skipped.
  tline="$(printf '%s' "$issues" | jq -r --arg repo "$repo" "$JQ"'[
      .[] | select(.title | startswith("post-launch:") | not)
      | select([lab[] | select(startswith("agent/"))] | length == 0)
      | select(
        (isbot and (haslab("agent-fix") | not))
        or ((isbot | not) and (lab | length == 0) and (agedays >= 1)))
      | "\($repo)#\(.number) \(.title) (\(age))" ] | unique | .[]')"
  [ -n "$tline" ] && sec_triage="${sec_triage}${tline}"$'\n'

  # § VERDICT DUE — goals past assembly-complete (ADR-102) awaiting a post-launch verdict.
  vline="$(printf '%s' "$issues" | jq -r --arg repo "$repo" "$JQ"'[
      .[] | select(haslab("task/goal") and haslab("goal/post-launch"))
      | "\($repo)#\(.number) \(.title) (\(age))" ] | unique | .[]')"
  [ -n "$vline" ] && sec_verdict="${sec_verdict}${vline}"$'\n'

  # § BACKLOG — agent-fix with no agent/* state label: AGGREGATE count + oldest so
  # the same standing items never re-scroll; --full expands beneath.
  bl="$(printf '%s' "$issues" | jq -c "$JQ"'[
      .[] | select(haslab("agent-fix")) | select([lab[] | select(startswith("agent/"))] | length == 0) ]')"
  bcnt="$(printf '%s' "$bl" | jq 'length')"
  if [ "$bcnt" -gt 0 ]; then
    bage="$(printf '%s' "$bl" | jq -r "$JQ"'(
      ([.[].createdAt | fromdateiso8601] | min) as $m
      | ((now - $m) / 86400 | floor) as $d | if $d < 1 then "<1d" else "\($d)d" end)')"
    sec_backlog="${sec_backlog}$repo: $bcnt suitable-unqueued (oldest $bage)"$'\n'
    if [ "$full" = 1 ]; then
      bdet="$(printf '%s' "$bl" | jq -r --arg repo "$repo" "$JQ"'[
        sort_by(.number)[] | "  \($repo)#\(.number) \(.title) (\(age))" ] | .[]')"
      [ -n "$bdet" ] && sec_backlog="${sec_backlog}${bdet}"$'\n'
    fi
    nback=$((nback + bcnt))
  fi
done

# ── render ────────────────────────────────────────────────────────────────────
mrepos="$(printf '%s' "$repos" | wc -w | tr -d ' ')"
echo "board — stack $stack ($mrepos repos) · $(date -u +%Y-%m-%dT%H:%M:%SZ)"

[ -n "$sec_review" ] && { printf '\n§ REVIEW (codeowner queue)\n'; printf '%s' "$sec_review"; }
[ -n "$sec_solve" ] && { printf '\n§ SOLVE (parks & latches)\n'; printf '%s' "$sec_solve"; }
[ -n "$sec_triage" ] && { printf '\n§ TRIAGE\n'; printf '%s' "$sec_triage"; }
[ -n "$sec_verdict" ] && { printf '\n§ VERDICT DUE\n'; printf '%s' "$sec_verdict"; }
[ -n "$sec_backlog" ] && { printf '\n§ BACKLOG (suitable, unqueued)\n'; printf '%s' "$sec_backlog"; }

cnt() { printf '%s' "$1" | grep -c '[^[:space:]]' 2>/dev/null || true; }
nreview="$(cnt "$sec_review")"; nsolve="$(cnt "$sec_solve")"; ntriage="$(cnt "$sec_triage")"; nverdict="$(cnt "$sec_verdict")"
printf '\ntotals — review: %s · solve: %s · triage: %s · verdict-due: %s · backlog: %s\n' \
  "$nreview" "$nsolve" "$ntriage" "$nverdict" "$nback"
if [ "$nfail" -gt 0 ]; then
  echo "⚠ $nfail repo fetch(es) failed — the totals above may be incomplete (see WARN on stderr)"
fi

exit 0
