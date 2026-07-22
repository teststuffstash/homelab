#!/bin/bash
# hubble-observe — fleet-wide hubble observe through the relay (the AgentWorkerEgressDropped
# runbook recipe: `devbox run hubble -- -n <ns> --verdict DROPPED`). The local hubble CLI needs
# relay reachability, so this port-forwards hubble-relay for the duration of one observe.
# NB an in-agent `kubectl exec ds/cilium -- hubble observe` sees ONE NODE's ring buffer only —
# that single-node blind spot is why this goes through the relay (bit the meta 2026-07-22).
set -euo pipefail
KUBECTL="${KUBECTL:-kubectl}"
KUBECONFIG="${KUBECONFIG:-tofu/kubeconfig}"
PORT="${HUBBLE_LOCAL_PORT:-24245}"

"$KUBECTL" --kubeconfig "$KUBECONFIG" -n kube-system port-forward svc/hubble-relay "${PORT}:80" >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null || true' EXIT
for _ in $(seq 1 20); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  sleep 0.5
done
hubble observe --server "localhost:${PORT}" "$@"
