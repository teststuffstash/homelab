#!/usr/bin/env bash
# Install and bootstrap a disposable, isolated one-node Talos control plane on an already-created
# nocloud VM. The generated credentials stay in OUTPUT_DIR and must never be committed.
#
#   scripts/controlplane-lab-install.sh <free-lab-ip> /tmp/cp-upgrade-lab
#
# The IP is BORROWED: clear it first (git grep + nmap -sn, docs/ip-plan.md). .65 (the 2026-09-20 run's)
# is production cp-02 now (docs/controlplane-ha.md §CP4). Run it with TALOSCONFIG/KUBECONFIG UNSET:
# `devbox run` points them at production's configs (tools on PATH instead).
set -euo pipefail

IP="${1:-}"
OUT="${2:-}"
[ -n "$IP" ] && [ -n "$OUT" ] || { echo "usage: $0 <vm-ip> <output-dir>" >&2; exit 64; }
[ ! -e "$OUT" ] || { echo "FAIL: output path already exists: $OUT" >&2; exit 2; }
mkdir -m 700 -p "$OUT"

OLD_VERSION="${OLD_VERSION:-v1.13.2}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-1.36.1}"
OLD_SCHEMATIC="${OLD_SCHEMATIC:-ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515}"
OLD_INSTALLER="${OLD_INSTALLER:-factory.talos.dev/nocloud-installer/$OLD_SCHEMATIC:$OLD_VERSION}"

talosctl gen config cp-upgrade-lab "https://$IP:6443" \
  --output "$OUT" --output-types controlplane,talosconfig \
  --install-disk /dev/sda --install-image "$OLD_INSTALLER" \
  --talos-version "$OLD_VERSION" --kubernetes-version "$KUBERNETES_VERSION" \
  --with-docs=false --with-examples=false
chmod 600 "$OUT"/*

echo "Applying isolated control-plane config to $IP"
talosctl apply-config --insecure -n "$IP" -f "$OUT/controlplane.yaml"
until talosctl --talosconfig "$OUT/talosconfig" -n "$IP" -e "$IP" version --short >/dev/null 2>&1; do sleep 5; done
talosctl --talosconfig "$OUT/talosconfig" -n "$IP" -e "$IP" bootstrap
until talosctl --talosconfig "$OUT/talosconfig" -n "$IP" -e "$IP" kubeconfig "$OUT/kubeconfig" --force >/dev/null 2>&1; do sleep 5; done
chmod 600 "$OUT/kubeconfig"
# kubeconfig is served before kube-apiserver necessarily has its socket open. Treat API reachability
# as its own asynchronous boot condition instead of letting the first kubectl connection refuse end
# the install (caught by the 2026-09-19 nx-02 rehearsal).
until kubectl --kubeconfig "$OUT/kubeconfig" get node cp-upgrade-lab >/dev/null 2>&1; do sleep 5; done
kubectl --kubeconfig "$OUT/kubeconfig" wait --for=condition=Ready "node/cp-upgrade-lab" --timeout=10m
echo "OK: isolated control plane is Ready; credentials: $OUT"
