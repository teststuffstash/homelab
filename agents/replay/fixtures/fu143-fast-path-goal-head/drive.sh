# ── drive ── one unit, straight through the real fast path.
echo "REACHED: assembly PR with goal/** head — falls through to full scan for goal-checkpoint emit"
rc=0
fast_unit_dispatch "changes-requested|oracle-fleet|pr-309" || rc=$?
printf 'RETURN %s\n' "$rc"

echo "REACHED: end"