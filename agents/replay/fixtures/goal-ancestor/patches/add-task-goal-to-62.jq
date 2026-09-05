# add-task-goal-to-62 — the real goal label, ADDED to a clean base (the table contract: base
# worlds are CLEAN, a row's patch earns its delta). Issue #62 is an ordinary parent with
# Goal/Acceptance headings but no `task/goal` label and no `Budget:` line. This patch adds
# the label so the walk can find it as the real goal after climbing past a child that has
# its own `Budget:` line (homelab#1392: a child with `Budget:` + parent → climbs past it).
.labels = (.labels // []) + [{"name": "task/goal", "description": "Routes to the coordinator's goal-decompose play, not a worker recipe — FU-090 leg (c)", "color": "5319e7"}]