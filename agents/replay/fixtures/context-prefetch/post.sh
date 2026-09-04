# Observation point: after the context-prefetch block runs, assert that RUN_CMD was prepended
# with the prelude. We check the structure without including the variable base64 content.
if printf '%s' "$RUN_CMD" | grep -q '^printf.*| base64 -d > /work/issue.md; '; then
  echo "→ prelude prepend verified: RUN_CMD starts with printf+base64 prelude"
else
  echo "→ prelude prepend FAILED: RUN_CMD=[${RUN_CMD}]"
fi

# Decode the base64 prelude payload and assert the rendered labels line is present.
# The prelude is: printf '%s' '<base64>' | base64 -d > /work/issue.md; <rest>
PF_PAYLOAD="$(printf '%s' "$RUN_CMD" | sed -n "s/^printf '%s' '\([^']*\)' | base64 -d > \/work\/issue.md; .*/\1/p")"
if [ -n "$PF_PAYLOAD" ]; then
  PF_DECODED="$(printf '%s' "$PF_PAYLOAD" | base64 -d 2>/dev/null)"
  if printf '%s' "$PF_DECODED" | grep -q '^\*\*Labels:\*\* agent-fix, task/fix$'; then
    echo "→ prelude labels line verified: **Labels:** agent-fix, task/fix"
  else
    echo "→ prelude labels line MISSING: decoded content does not contain expected labels line"
  fi
else
  echo "→ prelude payload extraction FAILED: could not extract base64 from RUN_CMD"
fi