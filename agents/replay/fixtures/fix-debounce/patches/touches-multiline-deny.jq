# S6 sprout (#716): a SECOND Touches: line carrying a deny-listed path (a box verb — plain
# scripts/ left the ❌ set in the ADR-142 trial, 2026-09-28, so the row names one that stayed) — the
# queue-time gate must read the UNION of every line. Under the pre-fix head -1 read only the
# first line (agents/coordinator/retro-argo.yaml, not denied) was seen and the issue QUEUED —
# the fail-open this row red-cases. Patches the PER-ISSUE read (the payload sq_decide consumes);
# base is CLEAN #237, this row appends the superseding line.
.body += "\n\nSecond consumer widens the footprint:\nTouches: scripts/node-maintenance.sh"
