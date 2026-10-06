# Failed pod - terminal phase, not counted as live
TEST_PODS_JSON='{"items":[{"status":{"phase":"Failed","containerStatuses":[{"name":"agent","state":{"terminated":{"exitCode":1}}}]}}]}'
