# ROUTER-ADOPTED-BARE leg: _router_adopted=1 (authoritative + dispatch + _rmodel non-empty),
# but _decision carries no .resolved carrier (the router's raw answer had the bare model id
# deepseek/deepseek-v4-flash without a structured resolved block). Falls back to
# model_id.py --shell parse, which returns rail=openrouter, model=deepseek/deepseek-v4-flash.
# The new OPENCODE_MODEL composition then prepends the openrouter/ prefix so opencode's -m
# receives the full provider-prefixed id (#1342).
MODEL="deepseek/deepseek-v4-flash"
_router_adopted=1
_decision='{"decision":"dispatch","model":"deepseek/deepseek-v4-flash"}'