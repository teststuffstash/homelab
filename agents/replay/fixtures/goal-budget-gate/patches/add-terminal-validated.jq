# add-terminal-validated — the terminal verdict, ADDED to a clean base (the table contract: base
# worlds are CLEAN, a row's patch earns its delta). A human has ruled the goal VALIDATED (ADR-102
# terminal, `goal/validated` — the label the coordinator's goal-lane applies, coordinator-scan.sh
# §goal-lane). The body budget is dropped to $1 so the world is the issue's measured shape: a
# terminal goal whose descendants sum ABOVE its `Budget:` line — which must NOT refuse. The row
# also pins the two sibling terminals by the same predicate: validated/reverted/abandoned are one
# label-family, and a future edit that narrows the exemption to ONE of them reds the other two rows.
.body = "Budget: 1\nVerdict-authority: human\n" | .labels = (.labels + [ { "name": "goal/validated" } ])
