# row unbound-answer-bound
ADMIT_ARGS=(--stack platform --role responder --task 'respond homelab#9' --env-file "$ENVF")
GW_REPLY_BODY='{"decision":"dispatch","session":{"id":"s-coord-1","expires_at":"2026-11-01T16:00:00Z"},"rail":"anthropic","harness":"claude","model":"claude/opus","env_keys":["ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN","ANTHROPIC_MODEL"],"pull_url":"http://agent-gateway.agent-egress.svc.cluster.local:8080/sessions/s-coord-1/env","context_tokens":200000}'
