# row unbound-env-newline
ADMIT_ARGS=(--stack platform --role responder --task 'respond homelab#8' --env-file "$ENVF")
GW_REPLY_BODY='{"decision":"dispatch","session":{"id":"s-resp-2","token":"gws_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2026-11-01T16:00:00Z"},"rail":"anthropic","harness":"claude","model":"claude/sonnet","env":{"ANTHROPIC_AUTH_TOKEN":"gws_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","ANTHROPIC_MODEL":"sonnet\nEVIL=1"},"context_tokens":200000,"rail_choice":"policy"}'
