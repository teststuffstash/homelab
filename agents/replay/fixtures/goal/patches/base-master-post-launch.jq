# base-master-post-launch — the SECOND ride on the same goal, one tick later: `Base: master` AND
# the `goal/post-launch` label the previous pass applied. This is the row the #1450 thread asked
# for — "pin the second ride, not the first": the defect was never that trigger (b) fires, it is
# that nothing retired it. `gpl=1` must make the whole goal lane quiet.
map(if .number == 29 then (.body += "Base: master\n") | (.labels += [{"name": "goal/post-launch"}]) else . end)
