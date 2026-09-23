# ── dispatch-side seams ── the dispatching legs (pr-397, pr-398) reach the handoff, so its seams
# get recording stubs: the CALL lines are the assertion that the unit genuinely proceeded past
# both holds. The launcher atomic gate is the real backstop in production.
dispatch_phase() { printf "CALL dispatch_phase %s\n" "$*" >> "$REPLAY_ACTIONS"; }
scan_phase() { printf "CALL scan_phase %s\n" "$*" >> "$REPLAY_ACTIONS"; }
