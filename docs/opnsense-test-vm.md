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

## The rebuild drill

The test VM above answers "does this PR apply?". The drill answers the boot-from-git question for
the router itself: **build an OPNsense from nothing, run ALL router code on it, and measure how far
the result is from prod** — weekly, destroyed after each run. It is a second VM, not a mode of
`9110`: `9110` is rolled back and forward by PR validations, and the drill must never touch it.

| | |
|---|---|
| VM | `9199` `opnsense-drill` on nx-02 — created and destroyed by each run (never in tofu); same hardware shape as `9110` |
| WAN | `vmbr0`, **`192.168.2.68/24`** — reserved in [`machines.yaml`](../machines/machines.yaml) although it is empty between runs |
| LAN | **`vmbr2`**, a second port-less bridge ([`tofu/opnsense-test.tf`](../tofu/opnsense-test.tf)) — `192.168.1.1/24` like `9110`'s, so it gets its own segment: one bridge for both would put two `.1`s and two DHCP servers on one wire |
| Probe container | `9198` `opnsense-drill-probe`, a Debian 12 LXC on `vmbr2` (template downloaded by the same tofu file), created and destroyed per run: the fake BGP peer and the DHCP/DNS/TLS probes |

The bridge and the template are the only persistent pieces.

**Run it:** `bash scripts/opnsense-drill.sh [--ref <rev>] [--keep]` — from the jail (prod creds
from the wallet) or the box (its env file). The script's header lists the stages (preflight →
build → probe-setup → converge → probe → compare → destroy) and the environment; each stage is timed in the report.

- **build** reuses the test VM's bootstrap: its `create`/`destroy` verbs make the tofu-shaped VM
  by `qm` (and refuse vmid `9110` and the name `opnsense-test`), then `bootstrap` as above — with a
  throwaway root password + API pair minted in memory per run instead of wallet entries.
- **converge** is the harness's step `all` (`--ref <rev> --steps "1 all"`): every
  `ansible/opnsense-*.yml` play plus `opnsense/dnsmasq-dhcp.py` and `opnsense/tuya-egress.py`,
  through the same guard, inventory and isolation overrides, plus
  [`drill-overrides.yml`](../ansible/test-vm/drill-overrides.yml) (the BGP neighbour is the drill's
  fake peer). `dnsmasq-dhcp.py` runs with `OPN_DHCP_REMAP=192.168.2.=192.168.1.` — prod's pool and
  reservations, moved onto the drill's LAN prefix (refused against the router).
- **preflight** reads nx-02's `nvme-thin` and free memory before anything writes and refuses above
  70 % / below 4 GiB (read the pool before writing GBs to a VM node); a leftover `opnsense-drill` from a
  crashed run is destroyed by name.

### The behaviour probes — proven by what it does, not what it saved

After the build and **before** any router code runs, the drill creates the probe container
(`9198` `opnsense-drill-probe`, Debian 12, unprivileged) on `vmbr2` and installs FRR, a DHCP
client and `dig` through the fresh router's own NAT — so a converge that breaks egress cannot
fail the setup. After the converge it asserts, each with its own metric/row:

| Probe | Passes when | Expected value comes from |
|---|---|---|
| `dhcp_reservation` | a NIC with a reserved MAC is leased its pinned address | `opnsense/dnsmasq-dhcp.py` `HOSTS[0]`, remapped to `1.0/24` |
| `dhcp_pool` | a NIC with a random MAC is leased an address in `.100–.245` | the script's `RANGE` |
| `dns_override` | `dig @192.168.1.1` answers an Unbound override | `group_vars` `unbound_hosts[0]` |
| `haproxy_tls` | a TLS handshake completes on a HAProxy VIP with the frontend's SNI | `haproxy_proxied_services[0]` (the cert is the harness fixture's) |
| `bgp_session` | the fake peer (FRR, **AS 64513**, `192.168.1.2`) reaches `Established` with the router's FRR | [`drill-overrides.yml`](../ansible/test-vm/drill-overrides.yml) makes it the router's neighbour |
| `bgp_route` | the router's kernel routes the peer's `192.168.40.254/32` via `192.168.1.2` | the peer announces it; prod's `CILIUM-ALLOW-ALL` route map admits it |

