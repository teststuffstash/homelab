# row defer
ADMIT_ARGS=(--stack platform --role coordinator --task t --round 3 --attempt 2 --bind platform-agents/agentstack-loop/p1)
GW_REPLY_BODY='{"decision":"defer","reason":"subscription-sessions-full","retry_after_s":120}'
