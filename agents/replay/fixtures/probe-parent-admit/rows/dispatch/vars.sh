# row dispatch — the gateway admits the parent (sonnet, anthropic rail; deliberately NOT the claim's
# haiku, so the model visibly comes from the gateway): claude runs on the session env, a claude
# child takes the same model, the EXIT trap releases the session.
GW_REPLY_BODY='{"decision":"dispatch","session":{"id":"s-probe-1","token":"gws_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2026-11-01T16:00:00Z"},"rail":"anthropic","harness":"claude","model":"claude/sonnet","env":{"ANTHROPIC_BASE_URL":"http://agent-gateway.agent-egress.svc.cluster.local:8080/anthropic","ANTHROPIC_AUTH_TOKEN":"gws_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","ANTHROPIC_MODEL":"sonnet"},"context_tokens":200000,"rail_choice":"policy"}'
