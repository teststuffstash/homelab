# ── bridge ── the per-alert loop variables the bind-at-filing block reads.
#
# The block runs after the verdict-dispatch block, so VHIT and VREPO are already set from the
# open-issue search. This fixture simulates a valid Cause: #123 line in the filed issue body.
# The cause issue #123 exists and returns an API ID; the POST to /sub_issues succeeds.
VHIT="999"
VREPO="teststuffstash/homelab"