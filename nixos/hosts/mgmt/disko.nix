# Disk layout for the management box — declarative, so the install is not a click-through.
#
# ⚠ FIRMWARE IS UNVERIFIED on the pilot box (Lenovo ThinkCentre Edge, ~2011 Sandy Bridge): it may
# be legacy-BIOS only. This layout carries BOTH a 1 MiB BIOS-boot partition (GRUB on MBR-less GPT)
# AND an ESP, so either firmware works from the same partitioning and a later move to systemd-boot
# needs no re-partition. Which bootloader is actually used is decided in default.nix.
#
# ⚠ INSTALL-TIME ONLY. Changing any of this on a provisioned disk does nothing — it needs a wipe.
{ config, lib, ... }:

let
  # ⚠ This device is ALSO what lands in `boot.loader.grub.devices`, so a placeholder does not just
  # break the install — it breaks every later `nixos-rebuild boot` (grub-install against a
  # nonexistent device), i.e. the promote path, on a box with no console. Hence the assertion.
  #
  # Read it in the installer: `ls -l /dev/disk/by-id/ | grep -v part`. NOT /dev/sdX — enumeration
  # on this box changes with a USB stick plugged in (machines.yaml), and this directive PARTITIONS.
  device = "/dev/disk/by-id/ata-KINGSTON_SV300S37A120G_50026B785500EFD9"; # read in the installer 2026-09-13
in
{
  disko.devices.disk.main = {
    inherit device;
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02"; # BIOS boot partition — GRUB's legacy path
        };
        ESP = {
          # 1.5G, not 512M: systemd-boot copies kernel+initrd for EVERY generation onto the ESP
          # (~50-100 MB each), so 512M holds roughly 5-8 and `nixos-rebuild boot` would start
          # failing with ENOSPC around generation 7 — precisely in the promote step. Install-time
          # only, so it has to be right now (review finding, 2026-09-12).
          size = "1500M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        swap = {
          size = "4G";
          content = {
            type = "swap";
            discardPolicy = "both";
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  assertions = [{
    assertion = !(lib.hasInfix "CHANGE-ME" device);
    message = ''
      nixos/hosts/mgmt/disko.nix still carries the CHANGE-ME device placeholder. Replace it with
      the real /dev/disk/by-id/... path read in the installer: it is both the install target AND
      what grub-install writes to on every later promotion, so a placeholder breaks the update
      loop and the manual rollback path, not merely the install.
    '';
  }];
}
