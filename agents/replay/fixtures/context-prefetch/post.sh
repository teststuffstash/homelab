# Observation point: after the context-prefetch block runs, assert that RUN_CMD was prepended
# with the prelude. We check the structure without including the variable base64 content.
if printf '%s' "$RUN_CMD" | grep -q '^printf.*| base64 -d > /work/issue.md; '; then
  echo "→ prelude prepend verified: RUN_CMD starts with printf+base64 prelude"
else
  echo "→ prelude prepend FAILED: RUN_CMD=[${RUN_CMD}]"
fi