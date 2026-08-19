# ── test case ── the raw-log fallback classifier. The RUNLOG is in world/runlog.txt with a
# 429 quota pattern. The block reads it and should set ERR_CLASS=quota.

# After the block executes, verify ERR_CLASS=quota
if [ "$ERR_CLASS" != "quota" ]; then
  printf 'FAIL: ERR_CLASS=%s (expected quota from 429 pattern)\n' "$ERR_CLASS" >&2
  exit 1
fi

# Verify that error_class=quota reaches the AGENT_STRIKE line
TEST_STRIKE_LINE="AGENT_STRIKE: model=${STRUCK_MODEL} error_class=${ERR_CLASS} round=${ROUND} session=${POD}"
if ! printf '%s' "$TEST_STRIKE_LINE" | grep -q "error_class=quota"; then
  printf 'FAIL: STRIKE_LINE would be missing error_class=quota: %s\n' "$TEST_STRIKE_LINE" >&2
  exit 1
fi

printf 'PASS: error_class=quota from 429 quota/rate-limit classifier\n'
