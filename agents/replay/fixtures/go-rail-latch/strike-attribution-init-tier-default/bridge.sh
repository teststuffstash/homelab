# ── bridge ── the tier-default rewrite context: MODEL is set to the OpenRouter default
# ("openrouter/deepseek/deepseek-v4-flash") and will be rewritten to "haiku" (the
# subscription default). STRUCK_MODEL should be synced to the new value because it's the
# script's OWN default, not a chain entry a dispatcher chose.
HARNESS="claude"
MODEL="openrouter/deepseek/deepseek-v4-flash"
PROJECT="test-project"
TASK="issue-42"
RAIL_DEGRADED=""
