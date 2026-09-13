# The installer stick for the management box (ADR-129, docs/management-box.md §OS and install).
# The stock minimal ISO (hybrid BIOS/UEFI) + sshd + the SAME two authorized keys as the installed
# system, so the box is reachable headless from the jail the moment the stick boots — the stick
# gets an SSH-able installer onto a box with no BMC, and nixos-anywhere does the rest from git.
# It takes a DHCP lease (the box's reservation stays for exactly this — default.nix).
{ config, lib, pkgs, ... }:

let
  keyDir = ./keys;
  authorizedKeys =
    let files = builtins.filter (n: lib.hasSuffix ".pub" n)
      (builtins.attrNames (builtins.readDir keyDir));
    in map (n: lib.removeSuffix "\n" (builtins.readFile (keyDir + "/${n}"))) files;
in
{
  networking.hostName = "mgmt-installer";
  services.openssh = {
    enable = true;
    # The stock installer allows root login with an EMPTY password on the console; over the wire
    # only keys, and only ours.
    settings.PermitRootLogin = lib.mkForce "prohibit-password";
    settings.PasswordAuthentication = lib.mkForce false;
  };
  users.users.root.openssh.authorizedKeys.keys = authorizedKeys;
  # `nixos` EXISTS on the minimal ISO too: installation-cd-minimal → installation-cd-base →
  # profiles/installation-device.nix, which declares it `isNormalUser` (nixpkgs 21a67dc, line 37).
  # Verified by `nix eval .#nixosConfigurations.installer.config.users.users.nixos.isNormalUser`
  # = true and by the ISO building (2026-09-13). Keyed here so `ssh nixos@` works as well as root.
  users.users.nixos.openssh.authorizedKeys.keys = authorizedKeys;

  # A stick with no key is a stick nobody can reach: fail the build, like the system config does.
  assertions = [{
    assertion = authorizedKeys != [ ];
    message = "nixos/hosts/mgmt/keys/ holds no TRACKED *.pub — the installer would be unreachable.";
  }];

  # Faster to build, a little larger — this image is written once.
  isoImage.squashfsCompression = "zstd -Xcompression-level 6";
}
