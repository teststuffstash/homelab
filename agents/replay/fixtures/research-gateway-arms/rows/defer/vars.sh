# row defer — arm 2 is deferred by the gateway: its terminal, no fallback, the reason in the table
ARM_OUT_1='→ gateway(sessions): dispatch claude/opus [rail=anthropic,harness=claude,session=s1,context_tokens=null] (task=research-210-arm1, round=1) — bound'
ARM_OUT_2='→ gateway(sessions): defer — [rail-capacity] retry_after=60s — not dispatching (task=research-210-arm2, round=1).'
ARM_RC_2=1
