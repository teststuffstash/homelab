# ── bridge ── the per-repo loop variables the changes-requested clause reads.
slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
orphans=""
units=""
assembly_cr_prs=""
WIPPODS_JSON='{"items":[]}'
wip_busy=""
sess_holds() { return 1; }
item_class_push() { :; }
pr_state_fp_pair() {
  printf '%s\n' 'abc123|'
  return 0
}
date() {
  if [ "$1" = "-u" ] && [ "$2" = "+%Y-%m-%dT%H:%M:%SZ" ]; then
    printf '2026-09-01T12:41:00Z'
  else
    command date "$@"
  fi
}