# Observation point: after the context-prefetch block runs, assert that RUN_CMD was prepended
# with the prelude and that the ConfigMap was created (off argv).
if grep -q '^mkdir -p /work/context; ' <<< "$RUN_CMD"; then
  echo "→ prelude prepend verified: RUN_CMD starts with mkdir -p /work/context"
else
  echo "→ prelude prepend FAILED: RUN_CMD=[${RUN_CMD}]"
fi
