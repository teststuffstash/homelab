#!/bin/bash
# Verify the ci-failure-run-select fixture
# The prefetch should have selected the failing run (33965268108) and populated ci-failure.md

# Verify the run ID is the failing one, not the skipped one
if [ "$PF_RUN_ID" != "33965268108" ]; then
  echo "❌ Expected PF_RUN_ID=33965268108, got $PF_RUN_ID"
  exit 1
fi

# Verify the log tail was populated
if [ -z "$PF_LOG_TAIL" ]; then
  echo "❌ Expected PF_LOG_TAIL to be populated, but it was empty"
  exit 1
fi

# Verify the log tail contains expected content
if ! echo "$PF_LOG_TAIL" | grep -q "pip._internal.exceptions.PipCheckError"; then
  echo "❌ Expected log tail to contain pip error, got: $PF_LOG_TAIL"
  exit 1
fi

# Verify the ci-failure.md was marked OK
if ! echo "$PF_INDEX" | grep -q "ci-failure.md  OK"; then
  echo "❌ Expected ci-failure.md to be marked OK"
  echo "PF_INDEX: $PF_INDEX"
  exit 1
fi

echo "✓ ci-failure-run-select fixture passed"
