# ── bridge ── source the SHIPPED helper and redefine exactly the wall clock.
#
# Test the marker anchoring fix (homelab#630): a comment that merely QUOTES the marker
# inline should NOT be counted as a duplicate or append target.
. "$REPLAY_ROOT/agents/machine-comment.sh"

mc_now() { printf '2026-08-19T11:05:00Z'; }

mc_event "$IN_SLUG" "$IN_NUMBER" stats "**round 2 complete** — deployment stable, all metrics green"
printf 'RETURN %s\n' "$?"
echo "REACHED: end"
