# Provisioning — Matchbox PXE + bare-metal Talos onboarding

How bare-metal nodes join the cluster. The PXE pipeline is built and verified; onboarding a new
node is a repeatable recipe. See `docs/runbook.md` for general ops.

## The PXE pipeline

- **Matchbox** runs as a Proxmox **unprivileged LXC** (CTID 210, `192.168.2.30`), deliberately
  out-of-cluster (always-on, survives a cluster `tofu destroy`). Built by `tofu/provisioning/`
  (LXC) + `ansible/matchbox*.yml` (install + TLS). Serves HTTP `:8080` (read API + `/assets`) and
  gRPC `:8081` (for the `poseidon/matchbox` tofu provider).
- **Boot lives on the LXC, not OPNsense** — a dnsmasq **proxy-DHCP + TFTP** on the LXC
  (`ansible/matchbox-proxydhcp.yml`); OPNsense's dnsmasq plugin won't emit the bootfile.
- **Disk-by-default, install-on-match.** Chain: PXE ROM → iPXE binary (`undionly.kpxe` BIOS /
  `ipxe.efi` UEFI) → `http://192.168.2.30:8080/assets/boot-or-disk.ipxe` → Matchbox `/ipxe`. A MAC
  with a **`matchbox_group`** matches the `talos-worker` profile → boots Talos **maintenance mode**
  (RAM only, disk untouched). An unflagged MAC → 404 → boots local disk.
- The `talos-worker` profile boots Talos maintenance with NO `talos.config` — safe to flag a MAC
  for testing; the actual wipe/install is a separate, deliberate `tofu apply`.

Check what Matchbox will do for a MAC (from the jail):
```bash
devbox run -- curl -s "http://192.168.2.30:8080/ipxe?mac=<aa-bb-cc-dd-ee-ff>"   # 200=flagged→maint, 404=disk
```
Tail PXE attempts: `ssh -i ~/.claude/homelab-pve-ssh/id_ed25519 root@192.168.2.30
"journalctl -u dnsmasq --since '1 hour ago' | grep -i <mac-prefix>"` (`log-dhcp` is on).

## Onboarding recipe (reuse for each new metal node)

Bare-metal nodes are declared in **[`machines/machines.yaml`](../machines/machines.yaml)** — the one
inventory — as an entry flagged `talos_metal_node: true` with an `install_disk` (plus the optional
`longhorn_disks` / `pin_hostname` / `kata` / `avx2` / `ephemeral` flags; field semantics in that file's
header). `tofu/locals.tf` reduces those entries to `local.metal_nodes`, which `tofu/metal.tf`
consumes — there is deliberately no `var.metal_nodes` map any more, so a node fact is edited in
exactly one place. After **any** edit to the YAML, regenerate the doc tables:
`devbox run -- python3 machines/generate.py` (re-running must produce an empty diff). Steps:

1. **Flag the MAC** — add a `matchbox_group` selecting the MAC to the `talos-worker` profile in
   `tofu/provisioning/matchbox.tf`, then
   `devbox run -- tofu -chdir=tofu/provisioning apply -target=matchbox_group.<x>`
   (`source scripts/keepass-env.sh` exports `TF_VAR_proxmox_api_token`).
2. **Reserve its IP** in `opnsense/dnsmasq-dhcp.py` (`hwaddr → ip`, maintenance IP == node IP) and
   apply (`python3 opnsense/dnsmasq-dhcp.py` with the OPN creds). Run `dig`/the matchbox curl above
   to confirm 200.
3. **PXE-boot it into maintenance** (or USB ISO if PXE firmware is flaky — see below). It comes up
   at the reserved IP.
4. **Read its install disk:** `devbox run -- talosctl -n <ip> get disks --insecure` → pick the real
   SSD (not loop devices / USB stick / Optane). Add the node to `machines/machines.yaml` (or fill in
   the existing entry) with `talos_metal_node: true` + that `install_disk`, then
   `devbox run -- python3 machines/generate.py` and commit the regenerated tables.
5. **Install:** `devbox run -- tofu -chdir=tofu apply -target='talos_machine_configuration_apply.metal["<name>"]'`.
   Talos wipes the disk, installs, reboots.
6. ⚠️ **Remove the Matchbox flag** before/at the post-install reboot
   (`tofu -chdir=tofu/provisioning destroy -target=matchbox_group.<x>`) so the reboot boots from
   disk and doesn't loop back into maintenance/reinstall. The committed `matchbox.tf` holds **no
   per-node group** on purpose — flags are transient.
