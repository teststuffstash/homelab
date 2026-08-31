# ── the queued units ── same format as the sibling fixtures. Two cases:
#   #1100 touches `something+else` → should be HELD (governance path, correctly unescaped)
#   #1101 touches `something.else` → should be DISPATCHED (not a governance path)
CASES="homelab|1100|something+else|a path with a literal plus sign
homelab|1101|something.else|a path with a literal dot"
while IFS='|' read -r repo qnum qtouches qtitle; do
  [ -n "$qnum" ] || continue