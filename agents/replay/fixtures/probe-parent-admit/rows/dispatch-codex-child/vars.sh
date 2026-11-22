# row dispatch-codex-child — the child block already admitted a codex child (prober.childRail): its
# harness/model stay the child's, and the parent's EXIT trap releases BOTH sessions.
GW_REPLY_BODY='{"decision":"dispatch","session":{"id":"s-probe-1","token":"gws_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","expires_at":"2026-11-01T16:00:00Z"},"rail":"anthropic","harness":"claude","model":"claude/sonnet","env":{"ANTHROPIC_BASE_URL":"http://agent-gateway.agent-egress.svc.cluster.local:8080/anthropic","ANTHROPIC_AUTH_TOKEN":"gws_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","ANTHROPIC_MODEL":"sonnet"},"context_tokens":200000,"rail_choice":"policy"}'
export PROBE_CHILD_HARNESS=codex PROBE_CHILD_MODEL=gpt-6-luna
_gw_sid="s-child-1"
_gw_release() { echo "→ gateway(sessions): released $_gw_sid (the codex child)"; }
