#!/usr/bin/env bash
# jail-cluster-smoke — the rig's proof command, run INSIDE a jail-cluster pod (ADR-167):
#
#   devbox run jail-cluster -- run --name smoke -- bash scripts/jail-cluster-smoke.sh
#
# Passes when (0) a privileged container in the guest sees no host disk, (1) the dind sidecar answers
# `docker info` and (2) a one-node k3d cluster reaches a Ready node.
#
# Step 0 is THE GATE before anyone is handed a token (ADR-167): that a privileged container inside a
# kata guest on this cluster cannot reach nx-01's disks is an assumption about the kata build (the
# Talos extension's default config), not a fact anyone has checked. The probe: `docker run
# --privileged --pid=host` — the same power the dind sidecar holds — lists every block device the
# guest kernel exposes (/sys/block, sizes) and PID 1's mounts. A HOST DISK is any block device that
# is not one of the guest's own: loop/ram/zram/pmem/nbd/sr devices, devices of ≤ 1 GiB (the guest
# image / config drives), and the one 20 GiB scratch volume this pod requested (41943040 sectors).
# nx-01's real disks are hundreds of GB and match none of those. Anything else fails the smoke,
# and everything seen is printed and kept as evidence. A false positive fails safe. k3d, not kind: the kata spike's gate runtime (21–38 s to a cluster there), and kind's
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

# ── step 0: what does `privileged` expose inside this guest? ─────────────────────────────────────
SCRATCH_SECTORS=41943040        # the 20Gi docker-lib block PVC (agents/agent-session.sh DOCKER_VOLUMES)
SMALL_SECTORS=2097152           # 1 GiB
docker run --rm --privileged --pid=host --net=none busybox:1.36 sh -c '
  for b in /sys/block/*; do echo "BLK $(basename "$b") $(cat "$b/size")"; done
  echo "--- mounts (pid 1)"; cat /proc/1/mounts' > "$EV/guest-devices.txt"
cat "$EV/guest-devices.txt"
hostdisks="$(awk -v scratch="$SCRATCH_SECTORS" -v small="$SMALL_SECTORS" '
  $1 == "BLK" && $2 !~ /^(loop|ram|zram|pmem|nbd|sr)/ && $3 + 0 > small && $3 + 0 != scratch { print $2 " (" $3 " sectors)" }' "$EV/guest-devices.txt")"
if [ -n "$hostdisks" ]; then
  echo "JAIL-CLUSTER-SMOKE-FAILED: a privileged container in the guest sees block device(s) that are not the guest's own:" >&2
  printf '%s\n' "$hostdisks" | sed 's/^/  /' >&2
  echo "Treat the kata boundary as NOT holding: hand out no token, scale the rig down, read the kata config." >&2
  exit 4
fi
grep -q '^BLK ' "$EV/guest-devices.txt" || { echo "JAIL-CLUSTER-SMOKE-FAILED: the device probe listed nothing — the check did not run" >&2; exit 4; }
echo "guest devices: OK — no host disk visible to a privileged container"

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
