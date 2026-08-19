#!/bin/bash
# Verify: tier-default rewrite syncs STRUCK_MODEL (the script's own default, not a dispatched entry).
# After the rewrite, both MODEL and STRUCK_MODEL should be "haiku".

EXPECTED_MODEL="haiku"
EXPECTED_STRUCK_MODEL="haiku"
EXPECTED_GOOSE_MODEL="haiku"

if [ "$MODEL" != "$EXPECTED_MODEL" ]; then
  echo "FAIL: MODEL=$MODEL (expected $EXPECTED_MODEL after tier-default rewrite)" >&2
  exit 1
fi

if [ "$STRUCK_MODEL" != "$EXPECTED_STRUCK_MODEL" ]; then
  echo "FAIL: STRUCK_MODEL=$STRUCK_MODEL (expected $EXPECTED_STRUCK_MODEL after tier-default sync)" >&2
  exit 1
fi

if [ "$GOOSE_MODEL" != "$EXPECTED_GOOSE_MODEL" ]; then
  echo "FAIL: GOOSE_MODEL=$GOOSE_MODEL (expected $EXPECTED_GOOSE_MODEL)" >&2
  exit 1
fi

echo "PASS: tier-default rewrite synced STRUCK_MODEL (they remain in sync at init)"
