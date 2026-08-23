# ── the queued units ── `repo|qnum|qtitle|qclass|qtouches`, one per line.
# qtouches carries the value the scan has ALREADY normalized (a missing `Touches:` line has become
# the `*` sentinel by this point). busy_fps is set in bridge.sh.
#
# Cases:
#   #822a  goal  *                DISPATCHED (goal is exempt from footprint hold)
#   #822b  fix   *                HELD       (`*` conflicts with busy chassis/**)
#   #822c  goal  agents/**        DISPATCHED (disjoint from busy chassis/**, docs/** — also exempt)
#   #822d  goal  chassis/**       DISPATCHED (overlaps busy, but goal-class exemption wins)
CASES="homelab|822a|a goal with no Touches line|goal|*
homelab|822b|a fix with no Touches line|fix|*
homelab|822c|a goal with disjoint footprint|goal|agents/**
homelab|822d|a goal with overlapping footprint|goal|chassis/**"
while IFS='|' read -r repo qnum qtitle qclass qtouches; do
  [ -n "$qnum" ] || continue