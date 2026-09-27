#!/bin/sh
# PreToolUse gate on the Skill tool: a MODEL-initiated `design-agents` invocation is
# denied. The operator-typed `/design-agents <q>` never passes through the Skill tool
# (the skill body is injected into the turn directly), so it is untouched — which makes
# "typed by the operator" the only way the ~300–350k-token corpus read starts.
# Operator rule 2026-09-27: the read is too expensive to start unprompted, mid-session,
# or for a question that needs one slice of the corpus. Rule text: agents/jail-seat-card.md
# §Design questions; skill: .claude/skills/design-agents/SKILL.md. No jq: runs on the host too.
# The match is the NAME SUFFIX after any scope prefix — Claude Code scopes skills with `:`
# (plugin:skill, apps/web:deploy) and paths with `/` — so a re-scope cannot fail the gate open.
input=$(cat)
printf '%s' "$input" | grep -Eq '"skill"[[:space:]]*:[[:space:]]*"([^"]*[:/])?design-agents"' || exit 0
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Unprompted design-agents read blocked (operator rule 2026-09-27, seat card section Design questions). The full agents-corpus load (~300-350k tokens) starts ONLY when the operator types /design-agents themselves. STOP here: do not read docs/agents/ or the agents/ READMEs wholesale as a workaround. Ask the operator (AskUserQuestion) whether the question needs the full corpus, a named slice of it, or no corpus read; if the full read, the operator issues /design-agents <question> in their next message."}}'
