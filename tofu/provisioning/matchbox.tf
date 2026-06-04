# Matchbox content: the talos-worker boot profile + per-MAC group matching.
#
# Bootstrap order note: this provider talks to the Matchbox gRPC API on the LXC
# created above. On a from-scratch apply the LXC/service don't exist yet, so target
# the container + run ansible/matchbox*.yml first, THEN apply these:
#   tofu -chdir=tofu/provisioning apply -target=proxmox_virtual_environment_container.matchbox
#   ansible-playbook -i '192.168.2.30,' ansible/matchbox.yml ansible/matchbox-talos-assets.yml
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
resource "matchbox_group" "thinkcentre_edge" {
  name    = "thinkcentre-edge"
  profile = matchbox_profile.talos_worker.name
  selector = {
    mac = var.thinkcentre_mac
  }
}

# To onboard a new metal node, add a matchbox_group here selecting its MAC (see git
# history for the wk-metal-01 X240 / wk-metal-02 X250 onboardings), apply, PXE it into
# maintenance, then REMOVE the group again post-install so it boots from disk (not a
# reinstall loop). Groups are intentionally transient — only persistent flags stay.
