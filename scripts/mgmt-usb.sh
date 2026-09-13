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
  # `|| true`: no by-id dir at all (the jail) must still list nothing and exit clean under set -e.
  ls -l /dev/disk/by-id/ 2>/dev/null | awk '/usb-/ && !/-part[0-9]+$/ {print "  /dev/disk/by-id/" $9 "  -> " $11}' || true
  echo "(nothing built — set the variable first)"
  exit 0
fi
DEV="$MGMT_USB_DEV"
[ -b "$DEV" ] || { echo "ERROR: $DEV is not a block device" >&2; exit 1; }
REAL="$(readlink -f "$DEV")"
case "$DEV" in /dev/disk/by-id/*) ;; *) echo "WARNING: $DEV is not a by-id path — enumeration moves with sticks plugged in (machines.yaml)" >&2 ;; esac
# sysfs, not lsblk: under `devbox run` lsblk answered nothing (2026-09-13, first run), which read
# as "not removable, 0 MiB". /sys/class/block is always there and needs no tool.
BLK="/sys/class/block/$(basename "$REAL")"
[ -d "$BLK" ] || { echo "ERROR: $BLK missing — is $REAL a whole disk (not a partition)?" >&2; exit 1; }
if [ "$(cat "$BLK/removable" 2>/dev/null || echo 0)" != "1" ]; then
  echo "ERROR: $REAL is NOT flagged removable — refusing (a system disk is one typo away). MGMT_USB_FORCE=1 overrides." >&2
  [ "${MGMT_USB_FORCE:-0}" = "1" ] || exit 1
fi
SIZE_B=$(( $(cat "$BLK/size") * 512 ))
if [ "$SIZE_B" -eq 0 ]; then
  # Seen 2026-09-13: a DataTraveler that had two partitions at plug-in re-enumerated as 0 sectors
  # (the by-id links were stale). The kernel sees no media — nothing here can fix that.
  echo "ERROR: the kernel reports $REAL with NO media (size 0) — re-plug the stick, ideally another port directly on the machine; if it stays 0 (check: sudo dmesg | grep -i $(basename "$REAL")) the stick is dead, use another" >&2; exit 1
fi
[ "$SIZE_B" -ge $((2 * 1024 * 1024 * 1024)) ] || { echo "ERROR: $REAL is $((SIZE_B / 1024 / 1024)) MiB — the ISO is ~1.5 GB" >&2; exit 1; }
if awk -v d="$REAL" '$1 ~ "^"d {found=1} END {exit !found}' /proc/mounts; then
  echo "ERROR: $REAL has mounted partitions — unmount first:" >&2; grep "^$REAL" /proc/mounts >&2; exit 1
fi
echo "target: $DEV -> $REAL  ($((SIZE_B / 1024 / 1024 / 1024)) GiB, removable=$(cat "$BLK/removable"))"
lsblk -o NAME,SIZE,TRAN,MODEL,RM "$REAL" 2>/dev/null || true
read -rp "Write the mgmt installer to $REAL? This ERASES it. Type 'yes': " ok
[ "$ok" = "yes" ] || { echo "aborted."; exit 1; }

# ── 2. build: only now ──────────────────────────────────────────────────────────────────────────
LINK="${MGMT_USB_OUT:-/tmp/mgmt-iso}"
echo "==> nix build $REPO/nixos#installerIso"
nix build "$REPO/nixos#installerIso" --out-link "$LINK"
ISO="$(readlink -f "$LINK"/iso/*.iso)"
echo "    $ISO ($(du -h "$ISO" | cut -f1))"

# ── 3. re-probe, write, verify ──────────────────────────────────────────────────────────────────
# The build above can take minutes; a re-plug or an sdX reassignment in that window (the stale
# by-id links seen on this very hardware) would leave $REAL naming a DIFFERENT disk. So the
# identity is re-derived right before the write and must match what was confirmed.
REAL2="$(readlink -f "$DEV" 2>/dev/null || true)"
[ -b "$REAL2" ] || { echo "ERROR: $DEV vanished after the build — re-plug and re-run" >&2; exit 1; }
[ "$REAL2" = "$REAL" ] || { echo "ERROR: $DEV now resolves to $REAL2, was $REAL when confirmed — re-run" >&2; exit 1; }
SIZE2=$(( $(cat "/sys/class/block/$(basename "$REAL2")/size") * 512 ))
[ "$SIZE2" -eq "$SIZE_B" ] || { echo "ERROR: $REAL2 changed size ($SIZE2 vs $SIZE_B) since it was confirmed — re-run" >&2; exit 1; }
if awk -v d="$REAL2" '$1 ~ "^"d {found=1} END {exit !found}' /proc/mounts; then
  echo "ERROR: $REAL2 got mounted meanwhile (desktop automount?) — unmount and re-run" >&2; exit 1
fi
echo "==> dd ($REAL2, re-verified)"
sudo dd if="$ISO" of="$REAL2" bs=4M status=progress oflag=sync conv=fsync
sync
echo "==> verify (byte-compare the written image)"
if sudo cmp -n "$(stat -c %s "$ISO")" "$ISO" "$REAL2"; then
  echo "OK: $REAL2 matches $ISO"
else
  echo "ERROR: $REAL2 does NOT match the ISO — bad stick or interrupted write" >&2; exit 1
fi
echo "Boot the box from the stick (one-time boot menu — PXE is out of its boot order), then from the jail:"
echo "  ssh -i ~/.claude/homelab-pve-ssh/id_ed25519 root@192.168.2.53   # the DHCP reservation"
echo "  [ -d /sys/firmware/efi ] && echo UEFI || echo legacy-BIOS ; ls -l /dev/disk/by-id/ | grep -v part ; ip -br link"
