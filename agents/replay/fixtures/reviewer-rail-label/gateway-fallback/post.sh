# ── observation point ── not launcher code. The block's whole output is the label fragment
# spliced into the reviewer pod manifest; what matters is which of the two semaphores counts
# the pod, so the assertion reads it as that question rather than as YAML.
case "$REVIEW_RAIL_LABEL" in
  *opencode-go*)            echo "COUNTED BY: the Go semaphore (OPENCODE_MAX_RUNNING)";;
  *subscription-session*)   echo "COUNTED BY: the Anthropic semaphore (SUBSCRIPTION_MAX_RUNNING)";;
  *)                        echo "COUNTED BY: nothing — ${REVIEW_RAIL_LABEL:-<empty>}";;
esac
echo "LABEL: ${REVIEW_RAIL_LABEL}"
