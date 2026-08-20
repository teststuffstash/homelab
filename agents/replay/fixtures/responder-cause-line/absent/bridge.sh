# ── bridge ── the per-alert loop variables the bind-at-filing block reads.
#
# The block runs after the verdict-dispatch block, so VHIT and VREPO are already set from the
# open-issue search. This fixture simulates an issue body with NO Cause: line at all.
# The block reads the body, finds no matching line, and skips the sub-issue link entirely.
VHIT="999"
VREPO="teststuffstash/homelab"