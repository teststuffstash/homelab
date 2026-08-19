#!/bin/bash
# Verify: STRUCK_MODEL diverges from MODEL after degrade (the core #660 acceptance).
# When MODEL degrades from opencode-go/* to haiku, STRUCK_MODEL must stay at the original
# value so the strike comment names what was attempted and failed, not what replaced it.

EXPECTED_STRUCK_MODEL="opencode-go/deepseek-v4-flash"
EXPECTED_MODEL="haiku"
EXPECTED_GOOSE_MODEL="haiku"

if [ "$STRUCK_MODEL" != "$EXPECTED_STRUCK_MODEL" ]; then
  echo "FAIL: STRUCK_MODEL=$STRUCK_MODEL (expected $EXPECTED_STRUCK_MODEL at strike time, unchanged from attempted entry)" >&2
  exit 1
fi

if [ "$MODEL" != "$EXPECTED_MODEL" ]; then
  echo "FAIL: MODEL=$MODEL (expected $EXPECTED_MODEL after degrade)" >&2
  exit 1
fi

if [ "$GOOSE_MODEL" != "$EXPECTED_GOOSE_MODEL" ]; then
  echo "FAIL: GOOSE_MODEL=$GOOSE_MODEL (expected $EXPECTED_GOOSE_MODEL after degrade)" >&2
  exit 1
fi

if [ "$RAIL_DEGRADED" != "claude/haiku" ]; then
  echo "FAIL: RAIL_DEGRADED=$RAIL_DEGRADED (expected claude/haiku)" >&2
  exit 1
fi

echo "PASS: STRUCK_MODEL divergence correct — attempted entry at strike time, fallback in use"
