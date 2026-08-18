# add-post-launch — an OPEN goal still SHIPPING, budget dropped to $1 so its descendants sum ABOVE
# it. `goal/post-launch` is the ADR-102 MIDPOINT (assembly merged, production rollout ongoing) —
# ADR-102 makes explicit it is still shipping against the same `Budget:` line. This is the
# regression that matters for homelab#509: the terminal exemption must NOT leak onto post-launch,
# so the row asserts the refusal holds with the exact pre-509 numbers. Over-broadening the
# exemption to post-launch reds here first.
.body = "Budget: 1\nVerdict-authority: human\n" | .labels = (.labels + [ { "name": "goal/post-launch" } ])
