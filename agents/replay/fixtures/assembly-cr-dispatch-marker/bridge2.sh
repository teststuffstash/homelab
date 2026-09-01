# ── bridge 2 (second pass) ── the NO-PR arm, folded in from assembly-cr-dispatch-no-pr
# (deleted; its pure-absence contract over pre-existing sentinels passed on ANY base — the
# ADR-103 pin-vacuity gate's negative-row blindness, #1225). Carried here because THIS
# directory reds on base (the goal-checkpoint arm does not exist pre-#1150), so the absence
# assertion below is not vacuous: an ordinary threshold-fired goal-checkpoint unit with an
# EMPTY side map must write no state-fp comment and emit no WARN — the expected stream
# carries exactly ONE CALL (pass 1's), and a second call here would fail the match.
uclause="goal-checkpoint"
uitem="issue-281"
urepo="oracle-fleet"
# Side map EMPTY — no assembly PR carried this unit.
assembly_cr_prs=""
