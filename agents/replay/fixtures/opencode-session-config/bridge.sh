# ── bridge ── the unpinned + no-injection opencode session config path (homelab#792 gap 2).
#
# CONDITION UNDER REPLAY: a recipe dispatch on the opencode harness, where the provider pin
# lookup returns NO pinned provider (registry unreachable, no eligible provider) AND cred
# injection is NOT active. Before the fix this left OC_CONFIG empty after the autoApprove
# guard, so OC_SETUP was never written and the headless run lacked autoApprove — reproducing
# the "user rejected permission" failure (#792 gap 2). After the fix the autoApprove guard
# seeds OC_CONFIG with the $schema base and merges autoApprove even when pin + injection are
# both absent.
#
# THE CONTRACT:
#   1. `OC_SETUP` is non-empty — the base64 config write is always produced for a --recipe
#      opencode ride regardless of pin/injection state.
#   2. The decoded config JSON carries `autoApprove: true`.
#   3. The config JSON carries the `$schema` key.
OC_SETUP=""; OC_ENV=""
HARNESS="opencode"
RUN_CMD="printf '%s' 'UkVDSVBF' | base64 -d > /tmp/fix-recipe.yaml; opencode run -m openrouter/deepseek/deepseek-v4-flash 'task message'"
MODEL="openrouter/deepseek/deepseek-v4-flash"
GOOSE_MODEL="deepseek/deepseek-v4-flash"
# HERE points to a directory WITHOUT estimate_budget.py — the pin lookup will fail silently
# (2>/dev/null || true), producing an empty PIN_JSON, which is exactly the "unpinned" condition.
HERE="/tmp/non-existent-opencode-fixture"
# OC_INJECT is empty — no proxy injection (the block checks `[ -n "$OC_INJECT" ]` which is false).
OC_INJECT=""