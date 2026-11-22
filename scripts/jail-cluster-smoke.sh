#!/usr/bin/env bash
# jail-cluster-smoke — the rig's proof command, run INSIDE a jail-cluster pod (ADR-167):
#
#   devbox run jail-cluster -- run --name smoke -- bash scripts/jail-cluster-smoke.sh
#
# Passes when the dind sidecar answers `docker info` and a one-node k3d cluster reaches a Ready
# node. k3d, not kind: the kata spike's gate runtime (21–38 s to a cluster there), and kind's
# default node image segfaulted in a kata dind (docs/spikes/kata-ci-gate.md §In-pod kind). The k3s
# node pulls ride the mirrors (registries.yaml); k3d's own helper images pull from ghcr.io (the
# docker-ride egress leg). Evidence: docker info, the node list and timings in $JAIL_EVIDENCE_DIR.
set -euo pipefail
EV="${JAIL_EVIDENCE_DIR:-/tmp/jail-cluster-smoke}"; mkdir -p "$EV"
NAME="smoke-$$"
t0=$(date +%s)
cleanup() { k3d cluster delete "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker info > "$EV/docker-info.txt"
echo "docker info: OK ($(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'))"

REG="$(mktemp)"
cat > "$REG" <<EOF
mirrors:
  docker.io:
    endpoint: ["${REGISTRY_MIRROR_DOCKER_IO:-http://192.168.40.20}"]
  ghcr.io:
    endpoint: ["${REGISTRY_MIRROR_GHCR:-http://192.168.40.21}"]
EOF
k3d cluster create "$NAME" --no-lb --wait --timeout 300s --registry-config "$REG" 2>&1 | tee "$EV/k3d-create.log"
t1=$(date +%s)
docker exec "k3d-${NAME}-server-0" kubectl wait --for=condition=Ready node --all --timeout=180s
docker exec "k3d-${NAME}-server-0" kubectl get nodes -o wide | tee "$EV/nodes.txt"
t2=$(date +%s)
printf 'cluster_create_s=%s node_ready_s=%s total_s=%s\n' "$((t1 - t0))" "$((t2 - t1))" "$((t2 - t0))" | tee "$EV/timings.txt"
echo "JAIL-CLUSTER-SMOKE-PASSED"
