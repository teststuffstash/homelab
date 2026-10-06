# ── post ── call live_worker_pod_count with the test pod JSON and output the count
printf '%s\n' "$(live_worker_pod_count "$TEST_PODS_JSON")"
