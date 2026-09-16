# 2026-09-16 — nx-01 (and wk-03 before it) rebooting on its own: the `page_table_check` kernel bug

**First symptom:** `NodeRebootedTwiceIn24h` on nx-01 (homelab#1735, 2026-09-16); the interval shrank
from hours to a steady ~15 min through the afternoon, killing every agent ride and CI job on the box.
**Class:** silent kernel panic under CI load — a **software** reboot that leaves no BMC event and no
shipped kernel log, on a node that had just been onboarded as a hardware burn-in, so every reader
(responder, seat, operator) reached for a hardware or sizing story first. wk-03 had the same fault
all the previous week (five "self-reboots", homelab#882) attributed to Proxmox overcommit.

## Timeline (UTC)

| when | what |
|---|---|
| 09-08 → 09-13 | wk-03 reboots 09-08 13:07, 09-10 09:39, 09-10 18:58, 09-11 18:53, 09-12 13:44, 09-13 21:15. Read as VM overcommit on the pve host; 16→8 GiB right-size, `maxRunners` 6→4, a serial console (`serial=true`, PR#1671) added 09-14. |
| 09-15 | nx-01 onboarded into the ARC + kata pools; LeastAllocated scoring sends most runner jobs to the idle 40-core box. wk-03 goes quiet. |
| 09-16 06:40 | nx-01 boot — the BMC power-on (SEL `PEF Action`, BMC clock +7h55m). 09:07: the seat's 08:09 config apply/reinstall. |
| 10:53, 14:12, 14:27, 14:43 | four unexplained nx-01 boots, ~3 min POST gaps; 2–5 ARC runners on the node before each. 13:29 was the seat's planned kata-image upgrade. |
| ~14:5x | seat cordons nx-01; handover written with the BMC SEL named as the one operator-only read. |
| 15:3x | this session: BMC reachable from the jail; SEL empty for the resets; SOL capture armed; Loki kmsg tail before each reset read. |

## Root cause

Loki holds the kmsg-reader's last shipped lines before three of the resets (wk-03 09-10 09:38:44,
nx-01 14:25:03 and 14:40:15), identical each time:

```
kernel BUG at mm/page_table_check.c:143!
Oops: invalid opcode: 0000 [#1] SMP PTI
CPU: 13 UID: 65532 PID: 58799 Comm: crossplane Not tainted 6.18.29-talos #1
RIP: 0010:__page_table_check_zero+0xfb/0x130
 __free_frozen_pages ← free_time_ns ← free_nsproxy ← do_exit
```

The upstream `PAGE_TABLE_CHECK` bug on the time-namespace VVAR page: special PTEs installed for the
vDSO are counted in the per-page map counters, so freeing the namespace's page on the last exit
trips the BUG; Talos runs `panic_on_oops=1` + `panic=10`, so the node is back in POST ten seconds
later with nothing on disk. siderolabs/talos#13496 (June 2026) — the maintainer's analysis and patch
(siderolabs/pkgs#1578, merged 2026-06-09): **Talos 1.13.x/1.12.x ship `page_table_check=off` from
then on; 1.14+ carries the kernel fix.** This cluster runs v1.13.2 / 6.18.29-talos, from before.
The trigger is a process exiting in a non-initial time namespace — here always the `crossplane`
binary (uid 65532) inside an ARC runner job; other reporters hit it on container-build jobs.

Correlation the tables missed: on wk-03 two or more ARC runners are present 7 % of the time over
14 days, yet 4 of its 6 unexplained reboots and 3 of nx-01's 4 had 2–5 runners on the node.

## What was wrong in the reads

- **"No panic in kmsg" is not evidence against a panic.** A userspace reader (`kmsg-reader`,
  `talosctl dmesg`) can never ship the panic itself; only the console (SOL, the pve serial socket)
  or pstore can. The oops *before* the panic was shipped 3 times out of 7 — batching loses the rest.
- **The BMC was reachable all along.** The responder's `TOOL_GAP` was correct for a pod; the seat
  copied it as "operator-only" without a probe. `ipmitool` is now baked into the jail image.
- The SEL carried real hardware facts that were *not* the cause: CMOS battery dead (VBAT 1.16 V,
  threshold 2.43 V — BIOS settings will not survive an AC loss), PS2 "failure" = only PS1 cabled,
  PS1 chronically flaky in the 2021 entries. Worth the hardware register, not this incident.
- wk-03's serial console (09-14) was the right instrument, armed one day before the fault moved
  to nx-01. nx-01's equivalent is `ipmitool … sol activate` — but NOT as first armed here: on the
  X10DRT the BMC's SOL rides the second UART (`ttyS1`, 0x2F8), the v1.13.2 cmdline said `console=ttyS0`,
  and the v1.13.10 metal image drops `console=ttyS0` altogether (`console=tty0` only) — the capture
  saw nothing through nx-01's upgrade reboot. A metal console capture needs `console=ttyS1,115200`
  as an image-factory `extraKernelArgs` (install-time), which FU-247 carries.
- The cilium-agent CPU-throttle / restart loop and the ride kills were symptoms; kata guests cannot
  oops the host, and the three pre-kata reboots rule the kata upgrade out.

## Fix, verified

nx-01 `talosctl upgrade`d to v1.13.10 at 16:00Z (kata schematic kept): kernel 6.18.48-talos with
`CONFIG_PAGE_TABLE_CHECK=y` but `CONFIG_PAGE_TABLE_CHECK_ENFORCED is not set` — the check is off
unless `page_table_check=on` is passed, which Talos does not. wk-metal-02 followed at 16:20Z (its
drain first stalled twice on a runner pod Terminating since its own 09-10 reboot — a Failed pod with
no finalizer the kubelet never confirmed; `--force --grace-period=0` cleared it); wk-03 was shut down
at 16:04Z until its VM is recreated from the v1.13.10 image (PR#1740 splits the declared
version by role: control planes stay v1.13.2 until ADR-133's move, workers declare v1.13.10).

## Residual actions

- **FU-246** — Talos ≥ v1.13.10 on the CI/ephemeral nodes (nx-01, wk-metal-02, wk-03 first); nx-01
  stays cordoned until then. Same action as FU-155's Option A pin, second driver.
- **FU-247** — a Loki-side alert on `kernel BUG at|Oops:` in the kmsg-reader streams: the oops sat
  in Loki from 09-10 09:38 with a node label on it; nothing read it for six days.
