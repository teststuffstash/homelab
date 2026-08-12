# add-unlabelled-budget — the mis-authored goal, ADDED to a clean base (the table contract: base
# worlds are CLEAN, a row's patch earns its delta). A machine-readable `Budget:` line — the exact
# grammar `gb_budget_line` parses, since that parser is shared between the walk and the sum it
# feeds — with NO `task/goal` label. docs/agents/issue-authoring.md authors a goal as label AND
# line; a READER cannot assume both, and a funded-but-unlabelled ancestor must still STOP the walk
# (walking past a funded issue is how money goes unwatched — #367 by the other road).
.body = "Budget: 8\nVerdict-authority: human\n\n" + .body
