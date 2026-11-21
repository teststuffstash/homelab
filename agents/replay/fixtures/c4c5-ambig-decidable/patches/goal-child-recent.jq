# The goal child was touched "now" (a future stamp reads as age < 0 < C4C5_PERSIST_S): a dispatch
# label write or a comment just landed, so the merge evidence is not consulted and it stays HELD.
map(if .number == 329 then .updatedAt = "2099-01-01T00:00:00Z" else . end)
