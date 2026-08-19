# Bridge for loop-fetch-guard fixture.
# Tests the core bash behavior: that assignment status propagates to ||, not export status.

echo ">>> Case 1: Assignment propagates failure (NEW FIX)"
# This is the FIXED form: assignment (not export) followed by export
set +e
bash -c 'X="$(exit 7)" || { echo "GUARD_FIRED"; exit 1; }; export X' 2>&1
RC1=$?
set -e
echo "EXIT: $RC1"
echo

echo ">>> Case 2: Export masks failure (OLD BUG)"
# This is the BROKEN form: export masks the substitution status
set +e
bash -c 'export X="$(exit 7)" || { echo "GUARD_FIRED"; exit 1; }' 2>&1
RC2=$?
set -e
echo "EXIT: $RC2"
echo

echo ">>> Case 3: Success path (both forms should work)"
# Both forms work fine when curl succeeds
set +e
bash -c 'X="$(echo token)" || exit 1; export X; [ -n "$X" ] && echo "TOKEN_EXPORTED"' 2>&1
RC3=$?
set -e
echo "EXIT: $RC3"
echo

echo ">>> Case 4: Real concatenation in PREP (fixed form with trailing separator)"
# homelab#617 round 2: the fix must preserve the separator between export and the next command.
# LOOP_FETCH ends with "; export GH_TOKEN; " (trailing semicolon + space before the closing quote).
# When used in PREP="set -e; ${LOOP_FETCH}touch /work/marker; ...", it must parse as separate commands.
LOOP_FETCH='GH_TOKEN="$(echo faketoken)" || { echo FATAL; exit 1; }; export GH_TOKEN; '
PREP="set -e; ${LOOP_FETCH}touch /work/marker; echo REACHED"
set +e
bash -c "$PREP" 2>&1
RC4=$?
set -e
echo "EXIT: $RC4"
[ $RC4 -eq 0 ] && echo "REAL_CONCAT_OK" || echo "REAL_CONCAT_FAILED"
