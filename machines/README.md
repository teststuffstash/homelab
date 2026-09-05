# Machine inventory

Generated from `machines.yaml` by `generate.py` — **do not edit by hand**; edit the YAML and re-run `devbox run -- python3 machines/generate.py`.

Physical boxes only (`kind: metal`) — a VM/LXC draws its power through its host. The same YAML also drives the host tables in [`../README.md`](../README.md) / [`../CLAUDE.md`](../CLAUDE.md) and the metal-node flags in `tofu/locals.tf`.

Benchmark = stress-ng `matrixprod` bogo-ops/s (synthetic, comparable across these runs only; see [`../docs/power-measurements.md`](../docs/power-measurements.md)). **Perf/W** = multi-core bogo-ops/s ÷ load W.

| Machine | Role | Hardware | Cores | RAM (GB) | Plug | Idle (W) | Load (W) | 1-core (bogo/s) | Multi (bogo/s) | Perf/W | Remote power |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| opnsense | Router/FW + DHCP (dnsmasq) + DNS (Unbound) + FRR/BGP + HAProxy + ACME | HP desktop ("Big Data") | 4 | 8 | opnsense | 57 | — | — | — | — | — |
| pve | Hypervisor for the Talos VMs + Matchbox LXC | AliExpress X99 + Intel Xeon E5-2680 v4 | 28 | 64 | pve | 127 | — | — | — | — | — |
| thinkcentre | k8s worker + Longhorn (+ 2×Optane fast tier) | Lenovo ThinkCentre Edge | 2 | 4 | thinkcentre | 27.9 | 54.5 | 1200.4 | 2231.7 | 40.9 | smart-plug (switch.tuyalocal_thinkcentre); auto-boots on AC restore — NOT WoL |
| hp-01 | k8s worker + Longhorn (WoL-capable) | HP desktop | — | 8 | hp | — | — | — | — | — | Wake-on-LAN (PXE-booted); smart plug switch.tuyalocal_hp exists but AC-restore is flaky — prefer WoL |
| wk-metal-01 | k8s worker, ephemeral/compute tier (tainted; kata node, 8GB) + Longhorn bulk tier | Lenovo ThinkPad X240 | 4 | 8 | laptop3 | 9.1 | 28.8 | 1182.1 | 1932.2 | 67.1 | — |
| wk-metal-02 | k8s worker, ephemeral/compute tier (tainted; kata node, 8GB) | Lenovo ThinkPad X250 | 4 | 8 | laptop4 | — | — | — | — | — | — |
| wk-metal-03 | k8s worker, ephemeral/compute tier (tainted; kata node) | laptop, i5-6200U (Skylake, VT-x/KVM + AVX2) | 4 | 8 | — | — | — | — | — | — | — |
| wk-metal-04 | k8s worker, ephemeral/compute tier (tainted; kata node, no AVX2) + Longhorn bulk tier | desktop, i5-3570K (Ivy Bridge, VT-x/EPT, no AVX2) | 4 | 16 | — | — | — | — | — | — | — |
| pop-os | the Docker host running this jail | workstation (Pop!_OS) | — | — | — | — | — | — | — | — | — |
