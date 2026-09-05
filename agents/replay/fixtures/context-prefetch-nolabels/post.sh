# Observation point: after the context-prefetch block runs, assert that RUN_CMD was prepended
# with the prelude, and that $PF_ISSUE_MD has no **Labels:** line but DOES have a blank line
# between the ## <title> heading and the body.
if printf '%s' "$RUN_CMD" | grep -q '^mkdir -p /work/context; '; then
  echo "→ prelude prepend verified: RUN_CMD starts with mkdir -p /work/context"
else
  echo "→ prelude prepend FAILED: RUN_CMD=[${RUN_CMD}]"
fi

# Assert no **Labels:** line in the rendered issue markdown
if printf '%s' "$PF_ISSUE_MD" | grep -q '^\*\*Labels:\*\*'; then
  echo "→ prelude no-labels arm FAILED: found unexpected **Labels:** line"
else
  echo "→ prelude no-labels arm verified: no **Labels:** line present"
fi

# Assert blank line between ## <title> and body: anchor on the first ## heading and exit
# immediately, so ## Comments cannot rescue a collapsed gap (fail-closed per round 2 review).
if printf '%s' "$PF_ISSUE_MD" | awk '/^## /{getline line; ok=(length(line)==0); exit !ok} END{exit !ok}'; then
  echo "→ prelude blank-line verified: blank line present between title and body"
else
  echo "→ prelude blank-line MISSING: no blank line between title and body"
fi