# ── bridge ── sets up the re-review shadow skip-tag fixture (homelab#945).
#
# CONDITION UNDER REPLAY: a shadow re-review invocation with --model opencode/big-pickle,
# where a tag-bearing comment already exists on the PR. Shadow mode must skip the
# idempotency gate and proceed to the claude call.
#
# Inputs set for the re-review-shadow block:
#   MODEL           the full model id (passed through verbatim to claude)
#   SHADOW          1 = advisory-only mode (no PR posting, skip idempotency gate)
#   PROMPT_CONTENT  the re-review prompt text
#   MODEL_RAIL      the rail derived from model_id.py (openrouter for opencode/big-pickle)
MODEL="opencode/big-pickle"
SHADOW=1
PROMPT_CONTENT="Test prompt for shadow re-review with existing tag."
MODEL_RAIL="openrouter"