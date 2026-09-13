# The management box (R12) — ADR-129. Mechanism, phases and the probe contract:
# docs/management-box.md. Keep this file SMALL: "no workloads, no storage, the fewest reasons to
# break" is the requirement, not a style note.
#
# The shape of the update loop below is the product of a review (2026-09-12) that found the first
# draft would have rebooted the box every 15 minutes forever. Two rules came out of it and they
# are load-bearing:
#   1. The DRIFT BELT and the DEADMAN are different units with different triggers. A fleet fault
#      (Garage unreachable, a node down, real drift) must never reboot this box — that is the
#      inverse of why it exists.
#   2. `nixos-rebuild test` does not touch the boot default, so the undo for a bad activation is a
#      plain REBOOT. Never `--rollback`: it demotes the generation BEFORE the good one.
{ config, lib, pkgs, ... }:

let
  # Public keys are config, not secrets (docs/secrets.md §Minting doctrine: a credential's
  # existence and scope are config; only the private half is data). Drop the operator's and the
  # jail's pubkeys in keys/ — two of them, because rotation is add-new → verify → remove-old.
  # ⚠ `git add` them: a flake sees only TRACKED files, so an untracked key is invisible here.
  keyDir = ./keys;
  authorizedKeys =
    let files = builtins.filter (n: lib.hasSuffix ".pub" n)
      (builtins.attrNames (builtins.readDir keyDir));
    in map (n: lib.removeSuffix "\n" (builtins.readFile (keyDir + "/${n}"))) files;

  repoPath = "/var/lib/homelab";
  repoUrl = "https://github.com/teststuffstash/homelab.git";

  # The ref the box follows. ⚠ NOT master: this repo auto-merges bot-approved PRs, and `/nixos/`
  # would otherwise let a merged PR rewrite the recovery root's kernel, bootloader or sshd within
  # the hour — against ADR-129's "a reviewed ref" and the spike's listing of this box as a trust
  # anchor. The operator advances this branch deliberately; if it does not exist, mgmt-pull
  # no-ops loudly rather than falling back. CODEOWNERS also gained a `/nixos/` row.
  mgmtRef = "mgmt-release";

  # Written after a successful `nixos-rebuild test`, read to decide whether a promotion is even
  # allowed. Without it, a crash between `git reset` and `test` silently stops updates forever,
  # and the belt could promote a closure nothing ever activated.
  activatedStamp = "/var/lib/mgmt/activated-rev";

  # Set at install time — see the boot.loader block. "bios" is the conservative default for the
  # pilot; "uefi" is the better one on hardware that supports it.
  # "bios" ON EVIDENCE, not for lack of UEFI (2026-09-13): the installer booted UEFI and a UEFI
  # install DID land (a "Linux Boot Manager" entry was written). But this is a CSM firmware whose
  # BIOS-setup boot priority (operator-set: USB, disk, PXE) is authoritative — it re-derives the
  # NVRAM BootOrder from that list on every boot, legacy device entries first, so `efibootmgr -o`
  # was overwritten and the UEFI entry sat behind the legacy "Hard Drive" one. GRUB in the
  # BIOS-boot partition IS what that legacy entry boots, and it needs no NVRAM at all. Nothing is
  # lost: boot counting does not exist in this pin either way (docs/management-box.md §Rollback).
  bootMode = "bios";
