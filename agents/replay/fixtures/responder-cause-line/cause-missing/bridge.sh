# ── bridge ── the per-alert loop variables the bind-at-filing block reads.
#
# The block runs after the verdict-dispatch block, so VHIT and VREPO are already set from the
# open-issue search. This fixture simulates a valid Cause: #123 line in the filed issue body,
# but the cause issue #123 does NOT exist (returns no API ID). The block skips the link.
VHIT="999"
VREPO="teststuffstash/homelab"