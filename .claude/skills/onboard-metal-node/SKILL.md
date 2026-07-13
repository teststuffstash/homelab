---
name: onboard-metal-node
description: >
  Onboard a bare-metal machine as a Talos Kubernetes worker via Matchbox PXE (or USB). Use when
  the user wants to add a physical box to the cluster, "PXE boot <machine>", "add a worker",
  "wipe and install Talos on <host>", or sees a new MAC trying to PXE boot. Covers flag→reserve→
  maintenance→install→unflag and the laptop taint.
---

# Onboard a bare-metal Talos node

Full reference: `docs/provisioning.md`. Nodes are defined in `tofu/metal.tf` (`metal_nodes`).
The flow is flag → reserve IP → boot to maintenance → read disk → install → **unflag**.

## Steps

1. **Flag the MAC** in `tofu/provisioning/matchbox.tf` (a `matchbox_group` → `talos-worker`
   profile), then apply it:
   ```bash
   source scripts/keepass-env.sh   # exports TF_VAR_proxmox_api_token (wallet: pve-api-token-matchbox)
   export NIX_CONFIG="experimental-features = nix-command flakes"
   devbox run -- tofu -chdir=tofu/provisioning apply -target=matchbox_group.<x>
   ```
   Confirm: `devbox run -- curl -s "http://192.168.2.30:8080/ipxe?mac=<aa-bb-..>"` → HTTP 200.

2. **Reserve its IP** in `opnsense/dnsmasq-dhcp.py` (`hwaddr → ip`, maintenance IP == node IP),
   then run `opnsense/dnsmasq-dhcp.py` with `OPN_API_KEY`/`OPN_API_SECRET` from the wallet
   (entries `opnsense-api-{key,secret}` — FU-001; see how `scripts/opnsense-playbook.sh` reads them).

3. **PXE-boot it** (or `devbox run talos-usb` for a USB ISO if PXE firmware is flaky). It comes up
   in Talos maintenance at the reserved IP.

4. **Read the disk** and set `install_disk` in `metal.tf` (pick the real SSD, not loop/USB/Optane):
   ```bash
   devbox run -- talosctl -n <ip> get disks --insecure
   ```

5. **Install** (needs the two TF_VAR secrets — see tofu-apply skill):
   ```bash
   devbox run -- tofu -chdir=tofu apply -target='talos_machine_configuration_apply.metal["<name>"]'
   ```

6. ⚠️ **Unflag** so the post-install reboot boots from disk (not a reinstall loop):
   ```bash
   devbox run -- tofu -chdir=tofu/provisioning destroy -target=matchbox_group.<x>
   ```
   Remove the group from `matchbox.tf` too (committed file holds no per-node groups).

7. **Taint** laptop/compute-tier nodes ephemeral — but only AFTER the node is Ready (transient
   cilium/not-ready taints cause a `kube-controller-manager` field conflict otherwise):
   ```bash
   devbox run -- kubectl --kubeconfig tofu/kubeconfig wait --for=condition=Ready node/<name>
   devbox run -- tofu -chdir=tofu apply -target=kubernetes_node_taint.<x>
   ```

## Verify

`devbox run nodes` — the new node should be `Ready` on Talos v1.13.2.
