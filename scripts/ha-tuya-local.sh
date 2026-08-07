#!/usr/bin/env bash
# Install/refresh the `tuya_local` custom component in Home Assistant (FU-038).
#
# WHY A SCRIPT AND NOT HACS: this HA has no HACS and does not need it for one component. HA config
# here is applied imperatively (docs/runbook.md §Home Assistant — `kubectl cp` + restart), and the
# component lives on the /config Longhorn PVC, so it survives pod restarts and image bumps.
#
# WHY PINNED: an auto-updating integration would silently change the device-config YAMLs that map
# each model's DPs, and a wrong DP map is a wrong power reading — which is exactly the kind of
# quiet-wrong this repo's pin-only convention exists to prevent. Bump VERSION deliberately.
#
# The component is HALF the job: it needs one config entry per device (host + device_id +
# local_key + protocol version). Those are created by scripts/ha-tuya-local-devices.sh from the
# wallet material, which is the part that must never be hand-typed.
set -euo pipefail

VERSION="2026.7.2"                    # https://github.com/make-all/tuya-local/releases
NS="home-assistant"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KUBECONFIG="${KUBECONFIG:-$ROOT/tofu/kubeconfig}"; export KUBECONFIG
command -v kubectl >/dev/null 2>&1 || { PATH="$ROOT/.devbox/nix/profile/default/bin:$PATH"; export PATH; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "→ fetching tuya-local $VERSION"
curl -fsSL "https://github.com/make-all/tuya-local/archive/refs/tags/${VERSION}.tar.gz" -o "$TMP/src.tgz"
echo "  sha256: $(sha256sum "$TMP/src.tgz" | cut -d' ' -f1)"
tar -xzf "$TMP/src.tgz" -C "$TMP"
SRC="$(find "$TMP" -maxdepth 3 -type d -name tuya_local -path '*/custom_components/*' | head -1)"
[ -d "$SRC" ] || { echo "tuya_local not found in the tarball" >&2; exit 1; }
echo "  device configs bundled: $(find "$SRC/devices" -name '*.yaml' 2>/dev/null | wc -l)"

POD="$(kubectl -n "$NS" get pod -l app=home-assistant -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[ -n "$POD" ] || POD="$(kubectl -n "$NS" get pod -o jsonpath='{.items[0].metadata.name}')"
echo "→ installing into $POD:/config/custom_components/tuya_local"
kubectl -n "$NS" exec "$POD" -- mkdir -p /config/custom_components
kubectl -n "$NS" exec "$POD" -- rm -rf /config/custom_components/tuya_local
kubectl -n "$NS" cp "$SRC" "$NS/$POD:/config/custom_components/tuya_local"
kubectl -n "$NS" exec "$POD" -- sh -c 'ls /config/custom_components/tuya_local/manifest.json >/dev/null' \
  || { echo "copy failed" >&2; exit 1; }
echo "  installed version: $(kubectl -n "$NS" exec "$POD" -- sh -c 'grep -o "\"version\": \"[^\"]*\"" /config/custom_components/tuya_local/manifest.json' || true)"

echo "→ restarting Home Assistant (HA installs the component's python requirements on boot)"
kubectl -n "$NS" delete pod "$POD" --wait=false >/dev/null
echo "  done — wait for the pod to become Ready, then run scripts/ha-tuya-local-devices.sh"
