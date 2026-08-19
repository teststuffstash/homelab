# Bridge for loop-fetch-guard fixture.
# Tests the core bash behavior: that assignment status propagates to ||, not export status.
#
# Setup: NS is used by the extracted LOOP_FETCH block; curl is shadowed to return test tokens.

NS="test-ns"
curl() {
  case "${1:-}" in
    *loop-git-token*)
      # Mock curl returning a test token on success
      printf 'test-token-12345'
      return 0
      ;;
    *)
      # Other curl calls should fail (shouldn't happen in this fixture)
      return 7
      ;;
  esac
}
export -f curl

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
