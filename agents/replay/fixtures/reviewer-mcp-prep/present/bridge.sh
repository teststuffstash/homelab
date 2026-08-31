# ── bridge — seams only, no gate logic. Sets MCP_ENDPOINT and MCP_TOOLS matching the oracle
# stack's claim (slo.endpoint: https://mcp.oracle.teststuff.net/mcp, tools: statute, search,
# give_feedback). PROJECT is set so the fail-closed degrade message is well-formed.
HERE="$REPLAY_FIXTURE"
PROJECT="${PROJECT:-test-project}"
MCP_ENDPOINT="https://mcp.oracle.teststuff.net/mcp"
MCP_TOOLS='["statute","search","give_feedback"]'