# Machine inventory

Generated from `machines.yaml` by `generate.py` — **do not edit by hand**; edit the YAML and re-run `devbox run -- python3 machines/generate.py`.

Physical boxes only (`kind: metal`) — a VM/LXC draws its power through its host. The same YAML also drives the host tables in [`../README.md`](../README.md) / [`../CLAUDE.md`](../CLAUDE.md) and the metal-node flags in `tofu/locals.tf`.

Benchmark = stress-ng `matrixprod` bogo-ops/s (synthetic, comparable across these runs only; see [`../docs/power-measurements.md`](../docs/power-measurements.md)). **Perf/W** = multi-core bogo-ops/s ÷ load W.

| Machine | Role | Hardware | Cores | RAM (GB) | Plug | Idle (W) | Load (W) | 1-core (bogo/s) | Multi (bogo/s) | Perf/W | Remote power |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| opnsense | Router/FW + DHCP (dnsmasq) + DNS (Unbound) + FRR/BGP + HAProxy + ACME | HP desktop ("Big Data") | 4 | 8 | opnsense | 57 | — | — | — | — | — |
| pve | Hypervisor for the Talos VMs + Matchbox LXC | AliExpress X99 + Intel Xeon E5-2680 v4 | 28 | 64 | pve | 127 | — | — | — | — | — |
| thinkcentre | R12 out-of-band management-box PILOT — left cluster duty 2026-09-12, NixOS installed 2026-09-13 (ADR-129); its first apply waits on FU-012's state copy | Lenovo ThinkCentre Edge | 2 | 4 | thinkcentre | 27.9 | 54.5 | 1200.4 | 2231.7 | 40.9 | smart-plug (switch.tuyalocal_thinkcentre — entity ids were CROSSED with hp-01's 2026-08-18→09-09, read the incident before trusting an older plug observation); auto-boots on AC restore — NOT WoL |
| hp-01 | k8s worker + Longhorn (WoL-capable) | HP Compaq Elite 8300 SFF (board 3397), i3-3220 | 4 | 16 | hp | — | — | — | — | — | Wake-on-LAN (PXE-booted); smart plug switch.tuyalocal_hp exists but AC-restore is flaky — prefer WoL |
| m70s | k8s worker + Longhorn (third physical Garage zone — ADR-114) | Lenovo ThinkCentre M70s SFF | 4 | 16 | — | — | — | — | — | — | PXE-first in BIOS by operator choice — a network wipe+reinstall needs no console. WoL untested; no smart plug yet. |
| wk-metal-01 | k8s worker, compute tier (tainted, 8GB) + Longhorn bulk tier + the garage-2 zone — NO rides | Lenovo ThinkPad X240 | 4 | 8 | laptop3 | 9.1 | 28.8 | 1182.1 | 1932.2 | 67.1 | — |
| wk-metal-02 | k8s worker, ephemeral/compute tier (tainted; kata node, 8GB) | Lenovo ThinkPad X250 | 4 | 8 | laptop4 | — | — | — | — | — | — |
| wk-metal-03 | k8s worker, ephemeral/compute tier (tainted; kata node) | Lenovo ThinkPad X260 (20F600A2MS), i5-6200U (Skylake, VT-x/KVM + AVX2) | 4 | 8 | — | — | — | — | — | — | — |
| wk-metal-04 | k8s worker, ephemeral/compute tier (tainted; kata node, no AVX2) + Longhorn bulk tier | desktop, i5-3570K (Ivy Bridge, VT-x/EPT, no AVX2) | 4 | 16 | — | — | — | — | — | — | — |
| nx-01 | k8s worker, RIDE/ARC tier (tainted; kata node, EPHEMERAL on NVMe) — no Longhorn | Supermicro X10DRT-P-G5-NI22 (Nutanix NX-6035-G5, CSE-827HD+ 2U twin), 2 × Xeon E5-2640 v4 | 40 | 64 | — | — | — | — | — | — | IPMI/BMC — the fleet's FIRST (ADR-013 assumed none): `ipmitool -I lanplus -H 192.168.2.123 -U ADMIN -P ADMIN chassis power on\|off\|cycle`. No WoL or smart plug needed. |
| nx-02 | Proxmox hypervisor — the SECOND one (ROADMAP §Hardware strategy); hosts `wk-04` | Supermicro X10DRT-P-G5-NI22 (Nutanix NX-6035-G5, CSE-827HD+ 2U twin), 2 × Xeon E5-2640 v4 | 40 | 64 | — | — | — | — | — | — | IPMI/BMC: `ipmitool -I lanplus -H 192.168.2.173 -U ADMIN -P ADMIN chassis power on\|off\|cycle`. BMC `nx-02-bmc` 192.168.2.173 (DHCP-reserved). |
| pop-os | the Docker host running this jail | workstation (Pop!_OS) | — | — | — | — | — | — | — | — | — |
