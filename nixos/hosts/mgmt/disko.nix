# Disk layout for the management box — declarative, so the install is not a click-through.
#
# ⚠ FIRMWARE IS UNVERIFIED on the pilot box (Lenovo ThinkCentre Edge, ~2011 Sandy Bridge): it may
# be legacy-BIOS only. This layout carries BOTH a 1 MiB BIOS-boot partition (GRUB on MBR-less GPT)
# AND an ESP, so either firmware works from the same partitioning and a later move to systemd-boot
# needs no re-partition. Which bootloader is actually used is decided in default.nix.
#
# ⚠ INSTALL-TIME ONLY. Changing this on a provisioned disk does nothing — it needs a wipe.
{
  disko.devices.disk.main = {
    # The 120 GB Kingston SV300S3 in the pilot. ⚠ /dev/sdX is enumeration-order dependent on this
    # box (it is /dev/sdb with no USB stick plugged, /dev/sdc with one — machines.yaml). The
    # installer runs WITH the stick in, so override at install time with the by-id path:
    #   nixos-anywhere --disk-args ... or edit this line before the one install.
    device = "/dev/disk/by-id/CHANGE-ME-AT-INSTALL";
    type = "disk";
    content = {
      type = "gpt";
      partitions = {
        boot = {
          size = "1M";
          type = "EF02"; # BIOS boot partition — GRUB's legacy path
        };
        ESP = {
          size = "512M";
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
}
