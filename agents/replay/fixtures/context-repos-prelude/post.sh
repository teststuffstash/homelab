# Observation point: the assembled prelude, plus the path contract as an explicit verdict.
echo "CTX_PRELUDE: $CTX_PRELUDE"
if grep -qE '/work/context/' <<< "$CTX_PRELUDE"; then
  echo "✗ prelude writes under /work/context/ — the read-only bundle mount"
else
  echo "→ prelude stays off /work/context/ (the bundle mount)"
fi
