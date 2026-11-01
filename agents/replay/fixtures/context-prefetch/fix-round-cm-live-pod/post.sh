# Observation point: the ConfigMap create was refused, so RUN_CMD must carry the TWO-FILE argv
# fallback prelude (index.txt + issue.md, base64-encoded separately) — never a single bundle.txt.
if grep -q '^mkdir -p /work/context; ' <<< "$RUN_CMD"; then
  echo "→ prelude prepend verified: RUN_CMD starts with mkdir -p /work/context"
else
  echo "→ prelude prepend FAILED: RUN_CMD=[${RUN_CMD}]"
fi

if grep -q "base64 -d > /work/context/index.txt;" <<< "$RUN_CMD"; then
  echo "→ fallback writes /work/context/index.txt"
else
  echo "→ fallback FAILED: no index.txt write in RUN_CMD"
fi

if grep -q "base64 -d > /work/context/issue.md;" <<< "$RUN_CMD"; then
  echo "→ fallback writes /work/context/issue.md"
else
  echo "→ fallback FAILED: no issue.md write in RUN_CMD"
fi

if grep -q "/work/context/bundle.txt" <<< "$RUN_CMD"; then
  echo "→ fallback FAILED: legacy single bundle.txt still referenced"
fi

# Decode the two base64 payloads out of RUN_CMD and check their content directly — the index must
# downgrade the OK optional items (pr.md, reviews.md) to MISSING/argv-fallback while leaving the
# pre-existing MISSING (ci-failure.md) untouched, and issue.md must be the real issue markdown.
INDEX_B64="$(printf '%s' "$RUN_CMD" | sed -n "s/.*printf '%s' '\([^']*\)' | base64 -d > \/work\/context\/index.txt.*/\1/p")"
ISSUE_B64="$(printf '%s' "$RUN_CMD" | sed -n "s/.*printf '%s' '\([^']*\)' | base64 -d > \/work\/context\/issue.md.*/\1/p")"
INDEX_TXT="$(printf '%s' "$INDEX_B64" | base64 -d)"
ISSUE_MD="$(printf '%s' "$ISSUE_B64" | base64 -d)"

if grep -qF "pr.md  MISSING  argv fallback (ConfigMap create refused)" <<< "$INDEX_TXT"; then
  echo "→ index downgrades pr.md to MISSING/argv-fallback"
else
  echo "→ index FAILED: pr.md not downgraded — index was:"
  printf '%s\n' "$INDEX_TXT"
fi

if grep -qF "reviews.md  MISSING  argv fallback (ConfigMap create refused)" <<< "$INDEX_TXT"; then
  echo "→ index downgrades reviews.md to MISSING/argv-fallback"
else
  echo "→ index FAILED: reviews.md not downgraded — index was:"
  printf '%s\n' "$INDEX_TXT"
fi

if grep -qF "ci-failure.md  MISSING  No failing check runs found" <<< "$INDEX_TXT"; then
  echo "→ index leaves ci-failure.md's pre-existing MISSING reason untouched"
else
  echo "→ index FAILED: ci-failure.md's original MISSING reason was altered — index was:"
  printf '%s\n' "$INDEX_TXT"
fi

if grep -q '^# Issue #1175' <<< "$ISSUE_MD"; then
  echo "→ issue.md content verified"
else
  echo "→ issue.md FAILED: content was:"
  printf '%s\n' "$ISSUE_MD"
fi
