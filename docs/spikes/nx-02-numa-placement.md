# Spike — nx-02 NUMA placement and CI swapping

**Tracked by:** [FU-289](../follow-ups.md#hardware--nodes). Investigation dated 2026-09-25,
counters read 2026-09-27; no NUMA configuration change or controlled placement experiment has
been performed. The tracker owns current status and the next action, including runner-02's
parked state.

## Evidence and remaining uncertainty

The [original read-only diagnosis](../../agents/coordinator/TICK-LOG.md#2026-09-25--ci-runner-02-swapping-diagnosis-fu-289)
records runner/host comparisons, timestamps, PR history and process memory measurements.
Both runner guests had 12 GiB, six vCPUs, two runner services, matching Debian/kernel versions,
no guest swap and matching build-cache configuration. The salient difference was host memory
placement and swap storage, not a missing runner cache.

nx-02 has two Xeon E5-2640 v4 sockets, each with ten cores/twenty hardware threads and 32 GiB
RAM. wk-04 has 16 vCPUs/32 GiB; cp-02 has four vCPUs/12 GiB; runner-02 has six vCPUs/12 GiB.
After wk-04's NVMe PCI passthrough, its approximately 32 GiB of host RAM was pinned, with
approximately 25.7 GiB on physical node 1. Runner-02 had approximately 3.7 GiB swapped onto
the host HDD while node 0 still had approximately 12 GiB free. Host automatic NUMA balancing
was enabled, but cannot relocate VFIO-pinned pages in the usual way.

Swap began on September 24 at 22:43Z with approximately 11 GiB globally available. During the
next morning's failing e2e runs, swap-in, high HDD utilization and I/O pressure coincided with
the node-preparation stalls. FU-225's global low-memory threshold misses this condition.
NUMA imbalance is the leading explanation, not a proven allocation-level root cause:
historical per-node placement was absent and no A/B experiment has been run. THP allocation/
compaction may contribute; no evidence establishes a kernel regression.

## Desired behavior and the three placement layers

The operator prefers automatic, best-effort placement with fallback, without enforcing
Kubernetes CPU/memory assignments. This is a preference for the investigation, not an approved
implementation. Keep these mechanisms distinct:

1. **Host RAM placement:** Proxmox `numa: 1` exposes guest topology but does not bind the RAM
   backing each guest node to the corresponding physical node. Explicit host-node policies
   determine where the VM's backing pages are allocated.
2. **Host CPU placement:** guest vCPU groups must run on corresponding physical sockets for
   guest-local memory to mean physically local memory. The installed Proxmox whole-VM affinity
   setting cannot express separate socket masks for each guest group. The inspected installation
   lacks the per-NUMA-group mapping described in the upstream RFC linked below. A mapping can
   allow any CPU within a socket; individual cores need not be dedicated to a VM or pod.
3. **Guest placement:** Linux initially prefers memory local to the allocating thread and can
   fall back. Threads can move as CPU load changes. Background access-driven migration requires
   automatic NUMA balancing support; guest topology alone does not provide it.

An illustrative preferred-memory configuration for wk-04 is:

```ini
memory: 32768
sockets: 2
cores: 8
numa: 1
numa0: cpus=0-7,hostnodes=0,memory=16384,policy=preferred
numa1: cpus=8-15,hostnodes=1,memory=16384,policy=preferred
```

Here `cpus` are **guest** CPU IDs, not host affinities. Each half prefers a different physical
node but can fall back, so this targets rather than guarantees a 16/16 GiB physical split.
`policy=bind` constrains backing allocation to the specified node, with less flexibility under
pressure. Interleaving across both physical nodes instead distributes backing pages across
them, helping capacity balance without establishing guest-to-host locality. These are alternative
experiments, not equivalent settings. A fresh VM start is needed to test initial placement of
wk-04's pinned RAM; changing an allocation policy does not redistribute existing pinned pages.

## Talos limitation confirmed live

Read-only inspection of wk-04 on 2026-09-25 found no
`/proc/sys/kernel/numa_balancing`. Reading `/proc/config.gz` confirmed:

```text
CONFIG_NUMA=y
CONFIG_ARCH_SUPPORTS_NUMA_BALANCING=y
# CONFIG_NUMA_BALANCING is not set
CONFIG_MIGRATION=y
```

Thus wk-04 supports NUMA topology and page migration mechanisms, but **not automatic NUMA
balancing**. The host's enabled sysctl does not enable that feature inside the guest. The
following Talos setting is meaningful only after selecting/building a kernel with
`CONFIG_NUMA_BALANCING=y`; it cannot enable a compiled-out feature:

```yaml
machine:
  sysctls:
    kernel.numa_balancing: "1"
```

Without that kernel change, ordinary first-touch local allocation and CPU scheduling still
operate, but there is no background NUMA access sampling to bring pages and tasks together.
Even with guest balancing enabled, physical locality requires the host mapping described above.
Guest page migration can copy data between guest-physical pages; that is distinct from migrating
the host pages pinned by VFIO.

## Kubernetes and the 2 CPU / 4 GiB pod example

wk-04's live kubelet configuration was `cpuManagerPolicy: none`, `memoryManagerPolicy: None`,
`topologyManagerPolicy: none`, scope `container`, with no reserved-memory configuration.
Leaving these unchanged avoids dedicated CPU allocation and NUMA admission constraints.
Setting only Topology Manager to `best-effort` does not activate CPU/memory placement managers.

A pod requesting two CPUs and 4 GiB is assigned to a Kubernetes worker; those requests do not
reserve a NUMA node or two exclusive CPUs. Its threads touch pages, which normally allocate
locally where possible. Multiple threads/containers can spread across NUMA nodes even when
the whole pod could fit on one. Automatic balancing, if supported, optimizes observed accesses
over time, not the pod's declared resource bundle. Kubernetes does not continuously move a
running pod between workers to improve NUMA locality.

## What the host's counters settled (read 2026-09-27, cumulative since the 09-24 boot)

| Counter | Value | Reading |
|---|---|---|
| `pswpout` / `pswpin` | 6.9 GiB / 7.0 GiB | the whole event, out and back |
| `pgsteal_kswapd` vs `allocstall_*` | 9.0 GiB vs 462 stalls | **kswapd** did the swapping, direct reclaim ~never ran |
| `numa_miss` on node 0 | 36.8 GiB | allocations meant for node 1 fell back to node 0 fine (`zone_reclaim_mode=0`) |
| `compact_fail` / `compact_stall` | 3986 / 3992 | THP compaction failing throughout — a contributor to kswapd wakeups, not the trigger |
| node 1 free with runner-02 stopped | 3.3 GiB (node 0: 16.9) | still skewed: wk-04 sits 6.3 / 25.7 GiB pinned |

So nothing failed to allocate. What swapped was kswapd1 doing its ordinary per-node watermark
maintenance on a node whose only evictable pages were the two unpinned guests' anon pages,
because wk-04's 25.7 GiB there is pinned and unevictable (`VmLck` = the full 32 GiB). That churn
ran overnight with no load — swap grew to 5.4 GiB by morning — and the 397 s stall is then the
swap-in from a 5400 rpm HDD at 98 % utilisation. Any change that restores free or evictable
headroom on node 1 fixes it; THP `defrag` tweaks would not (they govern direct reclaim).

Two consequences the original write-up did not draw:

- **Hugepages is the standard answer for a VFIO-pinned guest.** The installed
  `PVE/QemuServer/Memory.pm` pre-reserves the hugetlb pool per host node before QEMU starts
  (16/16 GiB here for `hugepages: 2` + `numa: 1`) and refuses to start the VM if it cannot —
  balanced capacity, deterministic, fail-fast. `policy=preferred` silently skews again on the
  next restart; `policy=bind` without hugepages makes the pin evict its neighbours to satisfy
  itself. Explicit `numa0/numa1` with `hostnodes` + `bind` on top adds locality. The
  `bpg/proxmox` provider (0.113) exposes all of it (`memory.hugepages`, `keep_hugepages`, the
  `numa` block); `cpu.affinity` needs `root@pam`, so it is not the lever. The "less
  flexibility under pressure" framing of `bind` above is wrong for wk-04: all 32 GiB are pinned
  at start and never move, so the policy matters for one moment only.
  **Applied 2026-09-27, corrected by the apply:** `hugepages` is ALSO `root@pam`-only in
  Proxmox (HTTP 500 *"only root can set 'hugepages' config"* to the automation identity), so
  the shipped form is the `numa` blocks alone with `policy=preferred` — with the pin faulting
  32 GiB in at start, a `bind` on a short host node would swap the other guests out to satisfy
  it. The balance is therefore decided by free memory at start; the belts report a skewed one.
- **Swap on the WD spinner is the amplifier.** pve swaps to NVMe and had no event. With
  dedicated no-balloon guests, nx-02's swap belongs on an SSD (the SA400 going in as the boot
  disk carries it — a DRAM-less SATA SSD still serves random 4k reads at ~100× the HDD's rate),
  or nowhere. The 256 GB Micron has 120 MB of VG free, so an NVMe swap would be a thin LV inside
  the VM pool — not an option.

Two workers instead of one is not justified by NUMA: the per-socket capacity math is identical
(16 GiB of worker + one 12 GiB guest per socket either way), the SN530 passes through to one VM
only, and a second Talos node costs ~1–1.5 GiB of DaemonSet residents. The one real argument
for a split is drain granularity during rollouts; if taken, state it as that.

## The detectors (shipped 2026-09-27, `argocd/resources/pve-metrics/`)

Both hypervisors' node_exporter now runs `--collector.meminfo_numa` and an extended
`--collector.vmstat.fields` (reclaim, compaction, THP), and the textfile collector publishes
per-guest placement — `pve_qemu_numa_resident_bytes{node}`, `pve_qemu_swap_bytes`,
`pve_qemu_locked_bytes` (`ansible/roles/pve-node-exporter/`). Four rules, fixture-tested:

| Alert | Fires on | Replay against the event |
|---|---|---|
| `PveHostSwapUsed` | > 1 GiB in swap for 30 m (warning) | fired ~23:00Z 09-24 — **8 h of lead** |
| `PveHostSwapThrash` | swap-in > 256 KiB/s AND I/O PSI > 5 % for 5 m (critical) | fired through both failing runs (07:24–07:31: 1.0 MiB/s at 20 %; 07:44–07:47: 0.7 MiB/s at 8 %) |
| `PveNumaNodeMemoryLow` | one node's free + inactive file < 1.5 GiB for 15 m | series new — fixture only; live baseline node 1 = 3.3 GiB + 0.1 GiB |
| `PveGuestSwapped` | a guest > 512 MiB on host swap for 15 m | series new — fixture only |

`PveHostMemoryLow` stayed at 9.4 GiB available throughout, as the write-up predicted.

## Experiment that would settle the operational question

Follow the [maintenance procedure](../../.claude/skills/maintenance-window/SKILL.md) for live
changes and the [CI operating context](../ci.md). The detectors above are the first step, done.

Then compare a fresh-start placement policy against the captured baseline under comparable
runner concurrency and e2e load. Budget **all three VMs**, not just wk-04: a hypothetical
16+16 GiB wk-04 split plus one 12 GiB VM per socket totals 28 GiB per socket before host overhead;
that is a capacity illustration, not a validated safe reservation plan. Record actual placement
after startup and under load, swap-in/out, I/O pressure, node-preparation time and e2e results.
Success requires avoiding renewed swap stalls while retaining usable headroom on both nodes.

Treat balanced capacity as the first question and full locality as a separate experiment.
Do not attribute a gain to automatic guest balancing unless kernel support and CPU mapping are
verified. Decide whether that additional operational complexity is justified by measured gains.
The earlier rough remote-memory latency estimate (about 50–80% more for an individual remote
access) is not a benchmark of these machines and is not a whole-CI runtime penalty; it cannot
explain the observed tens-to-hundreds-fold preparation slowdown by itself.

## External grounding

- [Linux NUMA memory policies](https://docs.kernel.org/admin-guide/mm/numa_memory_policy.html):
  default/local, preferred, bind and interleave allocation behavior.
- [Linux NUMA balancing sysctl](https://docs.kernel.org/admin-guide/sysctl/kernel.html):
  automatic task/page placement when supported by the kernel.
- [QEMU memory backends and NUMA topology](https://www.qemu.org/docs/master/system/invocation.html).
- [Intel KVM tuning guide, section 3.2.1](https://cdrdv2-public.intel.com/686407/kvm-tuning-guide-icx.pdf):
  automatic placement and the VFIO pinning limitation.
- [Proxmox per-NUMA vCPU pinning RFC](https://lore.proxmox.com/pve-devel/20260217114813.2063770-1-d.csapak@proxmox.com/):
  proposed functionality, not evidence of support in the installed version.
- [Kubernetes Topology Manager](https://v1-36.docs.kubernetes.io/docs/tasks/administer-cluster/topology-manager/),
  [CPU Manager](https://v1-36.docs.kubernetes.io/docs/tasks/administer-cluster/cpu-management-policies/),
  [Memory Manager](https://v1-36.docs.kubernetes.io/docs/tasks/administer-cluster/memory-manager/).
