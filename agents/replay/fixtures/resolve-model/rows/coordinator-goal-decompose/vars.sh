# COORDINATOR-GOAL-DECOMPOSE leg: role=coordinator, class=goal-decompose, proxy reachable,
# router returns claude/opus (the reasoning tier, matching model-classes.json policy).
ROLE="coordinator"
FALLBACK="opus"
CLASS="goal-decompose"
CELL=""
OVERRIDE=""
STUB_CURL="ok"
CURL_RESPONSE='{"decision":"dispatch","model":"claude/opus"}'