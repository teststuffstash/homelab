# kube.sh — how a launcher reaches kubectl. ONE implementation, two callers.
#
# Sourced by `agent-session.sh` (dispatch: worker pods, session keys, endpoint probes) and by
# `retro-session.sh` (the retro cell's own ephemeral key mint, homelab#270). It was inline
# launcher shell until the retro lane needed the same four lines — and a second copy of a
# *resolution* is worse than a second copy of arithmetic: the two callers run in the SAME two
# places (the jail and the coordinator image), so a copy that drifts drifts silently, in the one
# environment its author was not testing in. Same division as argv-guard.sh / goal-budget.sh: this
# file resolves, it never calls the cluster and never exits.
#
# Sets two variables, used together as `"$KUBECTL" $KUBE -n <ns> …`:
#
#   KUBE     `--kubeconfig <repo>/tofu/kubeconfig` when the jail's kubeconfig is present, else
#            EMPTY — inside a pod there is no such file and kubectl auto-detects the in-cluster
#            ServiceAccount. $KUBE is deliberately UNQUOTED at every call site: empty must expand
#            to no argument at all, which `"$KUBE"` would not do.
#   KUBECTL  the binary. PATH first (the coordinator image ships one), then this repo's devbox
#            profile (in the jail the nix tools are NOT on the bare PATH), then a bare `kubectl`
#            so a missing tool fails as kubectl's own "command not found" rather than as a path
#            we invented.
K_HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -f "${K_HERE}/../tofu/kubeconfig" ]; then KUBE="--kubeconfig ${K_HERE}/../tofu/kubeconfig"; else KUBE=""; fi
KUBECTL="$(command -v kubectl || true)"
[ -n "$KUBECTL" ] || KUBECTL="${K_HERE}/../.devbox/nix/profile/default/bin/kubectl"
[ -x "$KUBECTL" ] || KUBECTL="kubectl"

# live_worker_pod_count — count pods whose agent container has not terminated.
# ONE predicate, ONE home (agents/kube.sh), called by both the scan's WIP ceiling
# (coordinator-scan.sh) and the launcher's PREFLIGHT (agent-session.sh); a pod is
# live to both or to neither. Semantics: an exited agent is not a worker, per the
# scan's zombie reaper assumption.
#
# A pod is counted as live if:
#   1. Its phase is not terminal (Succeeded or Failed)
#   2. Its agent container HAS NOT terminated (including Pending pods, Unknown, unset phase)
#   3. For Pending specifically: schedulable or younger than 30 seconds (the launcher's grace period)
#
# Usage: live_worker_pod_count <json-pod-list>
# Returns: the count of live-agent pods, printed to stdout.
live_worker_pod_count() {
  printf '%s' "$1" | jq '[.items[]
    | select(.status.phase != "Succeeded" and .status.phase != "Failed")
    | select(
      .status.phase == "Running" or .status.phase == "Unknown" or
      (.status.phase == "Pending" and (
        ([.status.conditions[]? | select(.type == "PodScheduled" and .status == "False" and .reason == "Unschedulable")] | length) == 0
        or
        (now - (.metadata.creationTimestamp | fromdateiso8601)) < 30
      )) or
      (.status.phase | not)
    )
    | select(([.status.containerStatuses[]? | select(.name == "agent") | .state.terminated
               | select(. != null)] | length) == 0)] | length' 2>/dev/null || echo 0
}
