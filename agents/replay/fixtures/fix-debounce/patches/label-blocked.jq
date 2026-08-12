# leg A (homelab#238): a coordinator BLOCK removes agent/queued — the lifecycle-namespace test
# must keep the issue OUT of the pending set. Base is CLEAN #237; this row adds the human gate.
map(if .number == 237 then .labels += [{"name": "agent/blocked"}] else . end)
