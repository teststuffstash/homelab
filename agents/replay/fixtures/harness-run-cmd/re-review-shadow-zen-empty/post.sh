# ── observation point ── not launcher code. The block `continue`s on a second empty reply, which
# in the shipped script skips the snapshot; a composed clause has no enclosing loop, so bash says
# so on stderr and falls through to here. What this fixture pins is everything BEFORE that: two
# calls, one retry notice each, and the loud ERROR — never a recorded verdict.
echo "claude_reply: ${claude_reply:-(unset — the snapshot was skipped)}"
