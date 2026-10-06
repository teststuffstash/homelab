# Pod with unset/null phase and agent not terminated - counts as live
TEST_PODS_JSON='{"items":[{"status":{"containerStatuses":[{"name":"agent","state":{"waiting":{}}}]}}]}'
