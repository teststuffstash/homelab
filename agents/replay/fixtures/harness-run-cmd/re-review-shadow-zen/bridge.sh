# ── bridge ── sets up the zen-path re-review shadow fixture (homelab#946).
#
# CONDITION UNDER REPLAY: a shadow re-review with --model opencode/big-pickle, i.e. a Zen id.
# Nothing sets OPENCODE_RUN, so the block resolves the CLI itself and finds `opencode` on PATH
# (the replay stub) — the same resolution a jail seat gets from a pinned install.
#
# Inputs set for the re-review-shadow block:
#   MODEL           the full model id (passed through verbatim to the CLI)
#   SHADOW          1 = advisory-only mode (no PR posting)
#   PROMPT_CONTENT  the re-review prompt text
#   MODEL_RAIL      the rail derived from model_id.py (openrouter for an opencode/ id — the
#                   parser's catch-all; the PREFIX, not the rail, selects the invocation path)
MODEL="opencode/big-pickle"
SHADOW=1
PROMPT_CONTENT="Test prompt for shadow re-review."
MODEL_RAIL="openrouter"
