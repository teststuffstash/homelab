# ── bridge ── the per-alert loop variables the bind-at-filing block reads.
#
# The block runs after the verdict-dispatch block, so VHIT and VREPO are already set from the
# open-issue search. This fixture simulates an issue body with 'Cause: invalid' — a line that
# does NOT match the '^Cause: #[0-9]+' pattern. The block reads the body, the grep returns
# empty, and no sub-issue link is attempted.
VHIT="999"
VREPO="teststuffstash/homelab"