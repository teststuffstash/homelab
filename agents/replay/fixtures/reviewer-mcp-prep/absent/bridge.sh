# ── bridge — seams only, no gate logic. MCP_ENDPOINT and MCP_TOOLS are unset (absent knob).
# PROJECT is set so the fail-closed degrade message is well-formed (though it won't fire here).
HERE="$REPLAY_FIXTURE"
PROJECT="${PROJECT:-test-project}"