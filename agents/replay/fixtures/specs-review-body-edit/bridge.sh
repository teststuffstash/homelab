#!/usr/bin/env bash
# bridge.sh — the specs reviewer's skip, driven through its REAL blocks: the classify/JQ_PRELUDE
# block and the fetch block, extracted by sentinel from agents/specs-reviewer-session.sh, with the
# ONE lastEditedAt home (agents/pr-last-edited.sh) sourced as-is. lastEditedAt is NOT in the listed
# PRs (gh has no such field); it arrives only through the fake `gh api graphql` (world sr-3444).
set -euo pipefail
SRC="${REPLAY_ROOT:?REPLAY_ROOT unset — the replay harness exports it}/agents/specs-reviewer-session.sh"
block() {
  local b; b="$(sed -n "/# >>>REPLAY:$1>>>/,/# <<<REPLAY:$1<<</p" "$SRC")"
  if [ -z "$(printf '%s' "$b" | tr -d '[:space:]')" ]; then
    echo "bridge: EMPTY $1 extraction from $SRC — sentinel block missing or moved" >&2
    exit 1
  fi
  printf '%s' "$b"
}
CLASSIFY_BLOCK="$(block specs-reviewable-again)"
FETCH_BLOCK="$(block specs-last-edited)"
. "${REPLAY_ROOT}/agents/pr-last-edited.sh"
SPECS_REVIEWER_LOGIN="homelab-specs-reviewer"; CODE_REVIEWER_LOGIN="homelab-reviewer"
ORG="teststuffstash"; repo="homelab"
eval "$CLASSIFY_BLOCK"
prs="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
eval "$FETCH_BLOCK"
while IFS= read -r pr_json; do
  printf '#%s %s\n' "$(jq -r .number <<< "$pr_json")" "$(classify "$pr_json")"
done < <(jq -c '.[]' <<< "$prs")
