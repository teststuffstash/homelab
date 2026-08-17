# ── drive ── one unit straight through the real fast path: a CHANGES_REQUESTED PR whose item has
# a RUNNING coordinator session pod.
echo "REACHED: worker-authored PR with a live session pod — held before dispatch"
fast_unit_dispatch "changes-requested|circles|pr-396"
printf 'RETURN %s\n' "$?"

echo "REACHED: end"
