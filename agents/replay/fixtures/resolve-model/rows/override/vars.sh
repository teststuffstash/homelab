# OVERRIDE (latched-Anthropic) leg: OVERRIDE set (simulating --model "$rail" or
# AGENT_MODEL env from the caller when rail=opencode-go/*).  The override exits
# before the /route call — no curl, no proxy contact.
ROLE="responder"
FALLBACK="claude/sonnet"
CLASS=""
CELL=""
OVERRIDE="opencode-go/claude-sonnet-4-20250514"
STUB_CURL="ok"
CURL_RESPONSE=""