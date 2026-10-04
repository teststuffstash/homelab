# Matchbox content: the talos-worker boot profile + per-MAC group matching.
#
# Bootstrap order note: this provider talks to the Matchbox gRPC API on the LXC
# created above. On a from-scratch apply the LXC/service don't exist yet, so target
# the container + run ansible/matchbox*.yml first, THEN apply these:
#   tofu -chdir=tofu/provisioning apply -target=proxmox_virtual_environment_container.matchbox
#   ANSIBLE_CONFIG=ansible/ansible.cfg devbox run -- ansible-playbook ansible/matchbox.yml ansible/matchbox-talos-assets.yml
#   tofu -chdir=tofu/provisioning apply
# Steady-state (LXC already up) it's just a normal apply.
provider "matchbox" {
  endpoint    = var.matchbox_grpc_endpoint
  client_cert = file(var.matchbox_client_cert)
  client_key  = file(var.matchbox_client_key)
  ca          = file(var.matchbox_ca)
}

# Boots Talos (metal) into MAINTENANCE mode — no talos.config in args, so the node
# comes up in RAM and waits. It does NOT touch the disk until a machine config with
# an install disk is applied (talosctl apply-config), so flagging a box here is safe
# to test the boot path; the actual wipe/install is a separate, deliberate step.
# console=ttyS0 included for headless boxes (e.g. the ThinkCentre has no display).
resource "matchbox_profile" "talos_worker" {
  name   = "talos-worker"
  kernel = "/assets/talos/${var.talos_version}/vmlinuz-amd64"
  initrd = ["/assets/talos/${var.talos_version}/initramfs-amd64.xz"]
  args = [
    "initrd=initramfs-amd64.xz",
    "talos.platform=metal",
    "console=tty0",
    "console=ttyS0",
    "init_on_alloc=1",
    "slab_nomerge",
    "pti=on",
    "consoleblank=0",
    "nvme_core.io_timeout=4294967295",
    "printk.devkmsg=on",
  ]
}

# Per-MAC install flag (ROADMAP "disk-by-default / install-on-match"): only MACs
# with a group here get an install profile. A box NOT listed never matches, so it
# must never be pointed at Matchbox for PXE unless you intend to (re)install it —
# scope the OPNsense chainload per-host accordingly.
#
# NO persistent groups: every metal node is transient-flagged. The one box that used to have a
# persistent group (thinkcentre, onboarded off a USB ISO because its marginal NIC cable made PXE
# time out) lost it when the cable was fixed, 2026-06-11 — a persistent flag on a PXE-first box
# traps it in a maintenance reinstall-loop. ⚠ thinkcentre left the cluster on 2026-09-12 (it is
# the R12 management-box pilot): do NOT flag it here again. Its MAC, like every other host's,
# lives in the one DHCP source of truth, opnsense/dnsmasq-dhcp.py.

# A FLAG IS PROCEDURE STATE, NEVER A COMMIT (FU-244, ADR-132). To onboard a node, write its group
# into tofu/provisioning/flags.local.tf — gitignored (*.local.tf), tofu reads it like any .tf:
#
#   resource "matchbox_group" "<node>" {
#     name     = "<node>"
#     profile  = matchbox_profile.talos_worker.name
#     selector = { mac = "<aa:bb:cc:dd:ee:ff>" }
#   }
#
# flag = write it + `apply -target=matchbox_group.<node>`; unflag = `destroy -target=...` + delete
# the file. While it stands, the box's plan of this root shows it as drift — that is the belt.
# `devbox run machines-lint` fails on a matchbox_group in any TRACKED file here (nx_01_diag sat in
# git for six days, f844711a → #1822, because the live flag existed nowhere else).

