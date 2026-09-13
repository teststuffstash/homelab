# The management box (R12) — ADR-129, mechanism in docs/management-box.md.
#
# Deliberately a SUBDIRECTORY flake: the repo root belongs to devbox (devbox.json/devbox.lock),
# which is the TOOLCHAIN pin for both the jail and this box. This flake pins only the SYSTEM
# CLOSURE (kernel, glibc, systemd, sshd). Two pins, two revert paths, one git.
#
# Install (once, from a USB stick — the stick carries only an SSH-able installer). `--extra-files`
# is not optional: sshd GENERATES a host key when none is present, and a reinstall that regenerates
# it silently breaks the jail's known_hosts. The tree it ships (host key + the belt's env file +
# talosconfig/kubeconfig) is staged from the wallet by ONE script — no secret is ever in this flake:
#   scripts/mgmt-provision-secrets.sh          # stages ~/.claude/homelab-mgmt/extra-files, prints:
#   nix run nixpkgs#nixos-anywhere -- --extra-files <that dir> --flake ./nixos#mgmt root@<installer-ip>
# Rotation later = `scripts/mgmt-provision-secrets.sh --push` (same tree, onto the running box).
# Update — the box does this itself from the operator-advanced `mgmt-release` ref
# (mgmt-pull.service → mgmt-confirm.service). By hand, the same two steps in the same order:
#   nixos-rebuild --flake /var/lib/homelab/nixos#mgmt test   # live now, boot default UNCHANGED
#   nixos-rebuild --flake /var/lib/homelab/nixos#mgmt boot    # promote, then reboot
{
  description = "homelab management box (R12) — the out-of-band applier";

  inputs = {
    # Release branch, not unstable: this box's job is to be boring.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, disko, ... }: {
    nixosConfigurations.mgmt = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        ./hosts/mgmt/disko.nix
        ./hosts/mgmt/default.nix
      ];
    };
  };
}
