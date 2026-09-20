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
6b. **Apply the zone label** — `zone:` in `machines.yaml` is NOT part of the machine config; it is a
   separate tofu resource in `tofu/longhorn.tf`, so the install leaves the node unlabelled:
   `devbox run tf-apply '-target=kubernetes_labels.node_zone["<name>"]'` (or `longhorn_storage` /
   `longhorn_bulk_zone` when the node carries Longhorn disks — the `node_zone` `for_each` excludes
   those two sets). Then read the label back off the node.
   ⚠ Nothing fails without it. The node goes `Ready` either way, and ADR-114's zone-spread simply
   cannot distinguish an unlabelled node — which is how replicas quietly land in one failure
   domain. Missed on m70s (2026-09-07), the box bought to BE a third zone.
7. **Taint laptop/compute-tier nodes** ephemeral so Longhorn/stateful workloads don't schedule
   there — set `ephemeral: true` on its YAML entry (`local.ephemeral_nodes` →
   `kubernetes_node_taint.ephemeral["<name>"]`, `homelab.io/ephemeral`). Apply this **after** the
   node is Ready — while it still carries transient not-ready/cilium taints, `kube-controller-manager` owns
   `.spec.taints` and the apply conflicts (`kubectl wait --for=condition=Ready node/<name>` first).
   ⚠ Ready is not always enough: `cilium-operator-generic` keeps ownership of `.spec.taints` on a
   node whose agent-not-ready taint it stripped (nx-01, 2026-09-16 — Ready for 18 h, still
   `Field manager conflict`). **Never answer that with `force = true`**: taints are an atomic list
   and a forced apply makes tofu the owner of the whole list (the next apply drops the cordon and
   cilium's taints). Separately — and independent of force — the taint resource and
   `kubernetes_labels` used to share the default `Terraform` field manager, so **every re-apply of
   the taint stripped `topology.kubernetes.io/zone` off the node** (all six ephemeral nodes on
   2026-09-16, then wk-03 again on a non-forced re-test); the taint resource now carries its own
   `field_manager`. Re-read zone labels after any taint apply. The durable home for the taint is
   the Talos machine config — FU-235.
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
- `wk-metal-02` — ThinkPad X250, .183, `/dev/sda` (128GB SanDisk), legacy PXE; kata node.
  **CONTROL PLANE since 2026-09-20** (ADR-133; left the ride pool in #1814, merged 9b978367 —
  the prerequisite §CP5 step 1 names): reinstalled rather than
  flipped, because `machine_type` is baked at install — recipe in
  [`controlplane-ha.md`](controlplane-ha.md) §CP5. etcd sync-write ~1.6 ms (etcd's dd probe).
- `wk-metal-03` — laptop i5-6200U, .184, `/dev/sda`, ephemeral tier, **kata node** (`kata: true`
  → the `metal_kata` install image + `homelab.io/kata` label).
- `wk-metal-04` — desktop i5-3570K/16GB, .186, `/dev/sda`, ephemeral tier, **kata node**. The roomy
  one; deliberately left without `avx2: true`, so it is out of `local.avx2_nodes` (Ivy Bridge has no
  AVX2, so goose rides schedule here but opencode SIGILLs) — see the comment on its
  `machines/machines.yaml` entry, and `local.avx2_nodes` in `tofu/locals.tf`.
- `hp-01` — .54, `/dev/sda`, Longhorn, WoL-capable.
- `m70s` — Lenovo ThinkCentre M70s SFF, .56, **`/dev/disk/by-id/nvme-Micron_MTFDHBA512TDV_21052D0C4364`**
  — ⚠ by-id since 2026-09-12: the OEM Micron enumerates as `nvme1n1` now that the Garage data disk
  (Samsung PM961, x16 LP) took `nvme0n1`. (The first NVMe install disk in the
  fleet — every earlier metal node installs to `/dev/sdX`), storage tier: **not** ephemeral, **not**
  kata, `zone: m70s`. Onboarded 2026-09-07 as ADR-114's third PHYSICAL Garage zone. UEFI PXE
  (`ipxe.efi`), and PXE-first in BIOS by operator choice so a wipe+reinstall needs no console —
  safe because an unflagged MAC 404s at Matchbox and chains to disk. No AVX2 (Pentium Gold G6400),
  `vmx` present. Its OEM disk arrived carrying a Windows GPT; the installer repartitioned it
  without a manual `talosctl wipe disk` (that step is for `longhorn_disks` entries, not the
  install disk).
- `thinkcentre` — ⚠ **RETIRED from cluster duty 2026-09-12** (→ the R12 management-box pilot;
  runbook §"Retire a node from cluster duty"). Kept as a known-good example because the quirks
  below are the box's, not the role's: .53, `/dev/sdb` (120GB Kingston), Longhorn + 2×Optane fast
  tier. Originally
  onboarded via **USB ISO** (`devbox run talos-usb`) when PXE appeared broken — the culprit was a
  **bad NIC cable** (100Mbps + link flapping), replaced 2026-06-11; it PXE-onboards fine now.

## Upgrading a node's Talos — metal AND nocloud VM

`talosctl upgrade` cordons the node, drains it, installs, reboots, then rejoins and uncordons
itself. What you must get right is `--image`, on three axes — **platform, schematic, version**:

```bash
devbox run -- talosctl --talosconfig tofu/talosconfig -n <node ip> -e <a healthy CP ip> \
  upgrade --image <factory installer URL>
```

| Node | Installer URL comes from |
|---|---|
| metal | `data.talos_image_factory_urls.metal.urls.installer` (= `local.talos_install_image`, top of `tofu/metal.tf`) |
| metal with `kata: true` (`machines/machines.yaml`) | `data.talos_image_factory_urls.metal_kata` — pass THIS one |
| VM (nocloud) | `data.talos_image_factory_urls.vm["<longhorn\|plain>-<role version>"].urls.installer` — the `longhorn` flag in `variables.tf` picks the schematic, the ROLE picks the version (`tofu/image.tf`) |

⚠ **Never the generic `ghcr.io/siderolabs/installer`** — which is exactly what `talosctl upgrade`
defaults to when `--image` is omitted. On a nocloud VM it installs the **metal** platform, so the
nocloud datasource is never read again and the node rejoins as a DHCP-addressed `talos-xxxxx`
ghost. That is ADR-014's failure, root-caused 2026-09-18. The pinned talosctl also trails the
fleet by a patch, so the default would downgrade as well. **Always pass `--image`.**

⚠ **The schematic is part of the node's identity.** Upgrading with the wrong one silently strips
extensions: probed 2026-09-18 on `wk-03` (a `longhorn = true` VM) upgraded with the PLAIN
schematic — iscsi-tools vanished and longhorn-manager crashlooped on
`nsenter … iscsiadm: No such file or directory`. The same trap on metal is the `metal_kata` row
above (and FU-076's reverse case). `talosctl get extensions` reports the live schematic id —
compare it after every upgrade, not just the version.

Point `-e` at a control-plane node, never the worker itself: talosctl performs the drain
**client-side** and fetches kubeconfig over `MachineService/Kubeconfig`, which is control-plane
only. (Symptom when you get this wrong: the install succeeds but the node may not reboot; a
manual `talosctl reboot` then boots the staged version.)

For a control-plane node, run the dedicated wrapper from [the management box](management-box.md):

```bash
devbox run cp-upgrade -- cp-01
```

It requires at least three Ready control planes, selects a healthy endpoint other than the target,
checks that etcd has an odd membership of at least three, takes an etcd snapshot under
`/var/lib/mgmt/etcd-snapshots/`, and then enters the same WIP-1 maintenance path workers use. It
verifies the declared version and schematic plus unchanged etcd membership after the node rejoins.
It also gates on Cilium's backend for the in-cluster apiserver Service either side of the reboot —
restarting an apiserver drops it fleet-wide with no re-sync
([FU-258](spikes/cilium-apiserver-restart-backend-loss.md)) — refusing to start on an already
broken fleet and rolling `ds/cilium` after the rejoin only when an agent is genuinely missing it.
The full path was rehearsed on 2026-09-19 with a separate one-node cluster on a disposable nx-02
VM: Talos v1.13.2 → v1.13.10 preserved the nocloud IP, hostname, schematic and etcd identity. The
reproducible lab installer is `scripts/controlplane-lab-install.sh`; its generated credentials are
ephemeral and must never be committed.

**The drain respects PodDisruptionBudgets and fails closed.** Probed 2026-09-18 on v1.13.10: a
`minAvailable: 1` PDB over a 1-replica pod made `talosctl … --drain` retry the eviction, then exit
1 **without rebooting** — while `kubectl drain` errored the same way. So a Longhorn last replica
on the node is a *stuck upgrade*, not data loss; clear it first with
`scripts/node-maintenance.sh settle <node>`. Never pass `--legacy`: that forces the old node-side
drain, the one siderolabs/talos#9882 reported ignoring PDBs.

## Firmware reality (why USB sometimes)

Smart-plug power alone isn't enough — some boxes need a display/console for a one-time BIOS change
(enable Network Stack / PXE OpROM, Secure Boot off, NIC first). The ThinkCentre needed exactly that
one-time visit (and its "PXE never works" turned out to be a bad cable, not firmware — USB ISO
remains the fallback for genuinely PXE-less boxes). This is the argument for vPro/AMT boxes.
