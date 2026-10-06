# ── post ── the two caps the flag exports, read AFTER the loop. `:-<unset>` is the absence row's
# assertion: with no flag the launcher must leave BOTH unset, so the pod env default
# (GOOSE_MAX_TURNS, agent-session.sh's pod spec) and the claude run command's `:-200` still apply.
printf 'GOOSE_MAX_TURNS=%s\n' "${GOOSE_MAX_TURNS:-<unset>}"
printf 'CLAUDE_MAX_TURNS=%s\n' "${CLAUDE_MAX_TURNS:-<unset>}"
