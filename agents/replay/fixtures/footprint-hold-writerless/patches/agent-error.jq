# #50 also carries `agent/error`: a human owns the crash latch, and an errored in-progress issue
# keeps its footprint by design (the inprog-selector comment) — no live writer is not enough.
map(if .number == 50 then .labels += [{"name": "agent/error"}] else . end)
