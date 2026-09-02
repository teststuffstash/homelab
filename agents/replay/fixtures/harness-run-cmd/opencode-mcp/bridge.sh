# ── bridge ── same as harness-run-cmd-opencode, but with MCP_ENDPOINT and MCP_TOOLS set so the
# MCP attach block fires. The endpoint and tools match the oracle stack's claim
# (slo.endpoint: https://mcp.oracle.teststuff.net/mcp, tools: statute, search, give_feedback).
# The opencode RUN_CMD is unchanged — MCP is delivered via OPENCODE_CONFIG (merged into the
# session config in the opencode-session-config block), not a CLI flag.
CTX_PRELUDE=""
RECIPE_B64="UkVDSVBF"
ISSUE_N="19"
HARNESS="opencode"
OPENCODE_MODEL="openrouter/deepseek/deepseek-v4-flash"
RUN_CMD=""
MCP_ENDPOINT="https://mcp.oracle.teststuff.net/mcp"
MCP_TOOLS='["statute","search","give_feedback"]'