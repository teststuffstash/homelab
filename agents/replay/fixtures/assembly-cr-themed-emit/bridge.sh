# ── bridge ── the per-repo loop variables the changes-requested clause reads.
# Runs AFTER state-fp-jq and state-fp-pair blocks, so pr_state_fp_pair is already defined.
slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
orphans=""
units=""
assembly_cr_prs=""
# ── stubs ── the FU-146 holds and WIP gate are clear.
WIPPODS_JSON='{"items":[]}'
wip_busy=""
sess_holds() { return 1; }
item_class_push() { :; }
# ── override pr_state_fp_pair ── return no recorded marker (first emit, not debounced).
pr_state_fp_pair() {
  printf '%s\n' 'abc123|'
  return 0
}
# ── override goal_resolve_ancestor ── the ancestor walk is tested by the goal-ancestor
# fixture family. For this fixture, #1165 (the Fixes-referenced theme) resolves to #1162.
goal_resolve_ancestor() {
  GB_GOAL="1162"
  GB_HOPS=1
  return 0
}
# ── override date ── deterministic timestamp so the state-fp comment body is stable.
date() {
  if [ "$1" = "-u" ] && [ "$2" = "+%Y-%m-%dT%H:%M:%SZ" ]; then
    printf '2026-09-01T12:41:00Z'
  else
    command date "$@"
  fi
}

# ADR-125: `item_class_push` rows carry the item's LANE base. This bridge stubs the push and never
# runs the per-repo pass that records the lane map, so the caller's explicit argument — the repo's
# default branch for aggregate/container rows — is supplied here.
default_branch="${default_branch:-master}"
