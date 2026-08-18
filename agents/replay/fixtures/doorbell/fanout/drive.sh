# ── drive ── override the latch seam (block-defined, so the override must come after it), then
# run the arms. Every leg resets the per-scan caches the block keeps (wake, latch, said-once).
fanout_clear() { [ "${LATCH:-clear}" = clear ]; }
reset_scan() { DISPATCH_PHASE_WAKE="${1:?wake}"; FANOUT_LATCH=""; FANOUT_LATCH_SAID=""; }

echo "REACHED: edge-woken, repo scope all — every graduated stack rings"
reset_scan "edge|1786464880"; SCAN_RING_NS=""; SCAN_REPO=all
fanout_stack circles; fanout_stack sleep

echo "REACHED: repo-scoped — only the owning stack rings"
reset_scan "edge|1786464880"; SCAN_REPO=snore-recorder
fanout_stack circles; fanout_stack sleep

echo "REACHED: already routed (SCAN_RING_NS set) — no ring, the perstack trigger had it"
reset_scan "edge|1786464880"; SCAN_REPO=all; SCAN_RING_NS=circles-agents
fanout_stack circles; fanout_stack sleep
SCAN_RING_NS=""

echo "REACHED: cron wake — the backstop never fans out"
reset_scan "cron|"
fanout_stack circles; fanout_stack sleep

echo "REACHED: latched — held, said once"
reset_scan "edge|1786464880"; LATCH=held
fanout_stack circles; fanout_stack sleep
LATCH=clear

echo "REACHED: unit delegation — the fast-path forwards the unit in the ring"
reset_scan "edge|1786464880"
fanout_eligible && fanout_ring sleep "changes-requested|snore-recorder|pr-7"

echo "REACHED: ring refused — loud, cron named as owner"
reset_scan "edge|1786464880"
CURL_RC=7 fanout_stack circles

echo "REACHED: end"
