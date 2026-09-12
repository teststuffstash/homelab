# The management box (R12) — ADR-129. Mechanism, phases and the probe contract:
# docs/management-box.md. Keep this file SMALL: "no workloads, no storage, the fewest reasons to
# break" is the requirement, not a style note.
{ config, lib, pkgs, ... }:

let
  # Public keys are config, not secrets (docs/secrets.md §Minting doctrine: a credential's
  # existence and scope are config; only the private half is data). Drop the operator's and the
  # jail's pubkeys in keys/ — two of them, because rotation is add-new → verify → remove-old.
  keyDir = ./keys;
  authorizedKeys =
    let files = builtins.filter (n: lib.hasSuffix ".pub" n)
      (builtins.attrNames (builtins.readDir keyDir));
    in map (n: lib.removeSuffix "\n" (builtins.readFile (keyDir + "/${n}"))) files;

  repoPath = "/var/lib/homelab";

  # Set at install time — see the boot.loader block. "bios" is the conservative default for the
  # pilot; "uefi" is the better one and buys the automatic boot-failure rollback.
  bootMode = "bios";
in
{
  # ── identity + network ────────────────────────────────────────────────────────────────────────
  networking.hostName = "mgmt";
  networking.useDHCP = false;

  # STATIC, on purpose: the box must be LIVE independently, and a DHCP-reserved address makes its
  # identity depend on the router's dnsmasq being up when it boots (the ghost-node class in
  # docs/runbook.md). Keep the dnsmasq reservation anyway — the installer boots before any config
  # exists and needs a lease. ⚠ interface name is board-specific: verify with `ip link` in the
  # installer and correct before the one install.
  networking.interfaces.enp0s25.ipv4.addresses = [{
    address = "192.168.2.53";
    prefixLength = 24;
  }];
  networking.defaultGateway = "192.168.2.1";
  # Unbound on OPNsense. No second resolver: if the router is down there is no egress to resolve
  # FOR, and the box's job does not need DNS to keep running.
  networking.nameservers = [ "192.168.2.1" ];
  services.timesyncd.servers = [ "192.168.2.1" ];

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };

  # ── boot + rollback ───────────────────────────────────────────────────────────────────────────
  # ⚠ DECIDE THIS AT INSTALL TIME, when the firmware is finally known. The pilot is a ~2011
  # ThinkCentre Edge and its firmware is UNVERIFIED; `bootMode` below is the one-word switch.
  # There is no "safely covers both": GRUB with device = "nodev" installs an EFI binary ONLY, so
  # on a legacy-BIOS box that combination yields an UNBOOTABLE system. The disko layout carries
  # both a BIOS-boot partition and an ESP so either choice works without re-partitioning.
  #
  # Check first (in the installer): `[ -d /sys/firmware/efi ] && echo UEFI || echo legacy-BIOS`.
  #
  # ⚠ AND IT DECIDES THE ROLLBACK STORY: systemd-boot's `bootCounting` — the automatic fallback
  # after N failed boots, the only thing that makes a kernel-class update safe on a headless box
  # with no BMC — is a systemd-boot feature. UEFI ⇒ take it. Legacy BIOS ⇒ GRUB has no equivalent,
  # so a kernel/initrd bump happens while someone can reach the power button until the role moves
  # to the permanent (UEFI, vPro) box. docs/management-box.md §Rollback.
  boot.loader = lib.mkMerge [
    (lib.mkIf (bootMode == "bios") {
      # ⚠ Do NOT set `device` here: disko already registers the disk carrying the EF02
      # BIOS-boot partition (setting both trips "duplicated devices in mirroredBoots" — found by
      # evaluating this config, 2026-09-12). One home for the device: disko.nix.
      grub = {
        enable = true;
        efiSupport = false;
        configurationLimit = 20; # every generation stays bootable — the manual rollback path
      };
    })
    (lib.mkIf (bootMode == "uefi") {
      grub.enable = false;
      systemd-boot = {
        enable = true;
        configurationLimit = 20;
        # ⚠ VERIFY this option exists in the pin before relying on it — if it does not, the
        # never-boots case has no automatic recovery and §Rollback layer 2 stays manual.
        # bootCounting.enable = true;
      };
      efi.canTouchEfiVariables = false;
    })
  ];

  # ── access ────────────────────────────────────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
    # Host keys are declared from the wallet at provision time (docs/management-box.md
    # §Credentials): a reinstall that regenerates them silently breaks the jail's known_hosts.
    hostKeys = [
      { path = "/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
    ];
  };
  users.users.root.openssh.authorizedKeys.keys = authorizedKeys;

  # An empty key list is a brick: no console, no password, no way in. Fail the BUILD instead.
  assertions = [{
    assertion = authorizedKeys != [ ];
    message = ''
      nixos/hosts/mgmt/keys/ holds no *.pub — the box would install with no way to log in.
      Add the operator's key AND the jail's (rotation = add-new → verify → remove-old).
    '';
  }];

  # ── the toolchain is NOT here ─────────────────────────────────────────────────────────────────
  # tofu/talosctl/ansible come from the repo's devbox.lock (the same pin the jail uses), via
  # `devbox run` inside the checkout below. Only what is needed to GET there lives in the closure.
  environment.systemPackages = with pkgs; [
    git
    devbox
    curl
    jq
    openssl
    rsync
  ];
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "root" ];
  };
  programs.git.config.safe.directory = repoPath;

  # ── the pull loop (BUILT, NOT ARMED) ──────────────────────────────────────────────────────────
  # The box pulls a reviewed ref and rebuilds itself; the cluster may poke it but holds no
  # credential into it (ADR-129: a pushed update means something inside the cluster can rewrite the
  # recovery root). `test` first, so a failed activation is recoverable by rebooting into the
  # untouched default; promotion to `boot` happens only after the probe passes.
  #
  # ⚠ Timer is DISABLED until the probe set is trusted (phase A). Arm by flipping `enable`.
  systemd.services.mgmt-pull = {
    description = "pull the reviewed ref and activate it without promoting it";
    path = with pkgs; [ git nix nixos-rebuild systemd coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail
      cd ${repoPath}
      git fetch --quiet origin master
      before="$(git rev-parse HEAD)"
      git reset --hard --quiet origin/master
      after="$(git rev-parse HEAD)"
      [ "$before" = "$after" ] && { echo "no new commits"; exit 0; }
      echo "activating $after (boot default unchanged)"
      nixos-rebuild test --flake ${repoPath}/nixos#mgmt
      systemctl start mgmt-probe.service   # the deadman decides promote-or-roll-back
    '';
  };
  systemd.timers.mgmt-pull = {
    enable = false; # phase A: built, not armed
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      RandomizedDelaySec = "10m";
      Persistent = true;
    };
  };

  # ── the probe + the local deadman ─────────────────────────────────────────────────────────────
  # One mechanism, two jobs: FU-097's drift belt and this box's own health check are the same
  # read-only assertion (docs/management-box.md §Detection). The rollback is LOCAL by requirement —
  # the updater may be the very cluster that is down.
  systemd.services.mgmt-probe = {
    description = "contract probe: toolchain + state + credentials + path, then promote or roll back";
    path = with pkgs; [ bash git devbox nix nixos-rebuild curl jq coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -uo pipefail
      if ${repoPath}/scripts/mgmt-probe.sh; then
        echo "probe PASS — promoting this closure to the boot default"
        nixos-rebuild boot --flake ${repoPath}/nixos#mgmt
      else
        echo "probe FAIL — rolling back and rebooting" >&2
        nixos-rebuild --rollback boot
        systemctl reboot
      fi
    '';
  };
  systemd.timers.mgmt-probe = {
    enable = false; # phase A: built, not armed (the creds it probes are not here yet)
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
      RandomizedDelaySec = "2m";
      Persistent = true;
    };
  };

  # ── the box holds no workloads, no storage, no container runtime ──────────────────────────────
  documentation.enable = false;
  services.xserver.enable = false;
  system.stateVersion = "26.05";
}
