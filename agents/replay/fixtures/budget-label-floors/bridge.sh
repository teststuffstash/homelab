# ── bridge ── the consumer's input: the brief's escalation advice. The SHIPPED README is the
# default, so the fixed row reads the real file (editing the advice moves the fixture); a row may
# point ADVICE_NAME at a world copy to exercise advice the shipped README does not carry.
README="${REPLAY_ROOT}/agents/coordinator/README.md"
[ -n "${ADVICE_NAME:-}" ] && README="${REPLAY_WORLD}/${ADVICE_NAME}"
LABEL_MAP="${REPLAY_ROOT}/argocd/resources/openrouter-proxy/model-classes.json"

# The §arbitrate escalation advice: the sentence from "Re-grade the budget label if needed" to the
# end of the bullet. One extraction, every row reads the same advice; joined to one line so the
# per-label `floors at` clause is matchable regardless of the README's wrap column.
ADVICE="$(awk '/Re-grade the budget label if needed/{f=1} f{print} f&&/This RESETS nothing/{exit}' "$README" \
          | tr '\n' ' ' | sed 's/  */ /g')"

# The floor the advice declares for the row's label — the `floors at` clause naming it.
README_FLOOR="$(printf '%s\n' "$ADVICE" | sed -n "s/.*\`${LABEL}\` floors at \`\([a-z]*\)\`.*/\1/p" | sed -n 1p)"

# The floor `label_map` declares (the one home) — the round-trip's producer side.
MAP_FLOOR="$(jq -r --arg l "agent-budget/${LABEL}" '.label_map[$l].tier_floor // "none"' "$LABEL_MAP")"