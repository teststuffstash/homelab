# COORDINATOR-EXPLICIT-OVERRIDE leg: role=coordinator, --model set explicitly
# (simulating an operator passing --model on the command line, which triggers the ADR-096
# override rule). The override exits before /route — no curl, no proxy contact.
ROLE="coordinator"
FALLBACK="sonnet"
CLASS="dispatch"
CELL=""
OVERRIDE="opus"
STUB_CURL="ok"
CURL_RESPONSE='{"decision":"dispatch","model":"claude/sonnet"}'