in
{
  # ── identity + network ────────────────────────────────────────────────────────────────────────
  networking.hostName = "mgmt";
  networking.useDHCP = false;
  networking.useNetworkd = true;

  # Matched by MAC, not by interface name: a guessed `enpXsY` (or a rename after a kernel bump) is
  # a box that is simply gone, with no console to fix it. The MAC is already the one DHCP source
  # of truth — opnsense/dnsmasq-dhcp.py.
  systemd.network.networks."10-lan" = {
    matchConfig.MACAddress = "8c:89:a5:23:49:da";
    address = [ "192.168.2.53/24" ];
    # STATIC on purpose: a DHCP-reserved address makes the box's identity depend on the router's
    # dnsmasq being up when it boots (the ghost-node class in docs/runbook.md). The reservation
    # STAYS anyway — the installer boots before any config exists and needs a lease.
    gateway = [ "192.168.2.1" ];
    # Unbound on OPNsense. No second resolver: if the router is down there is no egress to resolve
    # FOR, and the box's own job does not need DNS to keep running.
    dns = [ "192.168.2.1" ];
  };
  services.timesyncd.servers = [ "192.168.2.1" ];

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };

  # ── boot + rollback ───────────────────────────────────────────────────────────────────────────
  # ⚠ DECIDE `bootMode` AT INSTALL TIME, when the firmware is finally known. The pilot is a ~2011
  # ThinkCentre Edge and its firmware is UNVERIFIED. There is no "safely covers both": GRUB with
  # device = "nodev" installs an EFI binary ONLY, so on a legacy-BIOS box that combination yields
  # an UNBOOTABLE system. The disko layout carries both a BIOS-boot partition and an ESP so either
  # choice works without re-partitioning.
  #
  # Check first (in the installer): `[ -d /sys/firmware/efi ] && echo UEFI || echo legacy-BIOS`.
  #
  # ⚠ AUTOMATIC boot-failure rollback is NOT available on either branch. systemd-boot's boot
  # counting is the mechanism that would provide it, and `boot.loader.systemd-boot.bootCounting`
  # DOES NOT EXIST in this pin (nixos-26.05, rev 21a67dc — grepped, 2026-09-12). So a kernel or
  # initrd that activates cleanly and then fails to boot needs hands on this box, in both modes.
  # docs/management-box.md §Rollback layer 2 says the same. That is the pilot's accepted limit.
  boot.loader = lib.mkMerge [
    (lib.mkIf (bootMode == "bios") {
      # ⚠ Do NOT set `device` here: disko already registers the disk carrying the EF02 BIOS-boot
      # partition, and setting both trips "duplicated devices in mirroredBoots" (found by
      # evaluating this config, 2026-09-12). One home for the device: disko.nix.
      grub = {
        enable = true;
        efiSupport = false;
        # Keep the generation list short enough to fit the ESP — see disko.nix's sizing note.
        configurationLimit = 10;
      };
    })
    (lib.mkIf (bootMode == "uefi") {
      grub.enable = false;
      systemd-boot = {
        enable = true;
        configurationLimit = 10;
      };
      # TRUE on purpose, and it is a real choice: with `false` (bootctl --no-variables) no NVRAM
      # entry is written and booting depends on this 2011 firmware trying the removable fallback
      # path. On a headless box with no BMC that is a coin flip you cannot recover remotely. Flip
      # it only if the firmware is known to mangle NVRAM entries — decide with the stick in hand.
      efi.canTouchEfiVariables = true;
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
    # ⚠ This does NOT import a host key — sshd GENERATES one at this path when it is missing. To
    # keep the jail's known_hosts stable across a reinstall, the wallet's key must be placed by
    # the installer: `nixos-anywhere --extra-files <dir>` with the key at
    # etc/ssh/ssh_host_ed25519_key (mode 600). See flake.nix's install command.
    hostKeys = [
      { path = "/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
    ];
  };
  users.users.root.openssh.authorizedKeys.keys = authorizedKeys;

  # An empty key list is a brick: no console, no password, no way in. Fail the BUILD instead.
  assertions = [{
    assertion = authorizedKeys != [ ];
    message = ''
      nixos/hosts/mgmt/keys/ holds no TRACKED *.pub — the box would install with no way to log in.
      Add the operator's key AND the jail's (rotation = add-new → verify → remove-old), and
      `git add` them: a flake cannot see untracked files.
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

  # A 120 GB disk and an hourly build loop: without GC the store fills, and a full root means nix
  # cannot build — which breaks the repair path itself, not just the next update.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 60d";
  };
  nix.settings.min-free = 5 * 1024 * 1024 * 1024;
  nix.settings.max-free = 20 * 1024 * 1024 * 1024;

  systemd.tmpfiles.rules = [ "d /var/lib/mgmt 0700 root root -" ];

  # ── the checkout the whole loop depends on ────────────────────────────────────────────────────
  systemd.services.mgmt-checkout = {
    description = "ensure ${repoPath} is a checkout of the expected remote";
    path = with pkgs; [ git coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "10m";
      Environment = [ "HOME=/root" ];
    };
    script = ''
      set -euo pipefail
      if [ ! -d ${repoPath}/.git ]; then
        git clone --origin origin ${repoUrl} ${repoPath}
        exit 0
      fi
      # A hand-cloned repo with the wrong remote would let the loop reset to the wrong tree.
      have="$(git -C ${repoPath} remote get-url origin)"
      [ "$have" = "${repoUrl}" ] || { echo "origin is '$have', expected ${repoUrl}" >&2; exit 1; }
    '';
  };

  # ── the pull loop (BUILT, NOT ARMED) ──────────────────────────────────────────────────────────
  # Fetch the operator-advanced ref, ACTIVATE it without promoting it (`test` leaves the boot
  # default alone), then hand the verdict to the deadman. ⚠ Timer disabled until phase A is done.
  systemd.services.mgmt-pull = {
    description = "activate the reviewed ref without promoting it";
    after = [ "mgmt-checkout.service" "network-online.target" ];
    wants = [ "mgmt-checkout.service" "network-online.target" ];
    path = with pkgs; [ git nix nixos-rebuild systemd coreutils ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "45m"; # Type=oneshot has NO default timeout; an unreachable cache would hang forever
      Environment = [ "HOME=/root" ];
    };
    script = ''
      set -euo pipefail
      cd ${repoPath}
      if ! git fetch --quiet origin ${mgmtRef}; then
        echo "ref '${mgmtRef}' does not exist on origin — nothing to do (the operator advances it)" >&2
        exit 0
      fi
      target="$(git rev-parse FETCH_HEAD)"
      # Compare against what was actually ACTIVATED, not against pre-fetch HEAD: a crash between
      # the reset and the activation would otherwise look like "no new commits" forever.
      activated=""
      [ -f ${activatedStamp} ] && activated="$(cat ${activatedStamp})"
      if [ "$target" = "$activated" ]; then
        echo "already activated $target"
        exit 0
      fi
      git reset --hard --quiet "$target"
      echo "activating $target (boot default unchanged)"
      nixos-rebuild test --flake ${repoPath}/nixos#mgmt
      printf '%s' "$target" > ${activatedStamp}
      # --no-block: this oneshot must not wait on a unit that may reboot the machine.
      systemctl start --no-block mgmt-confirm.service
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

  # ── the DEADMAN: box-local only, and its only action is a reboot ──────────────────────────────
  # Started by mgmt-pull, never by a timer. The gate checks only properties whose loss cannot be
  # recovered without carrying a stick to the box (sshd + keys + network + systemd + store), and
  # none of them may skip. On failure: reboot, which lands on the untouched boot default, because
  # `test` never promoted anything. NO `--rollback` — that would demote the generation before the
  # good one, and on a first update it exits non-zero and (under systemd's `set -e` script
  # wrapper) would skip the reboot entirely, leaving a broken closure live with no console.
  systemd.services.mgmt-confirm = {
    description = "post-activation gate: promote the closure, or reboot back to the boot default";
    path = with pkgs; [ bash iproute2 iputils openssh systemd nix nixos-rebuild coreutils ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "15m";
      Environment = [ "HOME=/root" "MODE=gate" ];
    };
    script = ''
      set -uo pipefail
      if ${repoPath}/scripts/mgmt-probe.sh; then
        echo "gate PASS — promoting this closure to the boot default"
        nixos-rebuild boot --flake ${repoPath}/nixos#mgmt
      else
        echo "gate FAIL — rebooting into the untouched boot default" >&2
        rm -f ${activatedStamp}   # so the next pull re-activates and re-gates rather than skipping
        systemctl --no-block reboot
      fi
    '';
  };

  # ── the DRIFT BELT: reports, never acts ───────────────────────────────────────────────────────
  # FU-097's belt and this box's fleet-facing health check, on a timer. A failure here means
  # something OUT THERE is wrong (or genuinely drifted); it changes no generation and reboots
  # nothing. ⚠ Publishing is unbuilt — Pushgateway is cluster-internal and never BGP-advertised,
  # so PUSHGATEWAY stays unset until that exposure is decided (docs/management-box.md §D1).
  systemd.services.mgmt-belt = {
    description = "drift belt: tofu plan + talosctl skew + opnsense --check (report only)";
    after = [ "mgmt-checkout.service" ];
    wants = [ "mgmt-checkout.service" ];
    path = with pkgs; [ bash git devbox nix curl jq coreutils ];
    serviceConfig = {
      Type = "oneshot";
      TimeoutStartSec = "30m";
      Environment = [ "HOME=/root" "MODE=belt" ];
      # The credentials. NOT in this closure (public repo, world-readable store): a root-only file
      # placed by scripts/mgmt-provision-secrets.sh (--extra-files at install, --push to rotate),
      # read at each start so a rotation needs no restart. The leading "-" means a missing file
      # does not fail the unit — the probe then SKIPS loudly, which is the "not provisioned yet"
      # signal, not a fault. The same line goes on the apply unit when phase B adds one.
      EnvironmentFile = [ "-/var/lib/mgmt/env" ];
    };
    script = "${repoPath}/scripts/mgmt-probe.sh";
  };
  systemd.timers.mgmt-belt = {
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
