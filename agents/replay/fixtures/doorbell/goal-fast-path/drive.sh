# ── drive ── three legs: valid goal-decompose dispatches, bot-queued is refused, moved-on settles.
echo "REACHED: legitimate goal-decompose unit — dispatches"
fast_unit_dispatch "goal-decompose|circles|issue-5"
printf 'RETURN %s\n' "$?"

echo "REACHED: bot-queued goal — breaker #1 refuses"
fast_unit_dispatch "goal-decompose|circles|issue-6"
printf 'RETURN %s\n' "$?"

echo "REACHED: issue no longer agent/queued — settles, full scan decides"
fast_unit_dispatch "goal-decompose|circles|issue-7"
printf 'RETURN %s\n' "$?"

echo "REACHED: legitimate goal-checkpoint unit — dispatches"
fast_unit_dispatch "goal-checkpoint|circles|issue-8"
printf 'RETURN %s\n' "$?"

echo "REACHED: valueless Base: on decompose leg — refuses"
fast_unit_dispatch "goal-decompose|circles|issue-9"
printf 'RETURN %s\n' "$?"

echo "REACHED: block-authored Base: twin of #5 — dispatches, no legacy meter"
fast_unit_dispatch "goal-decompose|circles|issue-10"
printf 'RETURN %s\n' "$?"

echo "REACHED: malformed machine block — refuses"
fast_unit_dispatch "goal-decompose|circles|issue-11"
printf 'RETURN %s\n' "$?"

echo "REACHED: end"