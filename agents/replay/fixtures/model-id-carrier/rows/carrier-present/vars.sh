# CARRIER-PRESENT leg: _decision holds .resolved={rail,harness,model} complete,
# and the router's decision was adopted (_router_adopted=1, meaning AGENT_ROUTER=authoritative
# + verdict=dispatch + _rmodel non-empty). model_id.py is NOT called — the carrier supplies
# all three fields.
MODEL="claude/haiku"
_router_adopted=1
_decision='{"decision":"dispatch","model":"claude/haiku","resolved":{"rail":"anthropic-subscription","harness":"claude","model":"haiku"}}'