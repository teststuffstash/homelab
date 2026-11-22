# Observation point: after the context-prefetch block runs, assert that RUN_CMD was prepended
# with the prelude. Here the ConfigMap was NOT created (AlreadyExists, no owner, nothing deleted), so the
# prelude is the argv fallback; the CALL/ERR lines in expected/actions.txt pin that, not this probe.
if grep -q '^mkdir -p /work/context; ' <<< "$RUN_CMD"; then
  echo "→ prelude prepend verified: RUN_CMD starts with mkdir -p /work/context"
else
  echo "→ prelude prepend FAILED: RUN_CMD=[${RUN_CMD}]"
fi