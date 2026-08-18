# add-agent-error — overlay the agent/error label the breaker's GENUINE-ANOMALY branch applies
# (gh pr edit --add-label agent/error). The exit contract treats an already-present label as a
# terminal: someone tripped the breaker before us, and the silent stop IS the record.
.labels = [{"name": "agent/error"}, {"name": "foo"}]
