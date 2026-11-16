# the kubelet OOM-killed the agent container (exit 137, reason OOMKilled); the launcher's classifier
# reads that verdict in the same call as the pod reason (row overlay kubectl/get-pod-…txt).
.items[0].status.containerStatuses[0].state.terminated |= (.exitCode = 137 | .reason = "OOMKilled")
