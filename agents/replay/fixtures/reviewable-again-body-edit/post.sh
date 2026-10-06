#!/usr/bin/env bash
# post.sh — run the changes-requested-gate and extract the hold status
set -euo pipefail

# The gate should either emit a `changes-requested|...` unit (held) or skip to next (not held).
# Grep the output for the unit and check if it was emitted.
if grep -q "changes-requested|${IN_REPO}|pr-${IN_U}" <<< "$units"; then
  echo "held"
else
  echo "not-held"
fi
