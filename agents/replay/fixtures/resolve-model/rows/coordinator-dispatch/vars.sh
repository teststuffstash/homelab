# COORDINATOR-DISPATCH leg: role=coordinator, class=dispatch (via resolve-model role_defaults
# when no explicit class is needed), proxy reachable, router returns claude/sonnet.
ROLE="coordinator"
FALLBACK="sonnet"
CLASS="dispatch"
CELL=""
OVERRIDE=""
STUB_CURL="ok"
CURL_RESPONSE='{"decision":"dispatch","model":"claude/sonnet"}'