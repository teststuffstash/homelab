#!/usr/bin/env bash
# Test the extracted touches-check helper functions used by the scan's ADR-097 footprint hold.

set -euo pipefail

# Test 1: fp_conflict_multi detects overlap (queued touches overlap in-progress)
if fp_conflict_multi "agents/**, argocd/**" "argocd/resources/**$IFS docs/**"; then
  echo "TEST 1 PASS: overlapping touches detected"
  exit_code=0
else
  echo "TEST 1 FAIL: overlapping touches NOT detected"
  exit_code=1
fi

# Test 2: fp_conflict_multi doesn't false-positive (disjoint touches)
if ! fp_conflict_multi "agents/**" "argocd/**, docs/**"; then
  echo "TEST 2 PASS: disjoint touches correctly identified as non-overlapping"
else
  echo "TEST 2 FAIL: false positive on disjoint touches"
  exit_code=1
fi

# Test 3: fp_conflict_multi handles wildcard sentinel (undeclared touches)
if fp_conflict_multi "*" "argocd/**, agents/**"; then
  echo "TEST 3 PASS: wildcard sentinel conflicts with everything"
else
  echo "TEST 3 FAIL: wildcard sentinel should conflict"
  exit_code=1
fi

exit ${exit_code:-0}
