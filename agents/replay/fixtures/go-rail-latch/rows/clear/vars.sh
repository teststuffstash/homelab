# CLEAR leg: opencode-go/* MODEL, /opencode-limit says limited:false — the gate falls through
# with no further reads (never touches TASK/RUN_CMD/_srow), so nothing else is needed here.
MODEL="opencode-go/deepseek-v4-flash"
CURL_LIMIT_BODY='{"limited": false}'
