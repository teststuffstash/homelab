# ── bridge ── the opencode sibling of harness-run-cmd-goose (homelab#792, ADR-107 addendum).
#
# CONDITION UNDER REPLAY: a recipe dispatch on the opencode harness. The card-spliced recipe is
# base64'd, the context-repos prelude is built, the issue number is known. What is left is the
# `case "$HARNESS"` that freezes the pod command — the string that reaches `args:` as one argv
# element a few dozen lines later.
#
# THE CONTRACT:
#   1. `OPENCODE_MODEL` is the full provider-prefixed id (openrouter/<vendor>/<model>) — never a
#      bare two-part id that opencode would interpret as a provider name and silently fall through
#      to a tools-incapable default model.
#   2. The recipe is base64-decoded to /tmp/fix-recipe.yaml, then opencode run receives the model
#      via -m and a task referencing the recipe file.
#   3. The rest of the pod command is unmoved: prelude, then the base64 decode, then `opencode run
#      -m <model> ...`.
CTX_PRELUDE=""
RECIPE_B64="UkVDSVBF"
ISSUE_N="19"
HARNESS="opencode"
OPENCODE_MODEL="openrouter/deepseek/deepseek-v4-flash"
RUN_CMD=""