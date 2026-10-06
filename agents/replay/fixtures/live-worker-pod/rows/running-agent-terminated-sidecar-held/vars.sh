# Running pod with terminated agent container but sidecar still holding the pod.
# This is THE DEFECT: the launcher counted it as live (Running phase), the scan did not
# (agent terminated). After the fix, both use scan semantics: not live.
TEST_PODS_JSON='{"items":[{"status":{"phase":"Running","containerStatuses":[{"name":"agent","state":{"terminated":{"finishedAt":"2026-10-06T10:00:00Z"}}},{"name":"sidecar","state":{"running":{}}}]}}]}'
