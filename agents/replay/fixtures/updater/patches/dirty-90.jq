# conflict-dirty: the armed PR goes DIRTY — the labeler must flag it (and the main pick must not touch it)
map(if .number == 90 then .mergeStateStatus = "DIRTY" else . end)
