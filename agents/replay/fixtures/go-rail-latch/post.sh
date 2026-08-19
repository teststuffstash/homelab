# ── observation point ── not launcher code. The finished pod command is the observable. Rows
# whose block EXITS before reaching this part (clear falls through with no post state to check;
# defer/reroute-unthreadable/reroute-model-mismatch's un-threadable sibling all `exit 0` inside
# the block itself) never execute these lines regardless of `$POST_SHAPE` — this switch exists
# only for the ONE leg that falls through the gate with no exit (`clear`) and would otherwise
# print stray empty-var lines the original bare-bridge fixture never had. Two shapes, matching
# the two post.sh essays the pre-table family carried:
#   goose — the `*)` default-arm failover + the #629 model-mismatch repro (GOOSE_MODEL, no SUB_LABEL)
#   pod   — the CAPACITY-reroute legs (SUB_LABEL, no GOOSE_MODEL)
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
esac
