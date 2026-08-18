# add-terminal-reverted — the terminal verdict REVERTED (ADR-102: production refutes the idea; the
# goal closes successfully-refuted, descendants die with it). Same delta as add-terminal-validated:
# a funded goal a human has ruled terminal must NOT gate its tree, however the verdict was reached.
# One row per terminal label — a future edit that narrows the exemption to `goal/validated` alone
# reds this row (and the abandoned sibling) on its own.
.body = "Budget: 1\nVerdict-authority: human\n" | .labels = (.labels + [ { "name": "goal/reverted" } ])
