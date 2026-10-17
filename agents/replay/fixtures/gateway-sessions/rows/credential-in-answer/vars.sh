# row credential-in-answer
# a pre-GW-SESSIONS-PULL gateway ignores the bind and answers the token + env
GW_REPLY_BODY='{"decision":"dispatch","session":{"id":"0123abcd","token":"gws_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2026-10-17T16:00:00Z"},"rail":"opencode","harness":"opencode","model":"opencode-go/deepseek-v4-flash","env":{"OPENCODE_CONFIG_CONTENT":"{\"model\":\"gateway/deepseek-v4-flash\",\"provider\":{\"gateway\":{\"options\":{\"apiKey\":\"gws_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\"}}}}"},"context_tokens":1000000}'
