# ── bridge ── the shipped helper from the checkout, one seam redefined. Same shape as
# fixtures/summary-comment-first-touch/bridge.sh; the difference under test is the WORLD, not the
# call — which is the point of holding the invocation constant across the two.
. "$REPLAY_ROOT/agents/machine-comment.sh"

mc_now() { printf '2026-08-09T13:30:00Z'; }

mc_event "$IN_SLUG" "$IN_NUMBER" stats "**run stats** — \`claude/haiku\` · \$0 · 402s · ci=false"
printf 'RETURN %s\n' "$?"
echo "REACHED: end"
