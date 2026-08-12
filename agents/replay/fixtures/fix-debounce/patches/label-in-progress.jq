# leg C (PR#250): the whole agent/* namespace excludes — an in-flight ride must not be re-queued
# mid-ride. Same base, the other lifecycle label.
map(if .number == 237 then .labels += [{"name": "agent/in-progress"}] else . end)
