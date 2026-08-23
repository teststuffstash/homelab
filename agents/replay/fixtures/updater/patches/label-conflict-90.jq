# conflict-clear: a stale merge-conflict label on a CLEAN PR — the labeler must remove it
map(if .number == 90 then .labels = [{ name: "merge-conflict" }] else . end)
