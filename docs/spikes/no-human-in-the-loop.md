# Spike — no human in the loop, even for OPNsense / PXE / tofu

**Tracked by:** FU-097 (this is its radical end-state: the "human-applied + belt" column shrinking
toward empty). **Status:** thought exercise, 2026-08-02 — nothing here is built or decided.
**Relates:** FU-012, FU-044, FU-102, ADR-005, ADR-088, ADR-090.

## The reframe

Today's human gate on OPNsense/tofu applies is mostly not *judgment* — a human watching
`tofu apply` scroll by verifies almost nothing. The human is the **rollback mechanism**: hands,
console, physical presence for when a change severs the automation's own path. Every piece below is
a machine-recovery path that replaces hands. Once they exist, the residual human role collapses to
pure *authorization* — and the operator's framing is the right razor: **one node down is not
dangerous; €5000 of cloud/API spend in 15 minutes is.**

Test every change against three questions: *machine-recoverable? bounded? probe-detectable?*
Infrastructure fails mostly on the first — fixable with topology. What stays human fails on the
second or third — not fixable with topology, only with caps and gates.

## The five recovery paths

1. **OPNsense as a CARP pair (VMs on separate Proxmox hosts).** The biggest dependency-cone
   shrink: "router change = network severed, updater dead" becomes "node change = failover event",
   which makes a canary rollout possible — apply to backup → probe (config parses, interfaces up,
   BGP from a test peer, DNS answers) → failover → observation window → apply to former master.
   Deadman = pre-scheduled config restore + failback, cancelled on post-apply health.
   Finesse: skip XMLRPC config sync (ansible applies to each node from git — the brief divergence
   IS the canary state, not drift); no shared storage needed (a dead node is recreated from git,
   not recovered); WAN CARP with one ISP DHCP lease rides a virtual MAC on the VIP; dnsmasq DHCP
   goes active/passive via CARP hooks; HAProxy/BGP VIPs move from IP-aliases to CARP VIPs (an
   ADR-088 ip-plan revision).
2. **A management network** — the key architectural move, more than PiKVM. Rule enforced: *the
   updater's path to its targets must not traverse anything it updates.* A dumb, static, deliberately
   boring switch; static IPs, no DHCP dependency; carries Proxmox mgmt, Talos API, PiKVM, the
   coordinator. Only the Proxmox hosts + the coordinator need dual-homing — workers are already
   cattle whose management interface is the smart plug + Matchbox PXE reinstall (`machines.yaml`
   `remote_power` is the precedent; this adds a `management_path` per box). Honest limit: mid-change
   the updater may lose internet *egress* while keeping its path to machines — acceptable if it
   buffers results and the deadman is local to the target.
3. **PiKVM** — narrower than it looks. Plug-cycle + PXE already recovers every worker; PiKVM is for
   the boxes a reinstall can't recover in one step: the Proxmox hosts and the coordinator (~4 ports:
   one PiKVM + an ezCoo switch). OPNsense-in-VMs gets console via Proxmox transitively.
4. **3× Proxmox + 3 control-plane nodes.** Quorum at both layers turns upgrades into rotation:
   drain → update → reboot → verify → next, with the OPNsense pair and CP VMs anti-affinity-spread.
   The "never `talosctl upgrade` a nocloud VM" rule stops *hurting* rather than stops applying —
   recreating a CP VM is routine when two others hold quorum. Modest used SFF boxes suffice.
5. **A dedicated coordinator (NUC-class, only that job).** Fixes "the updater runs on what it
   updates", and resolves FU-012 naturally: **tofu state + the dangerous creds (PVE root,
   talosconfig, OPNsense API) live on the NUC** — out of the cluster *and* out of the jail. It
   updates itself A/B (NixOS generations + boot-counter/phone-home rollback — the only self-update
   shape needing no second machine). Mutual watching: cluster probes NUC, NUC probes cluster,
   alerts leave by two independent paths.

You cannot fully close the loop: **something is the recovery root and its recovery is manual**
(USB stick in a drawer). The goal is exactly ONE such machine, chosen to have the fewest reasons to
break — no workloads, no storage, tiny config.

## What stays human — authorization, not recovery

| Class | Why no probe/rollback saves you | Gate shape |
|---|---|---|
| **Money** | Spend is irreversible and fast; an outage self-reports, a bill doesn't until it's huge | Not human review of spends — **hard caps at the credential layer**: prepaid/capped accounts, the egress-proxy breaker pattern generalized to every autonomous credential. Human only for *raising a cap* or minting a credential whose worst case exceeds it. AWS is the dangerous one (pay-per-use, no true cap) — automation never holds creds that can create expensive resources |
| **Security-boundary changes** | Wrong = quiet compromise, not loud failure; "now publicly exposed" passes every health check | WAN firewall rules, port forwards, mTLS/WireGuard/tunnel changes (ADR-090 surface) stay human. Everything *behind* the boundary automates |
| **Data destruction** | One-way by definition | Automation may create and detach, never destroy: delete = retain-30-days; actual destruction is human or time |
| **Trust anchors** | The recovery root can't be recovered by what it recovers | The NUC, CA keys, GitHub org admin, Tier-0 KeePass |

Deliberately NOT on the list: **quorum-reducing operations**. "Never take down the second of three;
never touch two failure domains in one window" is policy-as-code, not judgment — most changes that
*feel* human-gated are actually just missing an invariant checker.

The rollout machinery is one shape at every layer — canary → probe → window → promote-or-deadman —
i.e. the FU-044 revert + observation-window pattern extended down the stack. The prober (FU-102) is
the linchpin of the whole exercise: no-human-in-the-loop really means *the prober is the human*.

## Sequencing by leverage

1. Coordinator + management network — makes automation of the **current** topology safe (belts,
   deadman applies, state/cred relocation off the jail).
2. OPNsense CARP pair — biggest cone shrink.
3. Third Proxmox host + 3 CPs — upgrades become rotation.
4. PiKVM — last; only covers what plug+PXE can't.

## What would settle it

- Price + power the delta (2 SFF hosts, NUC, switch, PiKVM) against the budget lens.
- A one-weekend trial of the OPNsense pair on the *existing* single Proxmox host (no host
  redundancy yet, but proves CARP + per-node ansible + the canary/probe/failback machinery).
- The FU-097 ruling table, written with this end-state as the vanishing point: each surface's
  ruling is then "which recovery path is it waiting on", not "automate: yes/no".
