# row fail-closed — the gateway answers 503 (rc 3): one loud line, the parent falls back to the pod's
# old-proxy env at the claim's model (FU-270: transition fallback).
GW_REPLY_HTTP=503; GW_REPLY_BODY='{"error":"tokenreview-transient"}'
