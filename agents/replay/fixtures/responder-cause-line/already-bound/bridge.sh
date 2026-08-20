# ── bridge ── the per-alert loop variables the bind-at-filing block reads.
#
# The block runs after the verdict-dispatch block, so VHIT and VREPO are already set from the
# open-issue search. This fixture simulates a valid Cause: #123 line in the filed issue body,
# where the filed issue ALREADY has a parent (simulating a re-dispatch on a flapping alert-fp).
# The cause issue #123 exists and returns an API ID; the parent check finds an existing parent
# and skips the POST.
VHIT="999"
VREPO="teststuffstash/homelab"