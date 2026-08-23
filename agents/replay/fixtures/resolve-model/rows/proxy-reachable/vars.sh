# PROXY-REACHABLE leg: curl succeeds, router returns verdict=dispatch with a model.
# CURL_RESPONSE is what the curl stub returns.
ROLE="responder"
FALLBACK="claude/sonnet"
CLASS=""
CELL=""
OVERRIDE=""
STUB_CURL="ok"
CURL_RESPONSE='{"decision":"dispatch","model":"claude/haiku"}'