# row harness-not-run
ADMIT_ARGS=(--stack platform --role coordinator --task t --harnesses claude --bind platform-agents/agentstack-loop/p1)
GW_REPLY_BODY='{"decision":"dispatch","session":{"id":"s-oc-1"},"rail":"opencode","harness":"opencode","model":"opencode-go/glm-5","env_keys":["OPENCODE_CONFIG_CONTENT"],"pull_url":"http://agent-gateway.agent-egress.svc.cluster.local:8080/sessions/s-oc-1/env","context_tokens":200000}'
