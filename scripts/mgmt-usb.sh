#!/usr/bin/env bash
# Write the management box's installer stick (ADR-129, docs/management-box.md §OS and install).
# The stick is the flake's `installerIso` output — the minimal NixOS ISO + sshd + our two keys —
# so the box is reachable headless from the jail the moment it boots; nixos-anywhere does the
# install from git afterwards.
#
# Run on the HOST where the stick is plugged in (it has nix: the jail's builds go through this
# host's daemon, and /nix is shared). PROBE FIRST, BUILD SECOND: the target device is validated
# and confirmed before a single derivation is built, so a missing/wrong MGMT_USB_DEV costs
# nothing (the snore-recorder rpi-usb.sh got this backwards — 1.5 GB built, then "pick a device").
#
#   devbox run mgmt-usb                                   # list candidate devices, exit
#   MGMT_USB_DEV=/dev/disk/by-id/usb-... devbox run mgmt-usb   # probe → confirm → build → dd → verify
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

# ── 1. probe: the device, before anything else ──────────────────────────────────────────────────
if [ -z "${MGMT_USB_DEV:-}" ]; then
  echo "Pick the USB stick (NOT a system disk) and re-run with MGMT_USB_DEV=/dev/disk/by-id/usb-...:"
  ls -l /dev/disk/by-id/ 2>/dev/null | awk '/usb-/ && !/-part[0-9]+$/ {print "  /dev/disk/by-id/" $9 "  -> " $11}'
  echo "(nothing built — set the variable first)"
  exit 0
fi
DEV="$MGMT_USB_DEV"
[ -b "$DEV" ] || { echo "ERROR: $DEV is not a block device" >&2; exit 1; }
REAL="$(readlink -f "$DEV")"
case "$DEV" in /dev/disk/by-id/*) ;; *) echo "WARNING: $DEV is not a by-id path — enumeration moves with sticks plugged in (machines.yaml)" >&2 ;; esac
if [ "$(lsblk -dno RM "$REAL" 2>/dev/null || echo 0)" != "1" ]; then
  echo "ERROR: $REAL is NOT flagged removable — refusing (a system disk is one typo away). MGMT_USB_FORCE=1 overrides." >&2
  [ "${MGMT_USB_FORCE:-0}" = "1" ] || exit 1
fi
SIZE_B="$(lsblk -dnbo SIZE "$REAL")"
[ "$SIZE_B" -ge $((2 * 1024 * 1024 * 1024)) ] || { echo "ERROR: $REAL is $((SIZE_B / 1024 / 1024)) MiB — the ISO is ~1.5 GB" >&2; exit 1; }
if lsblk -no MOUNTPOINT "$REAL" | grep -q .; then
  echo "ERROR: $REAL has mounted partitions — unmount first:" >&2; lsblk "$REAL" >&2; exit 1
fi
echo "target: $DEV -> $REAL"; lsblk -o NAME,SIZE,TRAN,MODEL,RM "$REAL"
read -rp "Write the mgmt installer to $REAL? This ERASES it. Type 'yes': " ok
[ "$ok" = "yes" ] || { echo "aborted."; exit 1; }

# ── 2. build: only now ──────────────────────────────────────────────────────────────────────────
LINK="${MGMT_USB_OUT:-/tmp/mgmt-iso}"
echo "==> nix build $REPO/nixos#installerIso"
nix build "$REPO/nixos#installerIso" --out-link "$LINK"
ISO="$(readlink -f "$LINK"/iso/*.iso)"
echo "    $ISO ($(du -h "$ISO" | cut -f1))"

# ── 3. write + verify ───────────────────────────────────────────────────────────────────────────
echo "==> dd"
sudo dd if="$ISO" of="$REAL" bs=4M status=progress oflag=sync conv=fsync
sync
echo "==> verify (byte-compare the written image)"
if sudo cmp -n "$(stat -c %s "$ISO")" "$ISO" "$REAL"; then
  echo "OK: $REAL matches $ISO"
else
  echo "ERROR: $REAL does NOT match the ISO — bad stick or interrupted write" >&2; exit 1
fi
echo "Boot the box from the stick (one-time boot menu — PXE is out of its boot order), then from the jail:"
echo "  ssh -i ~/.claude/homelab-pve-ssh/id_ed25519 root@192.168.2.53   # the DHCP reservation"
echo "  [ -d /sys/firmware/efi ] && echo UEFI || echo legacy-BIOS ; ls -l /dev/disk/by-id/ | grep -v part ; ip -br link"
