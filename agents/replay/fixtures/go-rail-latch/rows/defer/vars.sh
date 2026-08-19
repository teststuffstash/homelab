# DEFER leg: opencode-go/* MODEL, /opencode-limit reason=semaphore — the TRANSIENT leg, which
# echoes and exits 0 before touching TASK/RUN_CMD/_srow.
MODEL="opencode-go/deepseek-v4-flash"
CURL_LIMIT_BODY='{"limited": true, "reason": "semaphore"}'
