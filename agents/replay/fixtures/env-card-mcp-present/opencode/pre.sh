# Set up the MCP knob and AGENT_BASE_IMAGE for the render_env_card call.
# MCP_ENDPOINT and MCP_TOOLS match the oracle stack's claim — same as the goose fixture.
# HARNESS=opencode means the MCP lines should NOT be emitted.
MCP_ENDPOINT="https://mcp.oracle.teststuff.net/mcp"
MCP_TOOLS='["statute","search","give_feedback"]'
AGENT_BASE_IMAGE="ghcr.io/teststuffstash/agent-base:2026.8.25-g6d30823c745d"
HARNESS="opencode"