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
| Version | 26.7.5 + `os-frr`, `os-haproxy`, `os-acme-client` (prod's three config plugins) — the 26.7 series (prod's since 2026-09-29) |
| Baseline | snapshot **`baseline`** (the harness's default `OPN_TEST_SNAPSHOT`) — after firmware + plugins + API/SSH, before any homelab playbook |
| Secrets | wallet only: `opnsense-test-root-password`, `opnsense-test-api-key`, `opnsense-test-api-secret`. Root SSH = key login with the pve seed key (`~/.claude/homelab-pve-ssh/id_ed25519`); no password auth |

Version caveat: a series' package mirror serves only its head, so a box built later can sit on a
newer core hotfix than prod (26.1: `26.1.11_10` built vs prod's `26.1.11_6`). On 2026-09-29 both
read `26.7.4_1`; on 2026-09-30 the mirror moved to `26.7.5` (every build failed at the old `SERIES`),
so `baseline` took the official check → update (12 packages, no reboot), and prod followed the same
path the same morning in window seat-1790760478-4482 (14 packages, 16 s, no reboot). Prod's other
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
   seed ISO → first boot through the importer → firmware update to `SERIES` (26.7.5) → plugins → clean
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

## The official update path — observed on this VM (2026-09-29)

The firmware path the GUI drives ([upstream: major upgrades](https://docs.opnsense.org/manual/updates.html#major-upgrades)),
run through the API against `9110` from `baseline` (26.1.11_10). Each row is what one call did; "revisions" are
new entries in `GET core/backup/backups/this` (all written by `(root)`, none by the API user).

| Step | Call | Took | Reboots | Revisions written |
|---|---|---|---|---|
| check | `POST core/firmware/check`, poll `upgradestatus` | ~3 s | 0 | **none** (count and newest id unchanged, `/conf/config.xml` mtime unchanged — twice: at 26.1 and at 26.7) |
| hotfix | `POST core/firmware/update` | < 1 min | 0 | none — "Nothing to do": the 26.1 mirror serves only 26.1.11_10, which `baseline` already is. The bootstrap's 26.1.6 → 26.1.11_10 pass (one reboot) plus the plugin installs left pairs of `run_migrations.php made changes` + `firmware/register.php made changes` |
| major | `POST core/firmware/upgrade` (offered once 26.1 is fully updated: `status` = `upgrade`, `upgrade_major_version` `26.7`, 26.1 declared end of life) | 5 min 06 s to API-up | 3, all automatic | one: `run_migrations.php made changes` (SystemHealth 0.0.0→1.0.0, Trust General 1.0.1→1.0.2) |
| minor | `POST core/firmware/check`, then `POST core/firmware/update` | 2 min 42 s to API-up | 1, automatic (the job ends `***REBOOT***`) | two: `run_migrations.php made changes` |

- **The major runs offline.** ~2 min 20 s online (download + kernel), then reboot → `>>> Invoking early script 'upgrade'`
  installs `base-26.7`, reboot → installs `packages-26.7` (337 packages, FreeBSD 14.3 → 15.1), reboot → up at
  **26.7.1_1**. API and SSH are down for ~3 min; the only view is the serial console (`qm terminal 9110`, or a
  reader on `/var/run/qemu-server/9110.serial0` like the bootstrap's importer driver). No prompt at any stage.
  The loader keeps the previous kernel as `kernel (1 of 2)`.
- During the download `upgradestatus` returns **invalid JSON** (raw progress control characters in `log`) — a
  poller must strip `\x00-\x1f` before parsing, and judge by the outcome (`firmware/info`), as the bootstrap does.
- After the minor: **26.7.4_1**, FreeBSD 15.1-RELEASE-p3, `os-frr` 1.55 (frr10 10.7.1), `os-haproxy` 5.1
  (haproxy32 3.2.23), `os-acme-client` 4.17; a following check reports no updates.
- The resulting disk was snapshot `trial-26-7-4`. Prod took the same path the same evening (26.7.4_1), so it
  became **`baseline`** (the 26.1 one deleted, 2026-09-29 night — §Recipes, *Moving the baseline*). The drill
  is born from the **26.7 nano** instead (`var.opnsense_test_nano_version`, the bootstrap's `NANO_VERSION`):
  26.7 → 26.7.4_1 is one minor update, no major pass — and the importer answered the same two prompts.
- First harness run there (2026-09-29, `--pr 2033`): **PASS** on all five steps — master's `oxlorg.opnsense`
  25.7.8 and #2033's 26.1.11 both converge, reach the running daemons and rerun at `changed=0` on 26.7.4.

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
  `ansible/opnsense-*.yml` play plus every `opnsense/*.py` (the two DHCP scripts — `OPN_DHCP_SERVER`
  picks dnsmasq or Kea, the other converges off, ADR-145 — and `tuya-egress.py`),
  through the same guard, inventory and isolation overrides, plus
  [`drill-overrides.yml`](../ansible/test-vm/drill-overrides.yml) (the BGP neighbour is the drill's
  fake peer). The DHCP scripts run with `OPN_DHCP_REMAP=192.168.2.=192.168.1.` — prod's pool and
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
role), or — only if it really is environment, unreachable or dead residue — a reviewed map line.
Prod config is never deleted to lower the score (operator, 2026-09-29): dead residue (the ISC-DHCP
block, the empty-valued legacy tunables, disabled port-forwards) is accepted **in its dead state
only**, by a map line with a condition (`| prod:value=`, `| prod:disabled=1`, syntax in the map's
header) — the same path counts again the day it comes alive.

### The router rehearsal — the drill in the future router's shape

`bash scripts/opnsense-drill.sh --router` (jail only: it reads the FU-013 backup) builds the same
throwaway VM `9199`, but shaped like the router that replaces Big Data
([`router-move.md`](router-move.md)), and carrying its identity:

| | the drill | `--router` |
|---|---|---|
| WAN | `vtnet1` on `vmbr0`, static `.68` | **`igb0` = nx-02's `eno2` by PCI passthrough** (`machines.yaml` `nx-02.router_wan_pci`), DHCP, `spoofmac` = Big Data's `em0` (`opnsense.wan_mac`) — uncabled |
| management + egress | the WAN | `opt9` "MGMT" = `vtnet1` on `vmbr0`, static `.68` (`opt9`: prod's `opt1..3` are its spare card ports, and the score aligns interfaces by key) — the real router has none |
| identity | minted per run | **carried from the newest FU-013 backup** (below) |
| score map | `compare-map.txt` | `compare-map-router.txt` first, then the base map minus its `interfaces/wan/**` wildcard — here the WAN is comparable |
| metrics | the box's textfile | none (the weekly score stays the plain drill's) |

**The WAN must be dark.** With Big Data's MAC spoofed, a cabled `eno2` would take the ISP lease
from the live router. The bootstrap's `create` refuses a WAN NIC with carrier (it raises an
admin-down port to read it, then lowers it again), one enslaved to a bridge, one that holds a
host address, and one that shares its IOMMU group. A NIC left on `vfio-pci` by a previous run
is first handed back to its host driver, because without a host netdev there is no carrier to
read. The rehearsal then asserts `no carrier` from inside the VM (`wan_dark`).

**The carry** ([`opnsense/test-vm/seed-shape.py`](../opnsense/test-vm/seed-shape.py)). The drill
fetches the newest object by port-forward to Garage, which needs none of the router's VIPs. It
decrypts it with the wallet's age identity into the 0700 secret dir, and the bootstrap's `render`
splices identity into the seed:

- `trust`: every `<cert>` + `<ca>` with its refids, plus the GUI's `ssl-certref`;
- `acme`: `OPNsense/AcmeClient` whole — the registered account and the certificate rows bound to
  those refids;
- `api-users`: the FU-013 users with their hashed keys, plus root's prod key line appended to the
  seed's throwaway one;
- `wireguard`: `OPNsense/wireguard` whole — the server keypair and its peers, so the laptop and
  phone configs survive the move unchanged (operator, 2026-09-30: option (a) of
  [`router-move.md`](router-move.md) §The identity).

Not carried but the router's own: **root's password** is the wallet's `opnsense-root-password`
(operator, 2026-09-30), not the plain drill's per-run throwaway.

The decrypted file is deleted right after the build, and the seed ISO follows the bootstrap's
usual path: a 0600 file on nx-02 for the first boot only. Never carried: anything a play owns
(the WireGuard role finds the carried instance and keeps its keypair — it generates one only
when the instance is absent). A carried cert that falls due for renewal
during the run would renew FROM the rehearsal, which means a real LE order and a Cloudflare write
with prod's token. So the drill refuses while any carried cert is ≥ 58 days old (os-acme-client
renews at 60).

**`--wan bridged`** (docs/router-move.md): the WAN is `vtnet2`, virtio (`queues=2`, `firewall=0`)
on a runtime host bridge `vmbr9` whose only port is the same dark `eno2` — built and deleted by the
bootstrap, refused if a configured bridge has the name. After the other probes a fake-ISP LXC joins
`vmbr9` (dnsmasq + iperf3 on `11.255.0.1/24`, outside prod's `blockpriv`/`blockbogons`; its packages
arrive over a temporary `vmbr0` leg deleted before dnsmasq starts). `wan_lease` wants the router's
lease on the spoofed MAC; `wan_throughput` runs iperf3 from the LAN probe through NAT, 1 and 4
streams both ways, each ≥ `OPN_DRILL_WAN_MIN_MBPS` (900). First run, 2026-09-30: 2988–3256 Mbit/s,
PASS, score 0. Expected per the literature: 1 Gbit/s over virtio is routine on Broadwell-class
Xeons with offloads off; the multi-Gbit ceilings people hit need multiqueue + RSS tuning
([Proxmox forum](https://forum.proxmox.com/threads/opnsense-10gbit-performance-and-throughput-limitation.142737/),
[Netgate](https://forum.netgate.com/topic/177372/limit-of-virtio-performance),
[OPNsense virtual setup](https://docs.opnsense.org/manual/virtuals.html)).

**Extra probes:** `wan_dark`, `wan_mac`, and `carried_key_{root,backup_puller,automation}`. Each
key probe calls an endpoint the user's privileges allow, using prod's wallet pair against the
rehearsal VM, and wants HTTP 200: no consumer re-keys on the move. `real_cert` wants HAProxy's
first VIP to serve the carried Let's Encrypt certificate for its SNI, where the plain drill
serves the harness's self-signed fixture. `wg_handshake` runs
[`scripts/wireguard-handshake-probe.py`](../scripts/wireguard-handshake-probe.py) in the probe
container as the laptop peer (its wallet key over stdin) against the LAN address, with PROD's
server pubkey: a reply proves the carried server key, since the WAN is dark. `root_password`
recomputes root's crypt hash from the live `config.xml` with the wallet password and its own salt.

Under `--router` the base map's "matched nothing" list is long by construction: the carried users
and certificates now equal prod's, so their env/accepted lines have nothing left to explain. Read
that list on the plain drill only.

**First run (2026-09-29 night): PASS, score 7, all twelve probes green.** The WAN was dark and
wore `em0`'s MAC; prod's three API pairs answered 200; HAProxy served the carried LE cert; the
users role minted nothing. The rows were the WAN's own shape (prod's `WAN_GW` dynamic default
gateway, `gateway` on the interface, a `descr`, an inert IPv6 field), the users' `nextuid`
counter, and SystemHealth (#2129). The seed now writes prod's WAN gateway, and the maps take
the rest.

**2026-09-30: score 0, thirteen probes.** #2129 took SystemHealth; the WireGuard carry added
`wg_handshake` (green); the last six rows were prod's pre-26.7 `WAN_GW` storage (three flags
empty where 26.7 writes `0`, three newer flags absent), accepted by the router overlay in that
dead state only.

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