7. **Taint laptop/compute-tier nodes** ephemeral so Longhorn/stateful workloads don't schedule
   there — set `ephemeral: true` on its YAML entry (`local.ephemeral_nodes` →
   `kubernetes_node_taint.ephemeral["<name>"]`, `homelab.io/ephemeral`). Apply this **after** the
   node is Ready — while it still carries transient not-ready/cilium taints, `kube-controller-manager` owns
   `.spec.taints` and the apply conflicts (`kubectl wait --for=condition=Ready node/<name>` first).
8. **Peer it with OPNsense BGP** — add the node IP to `bgp_node_ips` in
   `ansible/group_vars/opnsense.yml` and run
   `bash scripts/opnsense-playbook.sh ansible/opnsense-bgp.yml`. Cilium's BGP nodeSelector is
   all-nodes, but OPNsense/FRR only accepts explicit neighbors — a node missing from that list
   sits BGP `idle` forever and advertises no VIPs (the `state != established` Prometheus alert).
   ⚠ **This step applies to EVERY new node, VM workers included** — it is not PXE/metal-specific.
   Missed twice now: the metal nodes at their 2026-06-11 onboarding, then the wk-03 VM at its
   2026-08-18 capacity-day onboarding (caught by the alert the same day).

## Known-good examples (entries in `machines/machines.yaml`)

- `wk-metal-01` — ThinkPad X240, .182, `/dev/sda` (500GB MX500), ephemeral tier, BIOS/legacy PXE.
  ⚠ kata node AND a **Longhorn BULK zone** (ADR-089) — a wipe destroys bulk replicas; drain first.
- `wk-metal-02` — ThinkPad X250, .183, `/dev/sda` (128GB SanDisk), ephemeral tier, legacy PXE; kata node.
- `wk-metal-03` — laptop i5-6200U, .184, `/dev/sda`, ephemeral tier, **kata node** (`kata: true`
  → the `metal_kata` install image + `homelab.io/kata` label).
- `wk-metal-04` — desktop i5-3570K/16GB, .186, `/dev/sda`, ephemeral tier, **kata node**. The roomy
  one; deliberately left without `avx2: true`, so it is out of `local.avx2_nodes` (Ivy Bridge has no
  AVX2, so goose rides schedule here but opencode SIGILLs) — see the comment on its
  `machines/machines.yaml` entry, and `local.avx2_nodes` in `tofu/locals.tf`.
- `hp-01` — .54, `/dev/sda`, Longhorn, WoL-capable.
- `thinkcentre` — .53, `/dev/sdb` (120GB Kingston), Longhorn + 2×Optane fast tier. Originally
  onboarded via **USB ISO** (`devbox run talos-usb`) when PXE appeared broken — the culprit was a
  **bad NIC cable** (100Mbps + link flapping), replaced 2026-06-11; it PXE-onboards fine now.

## Upgrading a metal node's Talos

Metal nodes (unlike nocloud VMs) upgrade in place with the factory installer image that carries the
extensions:
```bash
devbox run -- talosctl --talosconfig tofu/talosconfig -n <ip> -e 192.168.2.51 \
  upgrade --image <factory installer URL — see below>
```
The URL is what `tofu/metal.tf` would install: `local.talos_install_image` (defined at the top of
`tofu/metal.tf` as `data.talos_image_factory_urls.metal.urls.installer`, whose schematic lives in
`tofu/image.tf`). A node flagged `kata: true` in `machines/machines.yaml` gets the **`metal_kata`**
installer instead (`data.talos_image_factory_urls.metal_kata`) — pass that one, or the upgrade
quietly swaps the node back to the plain-metal schematic.

Point `-e` at a control-plane node (`.51`), not the worker itself — otherwise the post-install drain
step can't fetch kubeconfig and errors (the install still succeeds, but the node may not reboot;
a manual `talosctl reboot` then boots the staged version).

## Firmware reality (why USB sometimes)

Smart-plug power alone isn't enough — some boxes need a display/console for a one-time BIOS change
(enable Network Stack / PXE OpROM, Secure Boot off, NIC first). The ThinkCentre needed exactly that
one-time visit (and its "PXE never works" turned out to be a bad cable, not firmware — USB ISO
remains the fallback for genuinely PXE-less boxes). This is the argument for vPro/AMT boxes.
