# ── bridge ── same as harness-run-cmd-goose, but with MCP_ENDPOINT and MCP_TOOLS set so the
# MCP prelude block fires. The endpoint and tools match the oracle stack's claim
# (slo.endpoint: https://mcp.oracle.teststuff.net/mcp, tools: statute, search, give_feedback).
CTX_PRELUDE="mkdir -p /work/context; git clone --depth 1 --quiet https://github.com/teststuffstash/circles.git /work/context/circles || echo \"WARN: context clone failed: https://github.com/teststuffstash/circles.git\"; "
RECIPE_B64="UkVDSVBF"
ISSUE_N="19"
HARNESS="goose"
RUN_CMD=""
MCP_ENDPOINT="https://mcp.oracle.teststuff.net/mcp"
MCP_TOOLS='["statute","search","give_feedback"]'