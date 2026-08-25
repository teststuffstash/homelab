# ── bridge ── sets up the re-review shadow fixture (homelab#923).
#
# CONDITION UNDER REPLAY: a shadow re-review invocation with --model opencode/big-pickle.
# The model id is passed through verbatim, no verdict-posting call is made, and the report
# is written to stdout with a shadow-re-review marker.
#
# Inputs set for the re-review-shadow block:
#   MODEL           the full model id (passed through verbatim to claude)
#   SHADOW          1 = advisory-only mode (no PR posting)
#   PROMPT_CONTENT  the re-review prompt text
#   MODEL_RAIL      the rail derived from model_id.py (openrouter for opencode/big-pickle)
MODEL="opencode/big-pickle"
SHADOW=1
PROMPT_CONTENT="Test prompt for shadow re-review."
MODEL_RAIL="openrouter"