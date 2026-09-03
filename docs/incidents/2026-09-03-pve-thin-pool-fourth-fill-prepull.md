# 2026-09-03 — pve thin pool hit 100% (FOURTH fill): three VMs paused on io-error, the API down ~8 min; the trigger was the new runner-image pre-puller

**Triggers: fourth occurrence of a known, unmetered failure.** [`storage-ledger.md`](../storage-ledger.md)
§"A THIRD sum" and the [2026-08-24 postmortem](2026-08-24-pve-thin-pool-garage-meta-wipe.md) both
name the same gap: **nothing meters the `pve/data` thin pool**, and it is oversubscribed (thin volumes
488 GB on a 353 GB pool). The 2026-08-24 residual — FU-093's "pool Data% metric + alert" — was still
open. This fill was pushed over the edge by the seat's own change that day.

## Timeline (UTC)

- **21:58** — homelab#1364 merged: `runner-image-prepull`, a DaemonSet holding the 4.9 GiB warm-store
  runner image on every worker (`RollingUpdate maxUnavailable: 3`). Purpose: the sentinel's first
  pull per node had cost 429–909 s and failed a run at its 900 s deadline. Pulls start on wk-02,
  thinkcentre, wk-metal-04 concurrently (wk-01/wk-03 already had the image).
- **22:01:06** — wk-02's kubelet posts its last status. **22:05** (pve dmesg, local 01:05) —
  `device-mapper: thin: switching pool to out-of-data-space (queue IO) mode`; **22:06** `(error IO)`.
  Inside wk-02: `Buffer I/O error` on the Longhorn frontend devices, `EXT4-fs … shut down requested`.
- **22:06:52** — wk-02 NodeNotReady. Operator's first symptom: `alertmanager.teststuff.net` 503
  (Alertmanager ran on wk-02, as did the apex cloudflared, ArgoCD's repo server, cf-api-proxy).
- **~22:10** — cp-01 and wk-01 also `qmpstatus: io-error` (their next new-block write): **the API
  server is unreachable** (`192.168.2.51:6443 no route to host`); Prometheus down. Alerting and
  the in-cluster fstrim path are both gone.
- **22:12** — seat pauses the DaemonSet (live patch + the same in git, `3fd6b54f`, pushed).
- **22:13:58** — pve: `lvextend -L +1000M pve/data` (the VG's whole free 1 GB) → `switching pool to
  write mode`; `qm resume 8101/8111/8112` → all three `running`. **22:14** — API back; cp-01, wk-01
  Ready; wk-02 recovers on its own within ~2 min (kubelet/containerd never died; the guest EPHEMERAL
  XFS was untouched — only Longhorn PVC filesystems hit errors).
- **22:14:30** — fstrim jobs created from the daily CronJobs (cp-01, wk-01, wk-03): wk-01 89.40→47.19 %,
  wk-03 86.03→48.28 %. **22:14:43** — operator ruling "CI VMs are sacrificial": `qm destroy 9001`
  (ci-runner-01, 63 GB allocated) → pool 100 → **74.09 %**. **22:16** — fstrim wk-02 (236 GiB of
  discards issued) → pool **64.34 %**, wk-02 disk 74.31→68.32 %.
- **22:17→** — Longhorn re-attaches; volumes degraded → rebuilding; Prometheus/others re-scheduling.

## Root cause

**The thin pool has no headroom policy and no meter.** 408 GB of thin volumes (after ci-runner-01's
removal; 488 GB before) sit on a 353 GB pool; the VG had 1 GB of free extents, so dmeventd
autoextend (armed 2026-08-07 at 80 %) could not act — exactly the 2026-08-17 failure. Guest-side
deletes do not return blocks until the daily fstrim runs at 03:00, so intra-day allocation is a
one-way ratchet. The **trigger** was a 4.9 GiB image pull onto wk-02's 240 GB thin disk (the image
store shares the guest EPHEMERAL partition), started by the pre-puller's first rollout — a platform
change whose headroom check looked at guest free space (88 GiB on wk-02's `/var`) and **not at the
pool underneath**, which is the sum that actually runs out.

## Collateral

- ~8 min API outage (single control plane, on the same pool); Alertmanager + Prometheus down, so
  the incident had **no alert** — the operator noticed a 503.
- Longhorn: every volume with a replica or frontend on wk-02/wk-01 went degraded/unknown; rebuilds
  ran for tens of minutes; pods on those PVCs (Garage, Forgejo/PG, Infisical/PG, Grafana/PG, Loki
  eventbus, registry, nix-cache, mirrors) restarted.
- **ci-runner-01 destroyed** (operator-authorized, sacrificial): tofu drift on
  `proxmox_virtual_environment_vm.ci_runner` (`tofu/ci-runner.tf`) — recreate or retire is FU-207.
- The pre-puller stays paused (nodeSelector no node carries) until FU-208 sets its rollout shape.

## Fixes (live, same session)

Pool extended by the VG's last 1 GB; VMs resumed; four fstrims; ci-runner-01 destroyed → 64 %.

## Probe lesson

When a pve VM goes NotReady and its Talos API is "no route to host", the first two reads are on
the hypervisor: `qm status <vmid> --verbose | grep qmpstatus` (`io-error` = paused on a failed
write) and `lvs -o lv_name,data_percent pve` — before any guest-side theory. And the headroom
check for anything that writes gigabytes to a VM node is the **pool's** free space, never the
guest filesystem's.

## Residual

- **FU-093** — the pool Data% metric + alert: fourth fill, still unmetered; now the blocking
  next act (pve is not scraped; a pve-side exporter/textfile into Prometheus, as code).
- **FU-207** — ci-runner-01: recreate from tofu (runner re-registration) or retire ADR-082's VM lane.
- **FU-208** — runner-image-prepull rollout shape: thin-pool VMs excluded or serialized behind a
  pool-headroom check; the 4.9 GiB image itself is oversized for what the sentinel needs.
