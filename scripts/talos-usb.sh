#!/usr/bin/env bash
# Build a Talos "maintenance-mode" USB stick from the Image Factory metal ISO — the
# no-PXE onboarding path (for boxes with broken PXE firmware, e.g. the ThinkCentre).
# Boot a box from this stick -> Talos comes up in maintenance mode (disk untouched),
# then onboard it exactly like a PXE node: reserve its IP, `talosctl get disks`, add to
# tofu/metal.tf, `tofu apply -target=...`.
#
# Usage (run on the HOST where the USB stick is plugged in):
#   devbox run talos-usb                      # download ISO + list candidate devices
#   TALOS_USB_DEV=/dev/sdX devbox run talos-usb   # download + flash (asks to confirm)
#
# Keep TALOS_VERSION / TALOS_SCHEMATIC in lockstep with tofu (var.talos_version) and
# ansible/matchbox-talos-assets.yml so USB-onboarded nodes match PXE-onboarded ones.
set -euo pipefail

TALOS_VERSION="${TALOS_VERSION:-v1.13.2}"
TALOS_SCHEMATIC="${TALOS_SCHEMATIC:-613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245}"
ISO_URL="https://factory.talos.dev/image/${TALOS_SCHEMATIC}/${TALOS_VERSION}/metal-amd64.iso"
OUT="${TALOS_ISO_OUT:-/tmp/talos-${TALOS_VERSION}-metal-amd64.iso}"

echo "Talos metal ISO (${TALOS_VERSION}, schematic ${TALOS_SCHEMATIC:0:12}…)"
echo "  $ISO_URL"
curl -fSL --progress-bar "$ISO_URL" -o "$OUT"
echo "  -> $OUT ($(du -h "$OUT" | cut -f1))"

if [ -z "${TALOS_USB_DEV:-}" ]; then
  echo
  echo "Candidate block devices (pick your USB stick — NOT a system disk):"
  lsblk -dno NAME,SIZE,TRAN,MODEL 2>/dev/null | sed 's/^/  /' || true
  echo
  echo "Then flash with:  TALOS_USB_DEV=/dev/sdX devbox run talos-usb"
  exit 0
fi

DEV="$TALOS_USB_DEV"
[ -b "$DEV" ] || { echo "ERROR: $DEV is not a block device"; exit 1; }
echo
lsblk "$DEV"
if [ "$(lsblk -dno RM "$DEV" 2>/dev/null || echo 0)" != "1" ]; then
  echo "WARNING: $DEV is NOT flagged removable — make sure this isn't a system disk!"
fi
read -rp "Flash $OUT to $DEV? This ERASES $DEV. Type 'yes' to proceed: " ok
[ "$ok" = "yes" ] || { echo "aborted."; exit 1; }

sudo dd if="$OUT" of="$DEV" bs=4M status=progress conv=fsync
sync
echo "Done. Boot the target box from $DEV -> Talos maintenance mode -> onboard via tofu/metal.tf."
