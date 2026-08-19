# Post-test for Case 4: Real concatenation using the extracted LOOP_FETCH block.
# The extracted block (loop-fetch-guard sentinels in coordinator-session.sh) has now set LOOP_FETCH
# with the production string including variable interpolation from NS.
# This case proves that LOOP_FETCH + following commands parse correctly and execute as intended.

echo ">>> Case 4: Real concatenation in PREP (fixed form with trailing separator)"

# Shadow cat to mock the service account token read
cat() {
  if [ "$1" = "/var/run/secrets/kubernetes.io/serviceaccount/token" ]; then
    printf 'mock-service-account-token'
    return 0
  fi
  # Delegate other cat calls to the real command
  command cat "$@"
}
export -f cat

# Shadow curl to mock the token endpoint
curl() {
  case "$*" in
    *loop-git-token*ns=test-ns*)
      # Mock curl returning a test token
      printf 'mock-token-for-test'
      return 0
      ;;
    *)
      # Unexpected curl call
      printf 'UNEXPECTED_CURL: %s\n' "$*" >&2
      return 1
      ;;
  esac
}
export -f curl

# Test the real concatenation: LOOP_FETCH + touch should parse and execute correctly
MARKER_DIR="$(mktemp -d)"
PREP="set -e; ${LOOP_FETCH}touch ${MARKER_DIR}/marker; echo REACHED"

set +e
bash -c "$PREP" 2>&1
RC4=$?
set -e

echo "EXIT: $RC4"
[ $RC4 -eq 0 ] && echo "REAL_CONCAT_OK" || echo "REAL_CONCAT_FAILED"
