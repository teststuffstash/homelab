---
name: onboard-metal-node
description: >
  Onboard a bare-metal machine as a Talos Kubernetes worker via Matchbox PXE (or USB). Use when
  the user wants to add a physical box to the cluster, "PXE boot <machine>", "add a worker",
  "wipe and install Talos on <host>", or sees a new MAC trying to PXE boot. Covers flag→reserve→
  maintenance→install→unflag, the post-install registrations Ready does not gate, and the doc rows.
---

# Onboard a bare-metal Talos node

> **Glance first**: [`../GAPS.md`](../GAPS.md) §onboard-metal-node — unpromoted sightings
> apply until closed (contract: [`../README.md`](../README.md)).

Full reference: `docs/provisioning.md`. Nodes are declared in `machines/machines.yaml`
(`talos_metal_node: true` + `install_disk`); `tofu/locals.tf` derives `local.metal_nodes` from it
and `tofu/metal.tf` consumes that — there is no `var.metal_nodes` map any more.
The flow is flag → reserve IP → boot to maintenance → read disk → install → **unflag** →
the post-install registrations below (taint, **zone label**, BGP) → the per-node doc rows.

## Steps

1. **Flag the MAC** in `tofu/provisioning/matchbox.tf` (a `matchbox_group` → `talos-worker`
   profile), then apply it:
   ```bash
   export NIX_CONFIG="experimental-features = nix-command flakes"
   export KP_DIR="$HOME/.claude/homelab-keepass"
   . scripts/keepass-env.sh                                    # TF_VAR_proxmox_api_token
   TOFU_STATE_ROOT_DIR="$PWD/tofu/provisioning" . scripts/tofu-state-env.sh   # S3 backend + TF_ENCRYPTION
   devbox run -- tofu -chdir=tofu/provisioning apply -target=matchbox_group.<x>
   ```
   ⚠ `keepass-env.sh` alone is NOT enough any more: `tofu/provisioning` moved to the encrypted
   Garage S3 backend on 2026-08-04 (`docs/tofu-state.md`), so without `tofu-state-env.sh` every
   command in that root dies with *"No valid credential sources found"*. There is no `tf.sh`
   wrapper for this root — only for `tofu/`. (Stale-doc hit, 2026-09-07.)
   Confirm: `devbox run -- curl -s "http://192.168.2.30:8080/ipxe?mac=<aa-bb-..>"` → HTTP 200.

2. **Reserve its IP** in `opnsense/dnsmasq-dhcp.py` (`hwaddr → ip`, maintenance IP == node IP),
   then run `opnsense/dnsmasq-dhcp.py` with `OPN_API_KEY`/`OPN_API_SECRET` from the wallet
   (entries `opnsense-api-{key,secret}` — FU-001; see how `scripts/opnsense-playbook.sh` reads them).

3. **PXE-boot it** (or `devbox run talos-usb` for a USB ISO if PXE firmware is flaky). It comes up
   in Talos maintenance at the reserved IP.

