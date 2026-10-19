# row dispatch-canary — GW-CATALOG-OR's entry canary (homelab#2742): AGENT_GATEWAY_ROLE=prober +
# AGENT_GATEWAY_CANARY=<model>@<provider> ride as `role: prober` + `canary: {model, provider}`; the
# gateway answers a dispatch on the openrouter rail for the catalog's model (not a policy tier's).
GW_REPLY_BODY='{"decision":"dispatch","session":{"id":"0123abcd","expires_at":"2026-10-17T16:00:00Z"},"rail":"openrouter","harness":"opencode","model":"deepseek/deepseek-v4.1-flash","env_keys":["OPENCODE_CONFIG_CONTENT"],"pull_url":"http://agent-gateway.agent-egress.svc.cluster.local:8080/sessions/0123abcd/env","context_tokens":null}'
