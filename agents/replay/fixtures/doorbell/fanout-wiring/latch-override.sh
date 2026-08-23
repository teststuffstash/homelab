# Replace the block-defined fanout_clear (which calls HERE/subscription-latch.sh —
# doesn't exist in the fixture context) with the test seam. Must come AFTER
# block:doorbell-fanout and BEFORE any call that exercises fanout_eligible.
fanout_clear() { [ "${LATCH:-clear}" = clear ]; }