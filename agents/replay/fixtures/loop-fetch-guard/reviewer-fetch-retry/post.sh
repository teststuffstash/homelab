# Post: run the extracted LOOP_FETCH under a curl mock that reads its own argv.
cat() {
  if [ "$1" = "/var/run/secrets/kubernetes.io/serviceaccount/token" ]; then printf 'mock-sa-token'; return 0; fi
  command cat "$@"
}
export -f cat

echo ">>> Case 1: the reviewer fetch carries the retry flags"
curl() {
  case "$*" in
    *role=reviewer*"--retry 3 --retry-delay 2 --retry-connrefused"*|*"--retry 3 --retry-delay 2 --retry-connrefused"*role=reviewer*) echo "RETRY_FLAGS_OK reviewer" >&2 ;;
    *) echo "RETRY_FLAGS_MISSING ($*)" >&2 ;;
  esac
  printf 'mock-token-for-test'; return 0
}
export -f curl
set +e
bash -c "set -e; ${LOOP_FETCH}[ \"\$GH_TOKEN\" = mock-token-for-test ] && echo TOKEN_EXPORTED" 2>&1
RC1=$?
set -e
echo "EXIT: $RC1"

echo ">>> Case 2: a fetch that fails after retrying still fails closed"
curl() { return 22; }
export -f curl
set +e
bash -c "set -e; ${LOOP_FETCH}echo BLIND_REVIEW_STARTED" 2>&1
RC2=$?
set -e
echo "EXIT: $RC2"
