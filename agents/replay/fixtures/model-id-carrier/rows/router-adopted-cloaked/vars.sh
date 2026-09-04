# ROUTER-ADOPTED-CLOAKED leg: same shape as router-adopted-bare, but the router's bare answer is a
# CLOAKED codename whose OpenRouter id lives in OpenRouter's own namespace (openrouter/<codename>).
# model_id.py keeps that id whole (rail=openrouter, model=openrouter/sonoma-sky-alpha); opencode's
# -m still needs the rail prefix in FRONT of it — openrouter/openrouter/sonoma-sky-alpha — because
# opencode splits provider from model at the first slash (#1342 codeowner-read finding).
MODEL="openrouter/sonoma-sky-alpha"
_router_adopted=1
_decision='{"decision":"dispatch","model":"openrouter/sonoma-sky-alpha"}'
