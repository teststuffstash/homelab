# ── bridge ── the unpinned + no-injection opencode session config path with MCP present.
#
# CONDITION UNDER REPLAY: a recipe dispatch on the opencode harness, where the provider pin
# lookup returns NO pinned provider, cred injection is NOT active, AND MCP_ENDPOINT is set.
# The MCP config should be deep-merged into OC_CONFIG alongside autoApprove.
#
# THE CONTRACT:
#   1. `OC_SETUP` is non-empty — the base64 config write is always produced.
#   2. The decoded config JSON carries `mode.autoApprove` (with empty permission+options).
#   3. The decoded config JSON carries `mcp.stack-mcp` with type "remote" and the endpoint URL.
#   4. The config JSON carries the `$schema` key.
OC_SETUP=""; OC_ENV=""
HARNESS="opencode"
RUN_CMD="printf '%s' 'UkVDSVBF' | base64 -d > /tmp/fix-recipe.yaml; opencode run -m openrouter/deepseek/deepseek-v4-flash 'task message'"
MODEL="openrouter/deepseek/deepseek-v4-flash"
GOOSE_MODEL="deepseek/deepseek-v4-flash"
# HERE points to a directory WITHOUT estimate_budget.py — the pin lookup will fail silently
# (2>/dev/null || true), producing an empty PIN_JSON, which is exactly the "unpinned" condition.
HERE="/tmp/non-existent-opencode-fixture"
# OC_INJECT is empty — no proxy injection (the block checks `[ -n "$OC_INJECT" ]` which is false).
OC_INJECT=""
# MCP knob present — the oracle stack's endpoint and tools.
MCP_ENDPOINT="https://mcp.oracle.teststuff.net/mcp"
MCP_TOOLS='["statute","search","give_feedback"]'
MCP_OPENCODE_CONFIG_JSON='{"mcp":{"stack-mcp":{"type":"remote","url":"https://mcp.oracle.teststuff.net/mcp"}}}'
