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
# ── override pr_state_fp_pair ── return matching marker (debounced).
# Return "abc123|abc123" (current hash == recorded hash) so the debounce check fires.
pr_state_fp_pair() {
  printf '%s\n' 'abc123|abc123'
  return 0
}
# ── override date ── deterministic timestamp.
date() {
  if [ "$1" = "-u" ] && [ "$2" = "+%Y-%m-%dT%H:%M:%SZ" ]; then
    printf '2026-09-01T12:41:00Z'
  else
    command date "$@"
  fi
}