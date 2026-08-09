# ── bridge ── source the SHIPPED helper from the checkout and redefine exactly one seam.
#
# Do it this way round, not by stubbing mc_event itself (agents/replay/README.md §When a clause
# depends on a sourced helper): the find-or-create arithmetic IS the thing under test, and a stub
# of it would pin its branching and nothing else. The gh calls deliberately stay real — they go
# through the PATH-shim `gh`, which is what puts them in the action stream.
. "$REPLAY_ROOT/agents/machine-comment.sh"

# The only seam: the wall clock. Everything else is the shipped code over the recorded world.
mc_now() { printf '2026-08-09T12:09:52Z'; }

mc_event "$IN_SLUG" "$IN_NUMBER" dispatch "**picking this up (round 1)** — split the cross-repo leg, move the launcher fallback"
printf 'RETURN %s\n' "$?"
echo "REACHED: end"
