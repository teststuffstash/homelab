# ── bridge ── the per-alert loop variables the bind-at-filing block reads.
#
# The block runs after the verdict-dispatch block, so VHIT and VREPO are already set from the
# open-issue search. This fixture simulates a valid Cause: #123 line in the filed issue body.
# The cause issue #123 read returns empty via per-call keying (STUB_GH_<slug>=empty),
# so the block skips the link with "not found or unreadable".
VHIT="999"
VREPO="teststuffstash/homelab"