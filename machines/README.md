# Machine inventory

Generated from `machines.yaml` by `generate.py` — **do not edit by hand**; edit the YAML and re-run `devbox run -- python3 machines/generate.py`.

Benchmark = stress-ng `matrixprod` bogo-ops/s (synthetic, comparable across these runs only; see [`../docs/power-measurements.md`](../docs/power-measurements.md)). **Perf/W** = multi-core bogo-ops/s ÷ load W.

| Machine | Role | Hardware | Cores | RAM (GB) | Plug | Idle (W) | Load (W) | 1-core (bogo/s) | Multi (bogo/s) | Perf/W | Remote power |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| pve | Proxmox hypervisor (hosts the Talos VMs + Matchbox LXC) | AliExpress X99 + Intel Xeon E5-2680 v4 | 28 | 64 | pve | 127 | — | — | — | — | — |
| opnsense | Router / firewall / DHCP / DNS / FRR / HAProxy | HP desktop ("Big Data") | 4 | 8 | opnsense | 57 | — | — | — | — | — |
| thinkcentre | k8s worker (storage tier + Optane fast tier) | Lenovo ThinkCentre Edge | 2 | 4 | konditsioneer | 27.9 | 54.5 | 1200.4 | 2231.7 | 40.9 | smart-plug (switch.konditsioneer_socket); auto-boots on AC restore — NOT WoL |
| wk-metal-01 | k8s worker (ephemeral / compute tier, tainted) | Lenovo ThinkPad X240 | 4 | 8 | laptop3 | 9.1 | 28.8 | 1182.1 | 1932.2 | 67.1 | — |
| wk-metal-02 | k8s worker (ephemeral / compute tier, tainted) | Lenovo ThinkPad X250 | 4 | 8 | laptop4 | — | — | — | — | — | — |
| wk-metal-03 | k8s worker (ephemeral / compute tier, tainted; KATA node — microVM runtime) | laptop, i5-6200U (Skylake, VT-x/KVM + AVX2) | 2 | 8 | — | — | — | — | — | — | — |
| hp-01 | k8s worker (storage tier, WoL-capable) | HP desktop | — | 8 | — | — | — | — | — | — | Wake-on-LAN (PXE-booted; no smart plug) |
