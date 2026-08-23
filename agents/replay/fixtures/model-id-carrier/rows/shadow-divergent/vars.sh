# SHADOW-DIVERGENT leg: AGENT_ROUTER=shadow, so _router_adopted is NOT set.
# _decision carries a resolved that DIFFERS from MODEL (the router would pick
# openrouter/deepseek/deepseek-v4-flash but the shadow mode means the served MODEL
# is unchanged). Expected: fallback to model_id.py --shell parse, MODEL unchanged.
MODEL="claude/haiku"
AGENT_ROUTER="shadow"
_decision='{"decision":"dispatch","model":"openrouter/deepseek/deepseek-v4-flash","resolved":{"rail":"openrouter","harness":"","model":"openrouter/deepseek/deepseek-v4-flash"}}'