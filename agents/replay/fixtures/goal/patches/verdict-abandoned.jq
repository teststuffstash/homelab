# verdict-abandoned — the ADR-102 ABANDONED terminal (homelab#208): budget ran out before a
# verdict, a human applied `goal/abandoned`. Same post-launch tree as the validated base —
# bucket #77, live sprout #95 — differing ONLY in the verdict label on the goal. The openall
# body also differs (the abandoned shape carries no Revert: line — the base body is reused
# verbatim). One row per terminal keeps the OR in the lane's `goal/{validated,reverted,abandoned}`
# predicate from decaying to a single verdict.
( .[] | select(.number == 29) | .labels[] | select(.name == "goal/validated") | .name ) = "goal/abandoned"
