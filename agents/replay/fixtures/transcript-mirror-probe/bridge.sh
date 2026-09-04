# ── bridge ── the launcher variables the transcript-mirror-probe block reads.
# The probe checks for the agent-transcripts-s3 secret before every ride.
#
# The launcher SA has no Secret access by design, so Forbidden is the expected
# outcome on every dispatch. This fixture pins all three probe outcomes.
KUBECTL="kubectl"
KUBE=""
NS="agent-runtime"

# Shadow kubectl with a function that returns the configured error mode.
# The composed block calls `"$KUBECTL" $KUBE -n "$NS" get secret agent-transcripts-s3`,
# which resolves to this function (bash resolves functions before PATH lookups).
kubectl() {
  # Record the call in the action stream (same format as the replay stub)
  printf 'CALL kubectl' >> "$REPLAY_ACTIONS"
  for a in "$@"; do
    printf ' %s' "$a" >> "$REPLAY_ACTIONS"
  done
  printf '\n' >> "$REPLAY_ACTIONS"

  mode="${STUB_KUBECTL_MODE:-notfound}"
  case "$mode" in
    forbidden)
      echo 'Error from server (Forbidden): secrets is forbidden: User "system:serviceaccount:platform-agents:agentstack-loop" cannot list resource "secrets" in API group "" in the namespace "agent-runtime"' >&2
      return 1
      ;;
    notfound)
      echo 'Error from server (NotFound): secrets "agent-transcripts-s3" not found' >&2
      return 1
      ;;
    ok)
      # Secret exists — exit 0 (probe passes, no message)
      return 0
      ;;
    *)
      echo 'Error from server (InternalError): an internal error occurred' >&2
      return 1
      ;;
  esac
}