The VM's WAN-side block on TCP 179 stays: the peer is on the LAN side, so the session is real
and still cannot reach the cluster. **First run (2026-09-29):** the four service probes pass; both
BGP probes FAILED because `bgpd` never starts on a fresh router (FU-298's second defect). The
bgp role now reads the running FRR config and stops + starts FRR only when `router bgp` is
missing ([`bgpd-running.yml`](../ansible/roles/opnsense-bgp/tasks/bgpd-running.yml)); the drill
at that head (2026-09-29): all six probes pass, `bgp_session` `Established`.

### The realism score — prod's config.xml vs the from-git build

After the converge, both `config.xml`s are downloaded (prod: `GET /api/core/backup/download/this`,
the only call the drill makes to `192.168.2.1`) into a 0600 file, compared, and deleted.
[`opnsense/drill/config-compare.py`](../opnsense/drill/config-compare.py) aligns the trees (list
items by natural key — name/description/address — never by the per-box uuids; uuid references by
the item they name) and sorts every difference into:

| Bucket | Meaning | Where it is decided |
|---|---|---|
| **(a) clickops** | on prod and not in code, or in code and not on prod | everything the map does not name — **the score is the count of these rows** |
| (b) env | the drill's own addresses, name, keys, WAN, seed; the LAN prefix remap | [`opnsense/drill/compare-map.txt`](../opnsense/drill/compare-map.txt) `env` / `remap` lines |
| (c) accepted | certificates, generated ids, timestamps, revision history — and ACME issuance, which the drill deliberately does not do | the same file's `accepted` lines |

The map is committed and small on purpose: a broad line hides exactly the click-ops the score
exists to count, and a line that matched nothing is listed at the bottom of each report. The
report shows sections, counts and paths with item keys redacted (`frontend[*]`) — never a value;
prod's config holds private keys and hashes. `bash opnsense/drill/config-compare-test.sh` is the
scorer's self-test (synthetic documents); the drill runs it before every score.

**Reducing the score** is the point: each (a) row is either code to write (put the setting in a
role), residue to delete on prod (a dead ISC-DHCP block), or — only if it really is environment or
unreachable — a reviewed map line.

### On the management box — weekly, with metrics and belts

The box ([`management-box.md`](management-box.md)) runs it: `mgmt-opnsense-drill.timer`, **Sundays
03:30 UTC** (±20 min, `Persistent`), `mgmt-opnsense-drill.service` in
[`mgmt/nixos/hosts/mgmt/default.nix`](../mgmt/nixos/hosts/mgmt/default.nix) — from a detached
worktree of the checkout's current revision (the hourly `mgmt-pull` reset must not change a script
mid-run), `restartIfChanged = false`, 3 h timeout. Credentials: nothing new — the env file's prod
OPNsense pair (already provisioned for the belt's `--check`, `mgmt-provision-secrets.sh`) and the
pve seed key at `/var/lib/mgmt/pve-ssh/`; the drill VM's own creds are minted per run.

It writes `mgmt_opnsense_drill_*` to the textfile collector (job `mgmt-node`): `_success`,
`_last_run_timestamp_seconds`, `_duration_seconds`, `_stage_seconds{stage}`,
`_stage_failed{stage}`, `_probe_success{probe}`, `_realism_score`, `_realism_score_previous` (kept
box-side in `/var/lib/mgmt/opnsense-drill/`, so "regressed" is run over run) and
`_config_diff_rows{section,bucket}`. Belts in
[`argocd/resources/mgmt-metrics/opnsense-drill.yaml`](../argocd/resources/mgmt-metrics/opnsense-drill.yaml)
(fixture `opnsense-drill.promtool-test`): **`MgmtOpnsenseDrillFailed`** (last run failed a stage),
**`MgmtOpnsenseDrillStale`** (no finished run in 9 days), **`MgmtOpnsenseDrillMetricsAbsent`**
(box scraped, file never written, 9 days), **`MgmtOpnsenseDrillScoreRegressed`** (score above the
previous run's). Run it now, by hand: `systemctl start --no-block mgmt-opnsense-drill` on the box,
`journalctl -u mgmt-opnsense-drill -f` for the report.
