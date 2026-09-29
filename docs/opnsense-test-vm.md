# opnsense-test — the OPNsense test VM on nx-02

_Tracked by FU-297 ([`follow-ups.md`](follow-ups.md)). Hardware: [`tofu/opnsense-test.tf`](../tofu/opnsense-test.tf).
Guest build: [`scripts/opnsense-test-vm-bootstrap.sh`](../scripts/opnsense-test-vm-bootstrap.sh) + the seed template
[`opnsense/test-vm/config.xml.tmpl`](../opnsense/test-vm/config.xml.tmpl). Inventory:
[`machines/machines.yaml`](../machines/machines.yaml). **Using it** — per-run rollback, the plays,
the report — is the validation harness, [`runbook.md`](runbook.md) §Validate a router-config PR on
the OPNsense test VM (`scripts/opnsense-test-vm.sh`)._

A throwaway OPNsense router at prod's version, so a router-config PR (`ansible/opnsense-*.yml`,
`opnsense/dnsmasq-dhcp.py`) can be applied to a **real API** before it reaches `192.168.2.1`.
`--check` against a stub proves plumbing, not apply.

## Shape

| | |
|---|---|
| VM | `9110` `opnsense-test` on nx-02 — 2 vCPU, 2 GiB, 8 GiB on `nvme-thin` |
| WAN = `vtnet1` = net1 | `vmbr0`, **`192.168.2.67/24`**, gateway `192.168.2.1` — the management path (API `:443` + SSH `:22` from `192.168.2.0/24` only) and the egress for firmware/plugins. "Block private networks" is off (WAN *is* private here) |
| LAN = `vtnet0` = net0 | **`vmbr1`**, a bridge with **no port and no host address** — `192.168.1.1/24` ([`ip-plan.md`](ip-plan.md) carve). DHCP, HAProxy VIPs and Unbound on this side serve nobody |
| BGP | a floating rule blocks **outbound TCP 179 on WAN**, so the box's FRR can never peer with the real Cilium nodes, whatever a playbook configures |
| Version | 26.1.11 + `os-frr`, `os-haproxy`, `os-acme-client` (prod's three config plugins) |
| Baseline | snapshot **`baseline`** (the harness's default `OPN_TEST_SNAPSHOT`) — after firmware + plugins + API/SSH, before any homelab playbook |
| Secrets | wallet only: `opnsense-test-root-password`, `opnsense-test-api-key`, `opnsense-test-api-secret`. Root SSH = key login with the pve seed key (`~/.claude/homelab-pve-ssh/id_ed25519`); no password auth |

Version caveat: the 26.1 package mirror serves only the series head (`opnsense-26.1.11_10` on
2026-09-29) while prod reads `26.1.11_6` — same release, newer core hotfix revision. Prod's other
plugins (`os-ddclient`, `os-isc-dhcp`, `os-tftp`) are not installed: no play touches them.

## Why this bootstrap mechanism

OPNsense has no cloud-init; the options for an unattended first boot of 26.1 were read from the
upstream source (`opnsense/core` stable/26.1, `opnsense/tools`):

- **Chosen: the nano image + OPNsense's own config importer, answered over the serial socket.**
  The nano image is a preinstalled UFS disk (`tools/build/nano.sh`) whose primary console is
  serial (`nano_hook`) and which ships **no `/conf/config.xml`**. On such a first boot, the
  `import` syshook runs `opnsense-importer -b`, which offers a 7-second *"Press any key to start
  the configuration importer"* and then *"Select device to import from"*; given a CD it mounts
  it as cd9660 and copies `/conf/config.xml` from it. So the script burns the rendered config onto
  a seed ISO, attaches it as `ide2`, starts the VM and answers exactly those two prompts through
  `/var/run/qemu-server/9110.serial0` — no login, no factory password, no installer.
- Rejected: **writing config.xml into the image** — the root is UFS2 and the Proxmox kernel ships
  `ufs` read-only (`# CONFIG_UFS_FS_WRITE is not set`).
- Rejected: **the installer images** (dvd/vga/serial) — a full interactive installer to drive over
  serial, then the same importer question anyway.
- Rejected: **boot the factory config and configure through the GUI/console** — the factory LAN
  address, the factory root password in the recipe (operator rule: no credential in repo text,
  even a factory one) and a menu-driven console to script.

Rehearsed end to end on a throwaway VM on nx-02 before this landed (2026-09-29): importer
answered, API up with the wallet key, 26.1.6_2 → 26.1.11_10 in one update pass + reboot, the three
plugins at prod's exact versions, a marker file gone after `qm rollback` (42 s to API-up). The
rehearsal found one thing now in the template: a WAN pass rule needs `disablereplyto` — its
default `reply-to` sends the SYN-ACK to a same-subnet client via the prod router, whose state
table never saw the SYN and drops it. (Also: Proxmox snapshot ids allow no dots.)

The seed is rendered from the template + the wallet at bootstrap time, lives on nx-02 only for
the first boot, and is deleted before the snapshot. The API secret and the root password go in
as SHA-512 `crypt` hashes (core's `Auth/API.php` checks with `password_verify`).

## Recipes

```bash
bash scripts/opnsense-test-vm-bootstrap.sh status   # power, snapshots, version, plugins
ssh -i ~/.claude/homelab-pve-ssh/id_ed25519 root@192.168.2.67
# back to the baseline by hand (the harness does this itself as its step 1):
ssh -i ~/.claude/homelab-pve-ssh/id_ed25519 root@192.168.2.59 qm rollback 9110 baseline --start 1
```

**Build from nothing** (the VM's hardware is tofu, its guest is the script):

1. `devbox run mgmt-tf -- plan` → the bridge, the nano download, the VM (created **stopped**;
   tofu ignores its power state afterwards). Apply inside a
   [maintenance window](../.claude/skills/maintenance-window/SKILL.md) — the bridge is a host
   network change on the hypervisor that carries `cp-02`.
2. `bash scripts/opnsense-test-vm-bootstrap.sh bootstrap` — wallet entries (created if missing) →
   seed ISO → first boot through the importer → firmware update to 26.1.11 → plugins → clean
   shutdown → seed CD removed → snapshot `baseline` → started.

**Recovery — a bootstrap that died after the import** (VM up, API answering with the wallet key,
no snapshot yet): `bash scripts/opnsense-test-vm-bootstrap.sh finish` redoes only what is missing.
Every step is judged by its outcome (version, installed plugin), not by the firmware job's
status: on the 2026-09-29 build `upgradestatus` read `error` for an update that had landed.

**Recovery — the disk booted without the seed** (e.g. someone ran `qm start` first): the factory
config was written and the importer never offers itself again; `bootstrap` refuses. Destroy the
VM (`qm destroy 9110` on nx-02) and let the next `mgmt-tf` plan/apply recreate it, then bootstrap.

**Moving the baseline** (a new prod version): roll back, update, then replace the snapshot
(`qm delsnapshot` + `qm snapshot`) and bump `SERIES` in the bootstrap script.
