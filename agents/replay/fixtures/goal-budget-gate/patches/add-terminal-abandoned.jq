# add-terminal-abandoned — the terminal verdict ABANDONED (ADR-102: budget out before a verdict;
# open descendants stay open but go inert). Same delta as the other two terminal patches: a funded
# goal a human has ruled terminal must NOT gate its tree. One row per terminal label keeps the OR
# in `goal_budget_read`'s label predicate from decaying into an AND on `goal/validated` alone.
.body = "Budget: 1\nVerdict-authority: human\n" | .labels = (.labels + [ { "name": "goal/abandoned" } ])
