# Pending pod with Unschedulable condition - should not be counted as live even with agent running
TEST_PODS_JSON='{"items":[{"status":{"phase":"Pending","containerStatuses":[{"name":"agent","state":{"waiting":{}}}],"conditions":[{"type":"PodScheduled","status":"False","reason":"Unschedulable"}]}}]}'
