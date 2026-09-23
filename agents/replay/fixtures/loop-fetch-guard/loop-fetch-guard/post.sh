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

echo ">>> Case 5: intake fetch degrades non-fatally (homelab#1095)"
# The coordinator fetch succeeds; the INTAKE fetch (role=intake) fails. Contract: WARN line,
# GH_TOKEN_INTAKE exported EMPTY, session continues — never a fatal (the #1136 degrade shape).
curl() {
  case "$*" in
    *role=intake*)                  return 7 ;;
    *loop-git-token*ns=test-ns*)    printf 'mock-token-for-test'; return 0 ;;
    *)                              printf 'UNEXPECTED_CURL: %s\n' "$*" >&2; return 1 ;;
  esac
}
export -f curl

PREP5="set -e; ${LOOP_FETCH}[ -z \"\$GH_TOKEN_INTAKE\" ] && echo INTAKE_EMPTY; echo REACHED5"
set +e
bash -c "$PREP5" 2>&1
RC5=$?
set -e
echo "EXIT: $RC5"

echo ">>> Case 6: the fetch retries a blip (2026-09-23, PR#1932)"
# The proxy answers 503 + Retry-After for a transient k8s read miss and connection-refused during
# its own restarts; curl only retries either with these flags. Both LOOP_FETCH fetches
# (role=coordinator, role=intake) must carry them — the mock reads its own argv ("$*").
curl() {
  role="unknown"; case "$*" in *role=intake*) role=intake ;; *role=coordinator*) role=coordinator ;; esac
  case "$*" in
    *"--retry 3 --retry-delay 2 --retry-connrefused"*) echo "RETRY_FLAGS_OK ${role}" >&2 ;;
    *)                                                  echo "RETRY_FLAGS_MISSING ${role}" >&2 ;;
  esac
  printf 'mock-token-for-test'
  return 0
}
export -f curl
PREP6="set -e; ${LOOP_FETCH}echo REACHED6"
set +e
bash -c "$PREP6" 2>&1
RC6=$?
set -e
echo "EXIT: $RC6"
