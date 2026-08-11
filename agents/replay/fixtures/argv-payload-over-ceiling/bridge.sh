# ── bridge ── source the SHIPPED guard from the checkout and redefine exactly one seam: the
# ceiling. The arithmetic under test is the guard's own (agents/replay/README.md §When a clause
# depends on a sourced helper) — stubbing argv_guard itself would pin the launcher's `if !` and
# nothing that matters.
. "$REPLAY_ROOT/agents/argv-guard.sh"
ag_limit() { printf '%s' 512; }

# The two launcher variables the block reads, exactly as agent-session.sh sets them upstream.
POD="agent-oracle-fleet-issue-77-r1"
HARNESS="claude"

# 100 ASCII bytes + 140 × `→` (3 bytes each) = 240 characters, 520 bytes. The gap between those
# two numbers is the point: see the fixture's contract 3.
_ARROWS=""; _i=0
while [ "$_i" -lt 140 ]; do _ARROWS="${_ARROWS}→"; _i=$((_i + 1)); done
WRAPPED="$(head -c 100 /dev/zero | tr '\0' 'x')${_ARROWS}"
