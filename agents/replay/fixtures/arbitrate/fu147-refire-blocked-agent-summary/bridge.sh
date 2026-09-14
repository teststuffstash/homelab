# ── bridge ── read the recorded world data for the jq-based no-op predicate test.
# This fixture tests the NOOP_ROUND_JQ directly against a recorded PR world (comments + commits),
# not through the changes-requested clause. The `prjson` variable is consumed by post.sh.
prjson="$(cat "$REPLAY_WORLD/gh/pr-view.json")"