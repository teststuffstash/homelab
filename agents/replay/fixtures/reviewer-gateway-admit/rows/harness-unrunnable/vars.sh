# row harness-unrunnable — a gateway that answers a codex cell anyway: this pod runs claude only, so the
# helper releases it and fails closed (rc 3) → old-proxy fallback
GW_REPLY_BODY='{"decision":"dispatch","session":{"id":"89abcdef","expires_at":"2026-11-01T16:00:00Z"},"rail":"codex","harness":"codex","model":"codex/gpt-6.1-sol","env_keys":["OPENAI_BASE_URL","OPENAI_API_KEY","CODEX_MODEL"],"pull_url":"http://agent-gateway.agent-egress.svc.cluster.local:8080/sessions/89abcdef/env","context_tokens":null}'