4. **Read the disk** and set `install_disk` on the node's `machines/machines.yaml` entry (pick the
   real SSD, not loop/USB/Optane), then regenerate the doc tables:
   ```bash
   devbox run -- talosctl -n <ip> get disks --insecure
   devbox run -- python3 machines/generate.py    # after ANY machines.yaml edit; commit the diff
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

## Post-install registrations — the steps `Ready` does not gate

⚠ **Read this whole section before declaring the node done.** Every miss in this repo's onboarding
history is in here, and they share one signature: **the node reports `Ready` whether or not you do
them**, so nothing fails and nothing alerts until much later. Two so far — the BGP neighbour
(wk-metal-04, 2026-07-28) and the zone label (m70s, 2026-09-07). Treat the list as a checklist, not
as prose, and add to it every time a round finds a new one.

7. **Taint** laptop/compute-tier nodes ephemeral — set `ephemeral: true` on the YAML entry
   (`local.ephemeral_nodes`), but apply only AFTER the node is Ready (transient cilium/not-ready
   taints cause a `kube-controller-manager` field conflict otherwise):
   ```bash
   devbox run -- kubectl --kubeconfig tofu/kubeconfig wait --for=condition=Ready node/<name>
   devbox run -- tofu -chdir=tofu apply -target='kubernetes_node_taint.ephemeral["<name>"]'
   ```

7b. **Apply the zone label.** `zone:` in `machines.yaml` is NOT carried by the machine config —
   it is a separate tofu resource, so step 5 leaves the node **unlabelled**:
   ```bash
   devbox run tf-apply '-target=kubernetes_labels.node_zone["<name>"]'   # plain node, no Longhorn disk
   devbox run -- kubectl --kubeconfig tofu/kubeconfig get node <name> \
     -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}{"\n"}'   # must print <zone>
   ```
   Pick the right resource for the node's storage role (all in `tofu/longhorn.tf`):
   `kubernetes_labels.longhorn_storage` (create-default-disk storage node) ·
   `kubernetes_labels.longhorn_bulk_zone` (bulk-tier, tagged disks only) ·
   `kubernetes_labels.node_zone` (everything else — the `for_each` explicitly excludes the first two).
   **Why it matters:** ADR-114's whole point is one Longhorn/Garage replica per PHYSICAL failure
   domain. An unlabelled node does not fail — the zone-spread rules just cannot tell it apart, which
   is how replicas quietly land in one domain. Missed on m70s, 2026-09-07, on the very box bought to
   BE a third zone.

8. **Add the node as a BGP neighbor in OPNsense** — Cilium's BGP nodeSelector is all-nodes, so a
   node not listed in FRR sits `active`/`idle` (never peers, never advertises VIPs) →
   `CiliumBGPNodeSessionDown`. Add its IP to `bgp_node_ips` in `ansible/group_vars/opnsense.yml`,
   then apply and verify the session goes `established`:
   ```bash
   bash scripts/opnsense-playbook.sh ansible/opnsense-bgp.yml
   devbox run -- kubectl --kubeconfig tofu/kubeconfig exec -n kube-system \
     "$(devbox run -- kubectl --kubeconfig tofu/kubeconfig get pods -n kube-system -l k8s-app=cilium \
        -o jsonpath='{range .items[?(@.spec.nodeName=="<name>")]}{.metadata.name}{end}')" \
     -c cilium-agent -- cilium bgp peers    # session must be `established`
   ```
   (Missed for wk-metal-04 on 2026-07-28; the same class recurred from 2026-06-11 — it's easy to
   forget because k8s reports the node `Ready` regardless.)

9. **Register it in the docs that carry a per-node row.** None of these are generated, so none of
   them fail when you skip them — grep the most recently onboarded node's name to find any that
   have appeared since this list was written, and add the new one to that list too:

   | File | What it carries |
   |---|---|
   | `docs/provisioning.md` §Known-good examples | one line per node: IP, install disk, tier, quirks |
   | `tofu/README.md` | the node roll-call in the status banner |
   | `docs/runbook.md` §WoL recovery | the physical NIC MAC (recovery needs it, and only DHCP has it otherwise) |
   | `docs/network-physical.md` | which switch port it hangs off (⚠ needs the operator at the cabling) |
   | `docs/power-measurements.md` | its plug + idle/load draw, or an explicit "not measured" |
   | `docs/storage-ledger.md` | only once it carries a Longhorn disk — a diskless node has no tier row |

   `CLAUDE.md` / `README.md` / `machines/README.md` / `machines.html` are **generated** — never hand-edit;
   `devbox run -- python3 machines/generate.py` and commit the diff.

10. **Read the install disk's health while you are here** — model, `percentage_used`, link width.
   Recipe: `docs/runbook.md` §Reading a fleet disk's identity and health. Do it at onboarding, not
   when the disk is already suspect: the buying criterion for any Garage/Longhorn data disk is
   DRAM cache + measured latency, and that starts from knowing what is fitted.

## Verify

`devbox run nodes` — the new node should be `Ready` on Talos v1.13.2, its zone label set (7b), and
its `cilium bgp peers` session `established` (step 8).
