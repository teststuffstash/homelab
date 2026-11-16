# ── the queued unit ── `repo|qnum|qtitle|qclass|qtouches|qbase`, the shape the queued loop holds
# by the footprint check (qtouches already normalized). #60 is a MASTER issue whose footprint
# overlaps in-progress #50's `gateway/src/agent_gateway/` — the #3420-behind-#3308 shape.
CASES="homelab|60|gateway: sessions retry outcome|build|gateway/specs/glossary.md, gateway/src/agent_gateway/sessions.py|"
while IFS='|' read -r repo qnum qtitle qclass qtouches qbase; do
  [ -n "$qnum" ] || continue
