#!/bin/bash
# Verify: STRUCK_MODEL remains at original value after degrade, MODEL changed to fallback.
STRUCK_MODEL_CHECK="opencode-go/deepseek-v4-flash"
MODEL_CHECK="claude/haiku"

if [ "$STRUCK_MODEL" != "$STRUCK_MODEL_CHECK" ]; then
  echo "FAIL: STRUCK_MODEL=$STRUCK_MODEL (expected $STRUCK_MODEL_CHECK)" >&2
  exit 1
fi

if [ "$MODEL" != "$MODEL_CHECK" ]; then
  echo "FAIL: MODEL=$MODEL (expected $MODEL_CHECK)" >&2
  exit 1
fi

echo "PASS: strike attribution preserves original model on degrade"
