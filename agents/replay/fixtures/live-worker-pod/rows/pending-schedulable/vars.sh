# Pending pod with no Unschedulable condition and agent not terminated
TEST_PODS_JSON='{"items":[{"status":{"phase":"Pending","containerStatuses":[{"name":"agent","state":{"waiting":{}}}],"conditions":[{"type":"PodScheduled","status":"True"}]}}]}'
