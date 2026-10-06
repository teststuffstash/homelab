# Pending pod with Unschedulable condition but younger than 30s - counts as live due to grace period
TEST_PODS_JSON='{"items":[{"metadata":{"creationTimestamp":"2026-10-06T10:59:55Z"},"status":{"phase":"Pending","containerStatuses":[{"name":"agent","state":{"waiting":{}}}],"conditions":[{"type":"PodScheduled","status":"False","reason":"Unschedulable"}]}}]}'
