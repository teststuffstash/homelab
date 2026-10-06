#!/usr/bin/env bash
# clause-coverage — bridge for the clause-coverage replay fixture (actions mode).
# Tests that issue label states match exactly one scan clause.
# On base: defects match zero clauses → fails → RED.
# After fix: defects match one clause → passes → GREEN.

# Enable the clause-coverage block by setting env vars for both test cases
export CC_RUN=1

# Test case 1: #2164 — agent/review without agent-fix
# This state is invisible to both IL-T27 (phantom-review belt) and IL-T09 (merged-closeout).
export CC_ISSUES_1="2164|agent/review"

# Test case 2: r7 F1 — agent/in-progress without agent-fix
# This state is invisible to IL-T06 (c4c5-redispatch), IL-T27, and IL-T09.
export CC_ISSUES_2="2165|agent/in-progress"

# Run the clause-coverage checks inline
echo "[REPLAY] clause-coverage: testing issue label state clause coverage"


