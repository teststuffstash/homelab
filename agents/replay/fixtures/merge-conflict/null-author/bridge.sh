# ── bridge ── the per-repo loop variables the merge-conflict clause reads. Same shape as the
# clause fixture's bridge; this family reuses it so the null-author leg differs only in its world.
slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
orphans=""
units=""
