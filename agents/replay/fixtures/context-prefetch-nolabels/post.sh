# Observation point: after the context-prefetch block runs, assert that RUN_CMD was prepended
# with the prelude, and that the decoded prelude payload has no **Labels:** line but DOES
# have a blank line between the ## <title> heading and the body.
if printf '%s' "$RUN_CMD" | grep -q '^printf.*| base64 -d > /work/issue.md; '; then
  echo "→ prelude prepend verified: RUN_CMD starts with printf+base64 prelude"
else
  echo "→ prelude prepend FAILED: RUN_CMD=[${RUN_CMD}]"
fi

# Decode the base64 prelude payload and assert no labels line, but blank line present.
PF_PAYLOAD="$(printf '%s' "$RUN_CMD" | sed -n "s/^printf '%s' '\([^']*\)' | base64 -d > \/work\/issue.md; .*/\1/p")"
if [ -n "$PF_PAYLOAD" ]; then
  PF_DECODED="$(printf '%s' "$PF_PAYLOAD" | base64 -d 2>/dev/null)"
  # Assert no **Labels:** line
  if printf '%s' "$PF_DECODED" | grep -q '^\*\*Labels:\*\*'; then
    echo "→ prelude no-labels arm FAILED: found unexpected **Labels:** line"
  else
    echo "→ prelude no-labels arm verified: no **Labels:** line present"
  fi
  # Assert blank line between ## <title> and body: look for "## <title>" followed by
  # an empty line (two consecutive newlines). Use awk to check the pattern.
  if printf '%s' "$PF_DECODED" | awk '/^## /{getline line; if(length(line)==0) {found=1; exit 0}} END{exit !found+0}'; then
    echo "→ prelude blank-line verified: blank line present between title and body"
  else
    echo "→ prelude blank-line MISSING: no blank line between title and body"
  fi
else
  echo "→ prelude payload extraction FAILED: could not extract base64 from RUN_CMD"
fi