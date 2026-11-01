# ── bridge ── the per-repo loop variables the changes-requested clause reads.
# Runs AFTER state-fp-jq and state-fp-pair blocks: pr_state_fp_pair is the REAL one, its
# `gh pr view 309` served from world/gh/pr-view-309.json.
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
