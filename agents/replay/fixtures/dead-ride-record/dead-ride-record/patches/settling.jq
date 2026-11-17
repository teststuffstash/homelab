# the agent container ended inside the settle window: finishedAt far in the future relative to any
# run of this fixture, so `finishedAt < now - settle` is false and the pod is not read at all.
.items[0].status.containerStatuses[0].state.terminated.finishedAt = "2099-01-01T00:00:00Z"
