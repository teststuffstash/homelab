# ── observation point ── not launcher code. The finished pod command is the observable. Rows
# whose block EXITS before reaching this part (clear falls through with no post state to check;
# defer/reroute-unthreadable/reroute-model-mismatch's un-threadable sibling all `exit 0` inside
# the block itself) never execute these lines regardless of `$POST_SHAPE` — this switch exists
# only for the ONE leg that falls through the gate with no exit (`clear`) and would otherwise
# print stray empty-var lines the original bare-bridge fixture never had. Two shapes, matching
# the two post.sh essays the pre-table family carried:
#   goose — the `*)` default-arm failover + the #629 model-mismatch repro (GOOSE_MODEL, no SUB_LABEL)
#   pod   — the CAPACITY-reroute legs (SUB_LABEL, no GOOSE_MODEL)
#   strike-attribution — #660 leg 1: STRUCK_MODEL initialization
#   strike-attribution-degrade — #660 leg 2: STRUCK_MODEL divergence across degrade
#   strike-attribution-init-tier-default — #660 leg 2: tier-default STRUCK_MODEL sync
case "${POST_SHAPE:-off}" in
  off) : ;;
  goose)
    echo "MODEL='${MODEL-}'"
    echo "GOOSE_MODEL='${GOOSE_MODEL-}'"
    echo "RUN_CMD: ${RUN_CMD}"
    echo "RAIL_DEGRADED='${RAIL_DEGRADED-}'"
    echo "AGENT_RAIL='${AGENT_RAIL-}'"
    ;;
  pod)
    echo "RUN_CMD: ${RUN_CMD}"
    echo "RAIL_DEGRADED='${RAIL_DEGRADED-}'"
    echo "MODEL='${MODEL-}'"
    echo "AGENT_RAIL='${AGENT_RAIL-}'"
    echo "SUB_LABEL='${SUB_LABEL-}'"
    ;;
  strike-attribution)
    # Issue #660 leg 1: STRUCK_MODEL is initialized to the original MODEL value
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
    ;;
  strike-attribution-degrade)
    # Issue #660 leg 2: STRUCK_MODEL diverges from MODEL after degrade
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
    ;;
  strike-attribution-init-tier-default)
    # Issue #660 leg 2: tier-default rewrite syncs STRUCK_MODEL
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
    ;;
  strike-quota-classifier)
    # Issue #660 leg 2: 429-quota classifier in raw-log fallback
    if [ "$ERR_CLASS" != "quota" ]; then
      echo "FAIL: ERR_CLASS=$ERR_CLASS (expected quota from 429 pattern)" >&2
      exit 1
    fi
    # Verify that error_class=quota reaches the AGENT_STRIKE line (construct it as the block would)
    TEST_STRIKE_LINE="AGENT_STRIKE: model=${STRUCK_MODEL} error_class=${ERR_CLASS} round=${ROUND} session=${POD}"
    if ! echo "$TEST_STRIKE_LINE" | grep -q "error_class=quota"; then
      echo "FAIL: STRIKE_LINE would be missing error_class=quota: $TEST_STRIKE_LINE" >&2
      exit 1
    fi
    echo "PASS: error_class=quota from 429 quota/rate-limit classifier"
    ;;
esac
