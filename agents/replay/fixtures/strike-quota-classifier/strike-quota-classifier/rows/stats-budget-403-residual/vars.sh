# STATS path: exit_status="budget-403" with an error_class that maps to the residual
# (not budget-exhausted-key, not budget-exhausted-account, not http-403-other).
# The jq expression in the classifier maps this to "budget-403" (residual).
STATS='{"exit_status":"budget-403","error_class":"insufficient-quota","cost_usd":10.00,"model":"claude/opus-5","ci_passed":false}'