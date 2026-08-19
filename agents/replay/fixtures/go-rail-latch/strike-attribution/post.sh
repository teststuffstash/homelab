#!/bin/bash
# Verify: STRUCK_MODEL is initialized to the original MODEL value for strike attribution.
STRUCK_MODEL_CHECK="opencode-go/deepseek-v4-flash"

if [ "$STRUCK_MODEL" != "$STRUCK_MODEL_CHECK" ]; then
  echo "FAIL: STRUCK_MODEL=$STRUCK_MODEL (expected $STRUCK_MODEL_CHECK)" >&2
  exit 1
fi

if [ "$MODEL" != "$STRUCK_MODEL" ]; then
  echo "FAIL: MODEL=$MODEL diverged from STRUCK_MODEL=$STRUCK_MODEL (they should match at init)" >&2
  exit 1
fi

echo "PASS: STRUCK_MODEL initialized correctly for strike attribution"
