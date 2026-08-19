# Shipped mc_event with duplicate detection (homelab#607).
. "$REPLAY_ROOT/agents/machine-comment.sh"

mc_now() { printf '2026-08-19T11:00:00Z'; }

echo "=== TEST: mc_event with duplicate marked comments (homelab#607) ==="
echo ""
echo "Scenario: Issue #43 carries TWO agent-summary comments (race condition)"
echo "  - 5231000042 @ 10:40:38Z (oldest; agent-session.sh, via mc_event)"
echo "  - 5231000099 @ 10:55:48Z (second writer, direct post, no mc_event)"
echo ""
echo "Action: mc_event appends a third event"
echo ""

mc_event "$IN_SLUG" "$IN_NUMBER" stats "**run stats (round 3)** — \`claude/opus\` · \$150 · 600s · ci=true"
EXIT_CODE=$?

echo ""
echo "=== RESULT ==="
echo "mc_event exit code: $EXIT_CODE"
printf 'RETURN %s\n' "$EXIT_CODE"

echo ""
echo "REACHED: end"
