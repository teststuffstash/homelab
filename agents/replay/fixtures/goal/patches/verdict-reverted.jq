# verdict-reverted — the ADR-102 REVERTED terminal (homelab#208): production refuted the idea, a
# human applied `goal/reverted`. Same post-launch tree as the validated base, differing in the
# verdict label AND the goal body's `Revert:` pointer line — the pointer is DECLARED by the
# person who rolled back, never guessed by the scan, and the terminal comment quotes it verbatim.
# The pointer here is the real one from the fixture's world: a pin rollback + the assembly squash.
( .[] | select(.number == 29) | .labels[] | select(.name == "goal/validated") | .name ) = "goal/reverted"
| ( .[] | select(.number == 29) | .body ) = ( (.[] | select(.number == 29) | .body)
    + "Revert: pin rollback circles-app 1.8.2 → 1.8.1 (argocd/resources/circles/values.yaml), assembly squash a1b2c3d reverted on master\n" )
