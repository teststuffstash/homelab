# #50 was touched "now" (a future stamp reads as age < 0 < C4C5_PERSIST_S): a dispatch label write
# just landed and the worker pod may not exist yet — the transition-race guard keeps the footprint.
map(if .number == 50 then .updatedAt = "2099-01-01T00:00:00Z" else . end)
