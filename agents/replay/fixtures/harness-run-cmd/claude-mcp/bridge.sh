# ── bridge ── same as harness-run-cmd-claude, but with MCP_ENDPOINT and MCP_TOOLS set so the
# MCP prelude block fires. The endpoint and tools match the oracle stack's claim
# (slo.endpoint: https://mcp.oracle.teststuff.net/mcp, tools: statute, search, give_feedback).
# CTX_PRELUDE is empty (same as the claude sibling — no context-repos pilot).
CTX_PRELUDE=""
RECIPE_B64="UkVDSVBF"
ISSUE_N="19"
HARNESS="claude"
MODEL="haiku"
RUN_CMD=""
MCP_ENDPOINT="https://mcp.oracle.teststuff.net/mcp"
MCP_TOOLS='["statute","search","give_feedback"]'