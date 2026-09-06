# base-master-tree-empty — goal #29 declares `Base: master`, i.e. a THEMED goal (ADR-126): its
# batching value lives in level-2 theme branches, so it has no assembly PR and deliberately no
# `Assembly-for:` trailer, and IL-T18's assembly-PR key can never fire for it. Everything else in
# `open-pre` is unchanged, so the tree is empty (children #30/#31 closed, bucket #77 excluded) —
# which is exactly the state that used to arm trigger (b) forever (homelab#1450, 13 rides).
# The line is appended rather than woven into the body on purpose: the legacy `Base:` grammar is
# position-free, and appending keeps the delta to the one fact the row is about.
map(if .number == 29 then .body += "Base: master\n" else . end)
