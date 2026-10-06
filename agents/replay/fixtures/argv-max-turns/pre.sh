# ── pre ── the row's argv, set BEFORE the arg loop runs. The composed clause is `bash <comp>`
# with no arguments of its own, so the row's vars.sh is the only source of positional params —
# the same shape pick-rail uses. The two caps are cleared first: GOOSE_MAX_TURNS is pod-wide
# config (agent-session.sh's pod spec sets it), so a fixture that did not clear it would assert
# the POD's value on the `no-flag` row instead of the launcher's own behaviour.
unset GOOSE_MAX_TURNS CLAUDE_MAX_TURNS
. "$REPLAY_WORLD/vars.sh"
