# ── drive ── the block defines absorb_pending_rings and evaluates its self-identity line once;
# each leg re-pins the identity vars and calls it, the way one scan's preamble would.

echo "REACHED: full scan absorbs pending siblings (and only them)"
SPAWN=1; SCAN_UNIT=""; SCAN_PHASE_NS=circles-agents; DOORBELL_WF_SELF=coordinate-perstack-self1
absorb_pending_rings
printf 'RETURN %s\n' "$?"

echo "REACHED: unit fast-path scan is narrower — absorbs nothing"
SCAN_UNIT="changes-requested|circles|pr-5"
absorb_pending_rings
printf 'RETURN %s\n' "$?"
SCAN_UNIT=""

echo "REACHED: report mode (no --spawn) — absorbs nothing"
SPAWN=""
absorb_pending_rings
printf 'RETURN %s\n' "$?"
SPAWN=1

echo "REACHED: unreadable workflow list — absorbs nothing, loudly"
STUB_KUBECTL=fail absorb_pending_rings
printf 'RETURN %s\n' "$?"

echo "REACHED: jail run — no workflow identity, then no real namespace"
DOORBELL_WF_SELF=""
absorb_pending_rings
printf 'RETURN %s\n' "$?"
DOORBELL_WF_SELF=coordinate-perstack-self1; SCAN_PHASE_NS=unknown
absorb_pending_rings
printf 'RETURN %s\n' "$?"

echo "REACHED: end"
