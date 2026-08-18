# ── bridge ── same four variables as the goose sibling, with CTX_PRELUDE EMPTY: the ordinary
# dispatch, no context-repos pilot. `CLAUDE_MAX_TURNS` is deliberately left unset so the arm's
# `:-200` default is the value that lands in the asserted stream. `MODEL` is the bare alias the
# model_id parse leaves behind for a claude/haiku dispatch — the block must put it on the CLI
# (`--model haiku`), because a flagless claude runs its own default (opus-tier, the 2026-08-13
# subscription-burn finding), and only this asserted stream makes that regression red.
CTX_PRELUDE=""
RECIPE_B64="UkVDSVBF"
ISSUE_N="19"
HARNESS="claude"
MODEL="haiku"
RUN_CMD=""
