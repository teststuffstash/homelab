# Issue #660 leg 2: tier-default STRUCK_MODEL sync (PR#668 round 2, step 1/3).
# Note: HARNESS is set to skip subscription-latch.sh in fu088-gates (the tier-default rewrite
# is only applicable after model initialization, not after capacity-driven degrade)
HARNESS="opencode"
MODEL="openrouter/deepseek/deepseek-v4-flash"
TASK="issue-42"
RAIL_DEGRADED=""
CURL_LIMIT_BODY='{"limited": false}'
