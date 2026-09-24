# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid — and every design-agents corpus load pays it too: at 75 KB this file cost
~20k tokens per corpus session before the 2026-09-05 prune. A wind-down writes the PICKUP,
never the session's arc — that is TICK-LOG's.)


## Live state (pruned 2026-09-05, the corpus-cost sitting — every item live-verified against the board that day; history is TICK-LOG's; the forward plan is the ROADMAP work map)
- **⚑ PICKUP (2026-09-24 — the basement drive session; arc in TICK-LOG).** All three drive windows
  are CLOSED and verified: 13/13 Ready, etcd 3/3, 0 degraded, rebuild timer back at 600,
  `mgmt-tf` baseline stamped at `a4cc12bb`. Nothing is half-applied. **Operator ruling on what is
  next: the registry2 experiment (FU-280), not the scratch rearrangement** — registry2 is upstream
  (it unblocks FU-274, which shrinks the 150Gi ghcr mirror = the biggest `bulk` tenant), and its
  tier blocker is gone because the SN530 pair now sits in hp-01 + nx-02 for exactly that. Operator
  is undecided whether those drives later become a bulk tier, so **do not coin a permanent tag or
  hostname yet** (the spike's own naming trap; a glossary row is owed on coining, FU-163).
  Order for that session: (1) the CHEAP side-question first — does a Garage server-side COPY share
  blocks or duplicate them? If it shares, the 2x peak is a quota artifact costing no disk and
  "raise the cap" beats changing backend; ~15 min, and building before it risks building the wrong
  thing. (2) the **selector-less StorageClass audit** (`longhorn-local-xfs`, `longhorn-static` have
  no `diskSelector`) — a hard blocker shared with the scratch work, so it is paid once here.
  (3) phase 1 only, no DNS/cert/VIP. The scratch plan waits in
  [`storage-ledger.md`](../storage-ledger.md) §the scratch class rides `bulk` (FU-234); nx-01's
  freed 7600p is idle but safe — nothing degrades while it waits.
- **⚑ PICKUP (2026-09-23 late — the mechanical FU sweep; arc in TICK-LOG).** Six PRs merged
  (#1946/#1947/#1948/#1949/#1950/#1951) plus the parked spike #1905. Three things a fresh session
  should expect rather than chase: (1) **`KernelOopsCaptured` is firing on wk-03 by design** — two
  synthetic probe lines, silenced in Alertmanager to ~04:30Z, self-clears ~6 h after the last
  injection (~04:00Z). (2) **`MgmtBeltCheckFailing` will fire on `check="talos"`** once the box
  picks up #1950 — that is FU-286 (devbox cannot resolve talosctl past 1.13.8 while the fleet runs
  v1.14.1), not a new fault; it clears when the pin moves. (3) **FU-287 needs a decision** —
  every Alloy restart re-counts old oops lines (positions on an emptyDir), so the new belt re-fires
  after any config bump; the fork is a hostPath positions dir (DaemonSet change) vs a
  restart-insensitive rule. Also open from this sitting: GAPS `maintenance-window-G4` (a window
  opened to prove a detector fires cannot close — `--force` is the only exit).
- **⚑ PICKUP (2026-09-23 ~10:30Z — write-back-is-the-store LIVE and proven; arc in TICK-LOG).**
  DONE this sitting: PR#1933/#1936 (play), #1934 (theme #1768 assembly, CLOSED), #1932 (token broker
  503 + retries + two masked export-guards), #1929 (rails assembly), #1931 override, #1916. The store
  on #1640 carries `last-checkpoint:` (09:51Z ride) — the play holds. OPEN: (1) #1651 closes by hand
  when #1908 reaches master via theme #1907's assembly (#1910 stays unqueued, operator: later).
  (2) **FU-281** = the trigger side, operator's — finding 36 on #1640's store is the ride's own
  "woke for nothing" diagnosis, evidence for it. (3) #1905: fix ADR-080 → ADR-091 at the spike's
  line 41. (4) `GoalTimelineNoisy` is live — a firing means per-ride prose came back; read the authors.
  (5) Next rollout is the first with the FU-278 workload-health hold (unchanged from 09-22).
- **⚑ PICKUP (2026-09-22 late — retro r5 + Goal #1906; arc in TICK-LOG; items (2) and the #1768 tail are RESOLVED above).** (1) **Goal #1906** (retro r5's
  batch container, themed): #1908/#1909/#1911 queued; **#1910 is authored and UNQUEUED on purpose** —
  it un-banks chainless-redesign's rung-0 corollary (b) for the no-op-after-directive case; the
  operator reads Goal pin 3 and queues it (`agent/queued`) or rules it deferred on the store. Theme
  #1907's assembly (`goal/1906-scan → master`, `Fixes #1907`) is the ONE codeowner read; acceptance 5
  (FSM rows, brief paragraphs, the charter note) rides it. (2) **Subagent outcomes to verify** (they
  report to the seat; if this file still says so, read the threads): PR#1792 merged + #1781 closed +
  theme #1768's assembly PR open (`Fixes #1768`, parks on `agents/**` for the seat's read); Goal
  #1769's #1768 edge removed + theme #1770's members filed and queued. (3) #1651 closes by hand when
  #1908 lands (lineage rule 5 — it stays under #1101). (4) r5's ADR-103 trigger (bucket-A not falling
  two weeks → revisit label-carried loop state) is the operator's design sitting — recorded on #1906.
- **⚑ NEXT (2026-09-22 evening — pickup list done; arc in TICK-LOG).** Garage PDB #1882 LIVE + tested on
  m70s; FU-264 CA rotated in production; FU-195/FU-276 landed. Open: (1) FU-278 LANDED (#1891, 15:41Z) — the next rollout is the first with the workload-health hold. (2) **Operator:** check
  pop-os `~/.talos/config` for the dead identity; #1882's "3 flagged choices" (never recorded). (3)
  FU-277 next step (drop the DHCP search on nodes? + an in-cluster DNS detector). (4) FU-097: ledger section in
  #1893; the **intent-review instruction is DRAFTED for the operator** (`.agents/review.md` is
  operator-direct), proposed as a bullet under "Judge these carefully": *"On a surface the box
  applies on its own (management-box.md §The capability ledger: the main-root allowlist, Talos
  versions, Talos config), your read replaces the codeowner read, so review INTENT: does the plan +
  install-impact line do what the linked issue asked, given what the fleet and the box already run
  (a version skipping the canary type, a config that needs a reboot under `no_reboot`, a CP change
  while the CP toggle is off)? Intent and plan disagreeing is BLOCKING even when every check is green."* Stack-side: oracle-fleet#698 waits for a codeowner read.
- **⚑ PICKUP (2026-09-20 evening — oracle handoffs + devbox pin; arc in TICK-LOG).** (1) **PR#1810 MERGED 18:18Z** — the
  arc-runner pin is `2026.9.20-gd4aab3d8146a` (devbox 0.18.3), so Monday's 03:00Z `devbox-update`
  should write `plugin_version` 0.0.5; a PR flipping `nodejs_22` back to 0.0.4 means a runner was
  still on the old image — close it, do not merge (FU-240). claude-jail `6f90815`
  (`DEVBOX_USE_VERSION=0.18.3`) is committed locally there, unpushed beside the operator's own
  commits — needs their push + a jail rebuild; the host profile wants the same export.
  (2) `fixer.imageVolumes` is LIVE (#1808, ADR-135) but NO claim declares it — oracle adds it in
  oracle-iac (SHIPPED note in their `done/`); first real ride with `/corpus` mounted is unobserved.
  (3) Oracle inbox still holds 7 handoffs from 09-08..09-16, untouched. (4) `merged-closeout` reads
  `.agents/closeout.md` (#1806, ADR-134) — the first oracle closeout under it is unobserved;
  oracle-fleet#637 is still CLOSED with nothing in prod (theirs to reopen).
- **⚑ PICKUP (2026-09-21 ~14:00 — pve GPU swap: DONE; arc in TICK-LOG).** pve runs HEADLESS (no
  GPU; x16 + x1 free — storage-ledger §hypervisor). Operator-only: the CMOS clear reset "Restore on
  AC Power Loss" — read it next time a card is fitted, else pve stays dark after a power cut.
  Unexplained, seen once: argocd-dex-server segfault (139) on hp-01, runs fine on wk-04.
  **CNPG replica-1: DONE 2026-09-21 16:00Z** (#1843; all six platform PVCs on
  `longhorn-local-std`, primaries now on m70s). FU-137's next = the backup CronJob. oracle-pg is
  oracle's (stays r2 until the zone list is a label).
- **⚑ PICKUP (2026-09-21 ~11:40 — the Talos rollout: DONE; arc in TICK-LOG).** All 13 nodes on
  **v1.13.10** (one os_image; `TalosFleetVersionSplit` resolved before its 09-22 08:00Z fire). #1836
  applied (0 replacements / 0 PKI); `upgrade-behind` ran on the box as transient units: cp-02, cp-01,
  then m70s → hp-01. Three fixes landed on the way: #1838 (a pure CP has no Longhorn to wait for),
  #1839 (**drain BEFORE the install** — each workload's PDB + controller fails itself over, CNPG
  switched 3+2 primaries unaided; preflight WARNs informational in `upgrade`; floors never
  FORCE-able), and the transient-unit recipe needs `--setenv=PATH` (docs/provisioning.md).
  **NEXT:**
  (1) **FU-264** — rotate the Talos API CA, now that the rollout is done; the spike says probe the
      state half on the lab CP first.
  (2) **FU-265** — wk-metal-04's firmware `Boot0008` breaks every future `talosctl upgrade` of it
      (it finished today by a planned reboot); firmware-setup delete + the public upstream issue are
      the operator's call.
  (3) Observation, single sighting — detector-first if it recurs: homelab CI's crossplane render
      failed at 10:28Z on `192.168.40.21` (ghcr mirror VIP) "no route to host", the minute cp-01
      rebooted and cilium-operator was evicted. Rerun green; VIP answered at 10:55.
  (4) Operator question still open: box metrics transport = node_exporter scraped as a static
      target like the hypervisors (FU-252) — RULED yes, and live 2026-09-21 (#1850).
  `GarageZoneDegraded` LIVE 2026-09-21 (#1849).
  ⚠ Host-side git prunes scratchpad worktrees mid-session and the jail's known_hosts is not durable —
  pin the box key from the wallet (`homelab-mgmt/extra-files/etc/ssh/*.pub`), never TOFU.

- **⚑ PICKUP (2026-09-18 session — two waits, both cheap, both easy to lose).**
  (1) ~~#4b flip~~ DONE 2026-09-21 (enforcing after #1755).
  (2) **Monday re-check: the reviewer's first-round deferral** — the defect where sonnet reports a
  PR's first-diff blocking findings in round 3 or 5 instead of round 1. Came up in the retro and was
  partly fixed there; the operator's read (2026-09-18) is that it should REAPPEAR, so the Monday
  board is the observation. No tracker item by design — the retro owns it. If it reappears, that is
  the second sighting, and the reshaped second-reviewer candidate in the A5 pile is where it would
  pay ([`iac-lane.md`](iac-lane.md), the governance-checkpoint section).

- **⚑ PICKUP (2026-09-17 corpus session — the responder rebuild's second half; arc in TICK-LOG).**
  Six PRs, all MERGED: **#1748** (the triage-routing filter), **#1749** (§A1 capture), **#1750**
  (declared window + human-close + the crosscheck's pause line), **#1751** (KubeJobFailed replaced
  — see the separate bullet), **#1752** (replay: a recorded world is read-only to a run), and the
  codeowner read on the parked **#1738** (model_id strip hoist — bot-approved since 09-16). The lane is still PAUSED (FU-249), so
  NOTHING below has been observed live — each item is a read to run at un-pause.
  (1) **At FU-249's un-pause (≈09-23), in this order:** delete the never-matching `alert-dep` filter
  in `responder-argo.yaml` (one revert); then (a) `responder_triage_sessions_today` for a day — it
  should sit well under the 11–12/day ceiling of the 09-11→16 window; (b) `kubectl -n
  agent-coordinator get cm responder-seen -o json | jq '[.data|to_entries[]|select(.value|
  startswith("none-") or startswith("window-") or startswith("humandecided-"))]|length'` — the
  three new deliberate-stop markers; (c) ONE prefix end-to-end
  (`devbox run garage-s3 s3 ls s3://agent-transcripts/homelab/ --recursive` — the `homelab/`
  prefix does not exist yet, verified 2026-09-17, which is FU-231's own blocker restated) — **that is FU-210's acceptance**,
  and specifically: a report-only session that files no issue must still leave a readable decision;
  (d) run one real `node-maintenance` window and confirm the DaemonSet-rollout class costs no
  session — **FU-230 leg (b)'s acceptance**.
  (2) **FU-231's switch is NOT flipped and one finding says it cannot be as sketched** — report-only
  issues are DECIDED-ONCE's anchor, and moving that anchor into the bucket needs a pod READ the
  write-only transcripts key will never grant. Two independent next legs on the FU: the jail-side
  `triage` meta-events source (reader key), and re-reading the switch with finding records in hand.
  (3) **Standing local branch residue:** `fix/responder-decide-once` is a stale local branch from the
  PR#1733 session (merged by squash, never pushed) and holds a worktree at another session's
  scratchpad path — it blocked a branch name this session. Prune at the next hygiene pass
  (meta-state §Hygiene already lists stale agent branches).
  (4) Not acted on, worth one read: `KubeJobFailed` fired 45 series in `node-maintenance` during the
  09-16 worker replacements (the per-node `fstrim-guard-*` CronJobs failing while their nodes were
  down) — expected during a window, but it is the class a declared window does NOT cover, and adding
  `KubeJobFailed` to `DECLARED_ALERTS` was rejected as too broad (it would mute every Job failure
  fleet-wide for the window). The narrower fix, unbuilt: the guard should skip a cordoned node.

- **⚑ PICKUP (2026-09-17, same session — the alert-quality tail; two reversals worth re-reading).**
  (1) **`KubeJobFailed` REPLACED (PR#1751)** after the operator caught what #1748 had got wrong: the
  stock rule reads a Job OBJECT, so on a CronJob it clears only by failing MORE
  (`garage-write-probe`: 2 failures, 776 successes, still firing 13.5 h later). Now
  `argocd/resources/job-health/` — `CronJobNotSucceeding` (cadence-derived from
  `next_schedule_time - last_schedule_time`, self-clearing), `CronJobNeverSucceeded`, and a
  `KubeJobFailed` narrowed to Jobs no CronJob owns. Verified end-to-end: the three stale alerts aged
  out of Alertmanager by themselves at 08:56Z, no Job objects deleted. **Watch at the next sitting:**
  the first real `CronJobNotSucceeding` fire — the 600s floor × 3 intervals is an authored number,
  and the honest re-read is whether a weekly job's 21-day threshold is tolerable or wants its own
  belt (`RegistryGCMirrorsStale` already covers gc-mirrors).
  (2) **Replay hermeticity (PR#1752):** a bridge that derives a world file wrote into the COMMITTED
  `world/` dir — `$REPLAY_WORLD` is the fixture's own dir unless a registry world is in play.
  `run.sh` now hashes every world file before/after a run and reds if any moved. Nothing to pick up;
  recorded here because the class is easy to re-introduce.
  (3) **#1737 closed on evidence** (the `diff-ci` `agentstack-rbac-lint` map row exists on master;
  `diff-ci` exited 0 on four branches today) — it was real when #1738's ride hit it on 09-16.
  (4) **Standing residue, unowned:** `fix/responder-decide-once` is a stale LOCAL branch from the
  #1733 session (squash-merged, never pushed) holding a worktree at a dead scratchpad path — prune
  with the rest of the stale-branch hygiene list.

- **⚑ PICKUP (2026-09-16 ~16:25Z) — the page_table_check reboots: FIXED on the ARC metal nodes, wk-03 DOWN, PR#1740 open.**
  **Update 19:25Z:** responder PAUSED (PR#1746 → FU-249, re-enable ≈09-23); all 21 open alert issues
  closed on substance; platform back. The remaining plan on the main root = 7 metal config updates + taint
  noise → the box loop refuses until a human applies them (`-exclude`-shaped, never `-target`).
  **Update 18:55Z: wk-01/02/03/04 ALL on v1.13.10** — wk-03 by design, the other three by the seat's
  targeted-apply incident (`docs/incidents/2026-09-16-targeted-apply-replaced-three-vms.md`, FU-248): no data
  lost, ~12 min platform outage, recovered via `tofu console` + `talosctl apply-config --insecure`. Tofu's
  `talos_machine_configuration_apply.node[wk-01|02|04]` state is stale-but-harmless (static id); the
  remaining plan = 7 metal config updates + taint noise. Do NOT `-target` anything on this root.
  **Update 18:10Z: ALL THREE MERGED** — #1733 (responder), #1742 (FU-215 belt), #1740 (version split, incl.
  the image-axis fix). **Next act = wk-03's recreate on v1.13.10**, human apply by target from the box
  (`devbox run mgmt-tf -- apply -target='proxmox_download_file.talos["longhorn-v1.13.10"]'
  -target='proxmox_virtual_environment_vm.node["wk-03"]' -target='talos_machine_configuration_apply.node["wk-03"]'`)
  — READ THE PVE THIN POOL FIRST (`pve_lvm_thin_pool_data_percent`, the 2026-09-03 rule); the box loop
  refuses master until the whole plan is human-applied (VM replaces wk-01/02/04 stay pending, one at a
  time). Three seat silences (`seat/wk-03-down`) cover wk-03's absence until 2026-09-17 02:03Z — expire
  them when it is back. Remove image.tf/nx02.tf `moved` blocks in the PR that next moves a version.
  Cause: siderolabs/talos#13496 (incident `docs/incidents/2026-09-16-page-table-check-reboots.md`),
  not the hardware. nx-01 + wk-metal-02 run v1.13.10 (verified) and are uncordoned; **wk-03 is shut
  down on purpose** — do NOT `node-maintenance up wk-03`; its path is the VM RECREATE from the
  v1.13.10 image (`mgmt-tf apply -target='proxmox_virtual_environment_vm.node["wk-03"]'` + its
  machine-config apply) once PR#1740 merges. **PR#1740** (two version variables by role; sentinel
  plan = 4 worker-VM replaces + 7 metal config updates + the taint noise, all human-apply) waits on
  the reviewer + auto-merge (squash armed); the box loop refuses until a human applies — apply by
  target, one VM at a time (FU-246). FU-247 = alert on captured oopses + the console half (BMC SOL
  is `ttyS1`; the v1.13.10 metal image ships `console=tty0` only). The three-CP program (ADR-133,
  FU-243) is deferred to its own session by the operator; the laptop CP is `wk-metal-02`
  (SETTLED 2026-09-20, ADR-133 amendment — `wk-metal-03` stays a ride node). **Upgrade-path
  update (2026-09-20):** PR#1778 merged `devbox run cp-upgrade -- <node>` on the management box;
  an isolated nx-02 one-node lab proved Talos v1.13.2→v1.13.10, then was destroyed. FU-243 now
  carries the post-join one-member-at-a-time convergence step; `controlplane-lab-install.sh` is
  only the independent rehearsal-cluster installer, not the production join path.


- **⚑ PICKUP (2026-09-16 corpus session — the responder rebuild; arc in TICK-LOG).**
  **PR#1733 open + armed, CI running at hand-off** — four deterministic legs in
  `responder-argo.yaml`: human-close guard, decided-once gate, REST engagement probe, FU-232
  subject re-key. `agents/**` so it parks for the codeowner read; **FU-232 archived in the PR**.
  (1) **Verify after merge, in order:** the next `respond-*` run's log carries `DECIDED —` or
  `HUMAN-CLOSED` lines rather than a session per standing alert; `kubectl -n agent-coordinator get
  cm responder-seen -o json | jq '[.data|to_entries[]|select(.value|startswith("decided-"))]|length'`
  is non-zero within a day; `responder_triage_sessions_today` drops off its 11–12/day ceiling.
  (2) ⚠ **One-time cost is EXPECTED, not a regression:** the FU-232 re-key retires the magnet
  threads, so each affected (alert, object) files ONE fresh issue on its next fire (#811/#882/#542
  kube-state, #241 pushgateway, #103 node-exporter, #884 `ns:monitoring`). Do not read that burst
  as the fix failing.
  (3) **Still open on the responder side:** FU-230 leg (b) (re-weighed non-binding — build when a
  SECOND window class leaks) and FU-231's bucket (**BLOCKED on FU-210** — responder sessions leave
  no transcript, the `homelab/alert-<fp>/` prefix is empty). Re-read FU-231 after this soaks.
  (4) Board drained seat-side: #1546/#530/#1547 closed (alert cleared, zero human engagement);
  open 🚨 24 → 21. Of the 17 open-with-cleared-alert threads, only 3 qualified for an unattended
  close — the other 14 have genuine human comments, so the `[bot]`-suffix bug's blast radius was
  smaller than the 13 `A human is engaged` body lines suggested.
  (8) **PR#1733 MERGED 2026-09-16 17:33Z** (squash c8c1395b) — the (1)–(3) verification list above is now live.
  (6) **Codeowner reads executed this session (ADR-110) — the PR board:**
  **#1698** (`estimate_budget`: price `:exacto` as its base id) APPROVED — a price-lookup defect,
  not budget semantics; miss-driven retry so `:free` never degrades, unknown models still escalate.
  The updater refreshed it 14:00Z, CI re-running. **#1715** (scan: honour a CLOSED fleet-strike
  filing inside the 24h window) APPROVED — ends the "a strip re-latches within a tick" freeze the
  oracle five sit under; its author filter (only the loop's own bot may author the `issues=` marker)
  is the load-bearing guard on a PUBLIC repo and tick 6 pins it against a spoofed world. Still
  BEHIND — one updater slot per (repo, base) lane per pass.
  (7) **PR#1699 CLOSED, #1692 re-scoped** (merge-conflict clause, close-and-re-queue): never
  bot-approved, and the conflict (`docs/follow-ups.md` + `docs/glossary.md`) was in files the sweep
  should not have touched. The bare-`§M` sweep matched `§M`+LETTER — `§MB1`/`§MB3`/`§MVP`/`§MODEL`/
  `§Model class` — leaving the management sentinel's glossary row pointing at
  `model-routing-history.md`; the rewrite shape pasted a bare path beside an existing link; and it
  changed 48 files against a 4-doc `Touches:`. Corrected directive posted on #1692.
  ⚠ **#1692 is NOT re-queued on purpose**: its `agent/error` is the fleet-strike latch, so a strip
  re-latches within a tick until **#1715 merges**. Strip `agent/error`+`agent/blocked`, add
  `agent/queued`, AFTER that lands.
  (5) **Quickfix landed direct:** `devbox run diff-ci` was failing on master for everyone (no
  map row for `agentstack-rbac-lint`); `scripts/**` is codeowner-author so PR is not a route.
  Bookkeeping is COMMITTED, **not pushed** — one master push at wind-down (the 2026-08-30 rule).

- **⚑ PICKUP (2026-09-15 night — nx-02, unattended run).** Box facts live in the private
  **hardware** repo `docs/nx-6035-g5.md` §"nx-02 put to work"; the arc is in TICK-LOG.

  **DONE tonight:** nx-02's BIOS boot order (`Hard Disk` #1, `Network` #2 — a mounted BMC virtual
  CD can no longer hijack a boot; SOL driver at `pve:/root/bootorder.py`); the stale
  `nvme0n1-thin` storage removed and the surviving pool renamed device-independently to
  **`nvme-thin`**; a tofu API token minted (KeePass `nx-02-api-token-tofu`, on the box via
  `mgmt-provision-secrets.sh --push`) and the pve SSH seed key authorized; **PR#1719 merged** —
  nx-02's thin pool is metered end-to-end (`pve_lvm_thin_pool_data_percent{host="nx-02"}` live in
  Prometheus, `PveMetricsAbsent` now one arm per host); **nx-01 added to `bgp_node_ips`** (736167cd
  — it was never added at onboarding, peer `idle`; ⚠ NOT verifiable as `established` until nx-01
  boots).

  **PR#1718 + PR#1717 APPLIED 2026-09-16 ~08:00Z (operator: "one big apply").** wk-04 (VM 8114 on
  nx-02) is Ready, zone `nx-02`, untainted, BGP `established` (playbook run); nx-01 carries the
  ephemeral taint + its cordon, BGP `established`. The apply loop's baseline is stamped at master
  (PR#1721's stamp works). ⚠ **nx-01 was NOT reinstalled by this** — `talos_machine_configuration_apply.metal["nx-01"]`
  applied in place (0 s); the wipe/reinstall onto the NVMe is the Matchbox path (the `nx-01-diag`
  group is committed now, f844711a; transient — remove it post-install). **Standing plan noise:**
  `kubernetes_node_taint.ephemeral["nx-01"]` wants to drop `node.kubernetes.io/unschedulable` (a
  forced SSA read-back — FU-235 (2); do NOT apply that resource with force). nx-02's
  `TerraformProv` role gained `VM.GuestAgent.Audit` (the 403 warning on the VM's agent read).

  **Also open:** `nx-01` is still powered off and cannot see a boot disk (untouched tonight, per
  the handover); **PR#1717** (`fix/nx-01-ride-box`) is MERGED (8e39f029) but NOT applied — applying
  it wipes nx-01 and targets the ADATA that does not enumerate. **FU-235 is still stale** (says the kata pool
  is 2; live it is 4) — close it on evidence. `wk-metal-02` recovered on its own (Ready again).

  **Do NOT re-derive:** the Matchbox profile sets `console=ttyS0` (COM1) but these boards have COM1
  disabled and COM2/SOL enabled (= ttyS1), which is why Talos is invisible over SOL on both nodes
  while BIOS output shows fine. A `console=ttyS1,115200` kernel arg would fix it.

- **⚑ PICKUP (2026-09-14 midday session — the box + wk-03 window; arc in TICK-LOG).**
  (1) **Box hand-advance DONE** — gen 4, `mgmt-pull` hourly live (first tick advanced to
  115794f4, no re-activation). `scripts/mgmt-tf.sh` fixed (positionals never crossed the ssh hop)
  — batched, pushes at wind-down. (2) **wk-03: serial console LIVE + 8Gi/6c + maxRunners 4**
  (PR#1671 merged, 115794f4 direct). **The next self-reboot's panic is in
  `root@192.168.2.3:/var/log/qemu-serial/8113.log`** — read it FIRST when `NodeRebootedTwiceIn24h`
  / `NodeRebootingRepeatedly` (#1663) fires; then the fix, on #882. (3) **PR#1674** (settle waits
  for busy ARC runners) — armed, verify merged. (4) **#1675 pool**: manual trims took it to 69 %;
  the fixer's target should be trim CADENCE (steer posted), not the replica RecurringJob; re-read
  `pve_lvm_thin_pool_data_percent` — if it climbs past 85 % before the fix lands, kick
  `create job --from=cronjob/fstrim-wk-02` again. (5) **wk-02 std disk (allowScheduling=false)
  still holds four r=1 `coordinator-transcripts` volumes' ONLY replica** (sleep/circles/platform/
  agent-coordinator) + agent-uv-cache's second copy — operator placement call (std = m70s + hp-01
  only); `node-maintenance.sh move wk-02 <volume>` is the recipe. (6) **OOMController on the VM
  tier** (wk-02 09:15Z, 11 kills, instance-manager first — #1672 class B; wk-metal-03 #1664) —
  FU-155's tune-vs-accept ruling is where it lands; VMs are outside the pin experiment.
  (7) **Responder pass done** (operator-scoped, no sweep): #114/#811/#1013/#542/#100/#261/#121/#153
  closed on substance; **PR#1678** (Argo controller `writeConfigMaps` — oversized responder payloads
  died silently) + **PR#1679** (Prometheus maxConcurrency 40) armed — verify merged, then
  `kubectl auth can-i create configmaps -n agent-coordinator --as=system:serviceaccount:argo:argo-workflows-workflow-controller`
  → yes. Still open on the responder side: #1546 (oracle items footprint-held — stack lane),
  #241 (oracle prune dry-run — stack lane), #857/#103 graft threads (reads only).
  (8) **wk-02 = compute-only DONE, disks DONE (2026-09-14 midday):** wk-02 recreated at 80 G,
  wk-03 grown to 80 G, cp-01 at 12 GiB (#1687), VM kubelet image GC 60/50 live, pool 37 %.
  Verify at the next sitting: PR#1689 + PR#1691 (proxy: transient ref-resolve → 503, no cred
  count — the #1620 round-2 strike was the cp-01 blackout) merged and the proxy rolled;
  PR#1690 (TTL 2 d) MERGED; `kubectl get wf -A | wc -l` trending
  down from ~800 (the 2 d TTL); no cp-01 `allocatableMemory.available` eviction in 24 h → close
  #1687; #1675's fixer targets trim cadence; wk-02's image store stays under 50 % of 75 G.
  (9) **PR#1676 (the #1621 doorbell) codeowner-merged at wind-down** — #1621 stays open for the
  live acceptance (the next oracle corpus publish rings `/corpus-published` → `release-corpus.yaml`
  runs on `repository_dispatch`); the generic `/dispatch` knob is banked on #1621 for a second
  publisher. Four fixer items queued by hand (#1675 #1594 #1664 #1672) — watch their rides.
  (10) Unchanged from the late-morning pickup: theme 1 queued (#1665–#1669, first ride reads
  `exacto:no-pin`); fleet un-latched; #1237 re-home question at the next sweep; oracle-fleet
  PR#591/#395 human-directive path; #1651 unqueued.
- **⚑ PICKUP (2026-09-14 evening handoff/board session — no corpus load; arc in TICK-LOG).**
  (1) **#1692 DONE** — PR#1699 abandoned (the bare-`§M` over-match), split into PR#1753 (the
  rewrite, merged 09-17) + #1710/PR#1755 (the pointer sweep, OPEN). The shim's docstring pointer
  landed operator-direct 2026-09-18 with the check-#4b ratchet below; #1710 closes when PR#1755
  merges. (2) **PR#1698 codeowner read** (#1670,
  bot-approved after two rounds, CI green, BEHIND) — the corpus-loaded seat merges it; #1697
  unparks by itself. (3) **#1713** pin-only-lint's merge-ref two-dot (operator lane, sibling of
  fadb0ff6). (4) **oracle-fleet#605** (ErtPipeline rules on the Argo counter) in the oracle
  reviewer's hands; #604 item 3 after the chart rolls. (5) **Garage capacity**: the 150 GB
  ert-delta ask is the SFF zone-disk item (ledger §"Garage bucket quotas vs the layout");
  cheap interim = move the PyPI + mcr mirror volumes off wk-metal-04 `intel1` (258 GB scheduled
  on 256) — not filed, operator's call. (6) Still the operator's: #1669 stays blocked until
  theme 1 deploys + ≥2026-09-20.
- **⚑ PICKUP (2026-09-14 afternoon, same session — wound down at ~600k ctx; arc in TICK-LOG).**
  (1) **PR#1652 (mgmt box follows master, ADR-129 amended) MERGED 08:3xZ (bd74bdd4)** — the box
  is still on the OLD generation (timer disabled, pull ref absent), so nothing moves until the
  hand-advance; safe as it sits. **The box, next seat:** its checkout still points at the
  absent `mgmt-release`, so ONE hand-advance over the `mgmt-tf` ssh path (`scripts/mgmt-tf.sh`
  shape, root@192.168.2.53): `git -C /var/lib/homelab fetch origin master && git reset --hard
  origin/master`, `nixos-rebuild test --flake /var/lib/homelab/nixos#mgmt`, let `mgmt-confirm`
  gate + `boot`; verify `systemctl list-timers mgmt-pull` armed and the first tick's journal
  ("advanced the checkout" / "already at"). (2) **PR#1654 (NodeRebootedTwiceIn24h +
  NodeRebootingRepeatedly)** — armed, CI + bot, no park; verify it merged and the 7 d rule fires
  on 192.168.2.63. (3) **wk-03 serial console — NOT started (the #882 next act):**
  `serial_device {}` on wk-03 in `tofu/proxmox.tf` (conditional per node, the ci-runner.tf
  shape) + an Ansible role `pve-serial-log` (socat template unit on pve → /var/log/qemu-serial/
  <vmid>.log; the guest already has `console=ttyS0`); apply via the box (`devbox run mgmt-tf --
  plan`); the fix follows the first captured panic. Probe results on #882. (4) **#1620/#1621:
  strip `agent/error` after 14:51Z** (the 09-13 strikes age out of the reader's 24 h window; a
  strip before that re-latches within a tick). (5) **PR#1650 MERGED 08:00Z** — caps live (xs
  0.50 / sm 1 / md 2 / lg 4 enforced, selection unchanged); the ledger mirror + 6 test assertions
  re-pinned. (6) Still the operator's: the #1231 verdict (then #1238 re-parent + theme-1 filing +
  queue), the #1162 verdict (recommendation posted), #1101's #1651 (unqueued).
- **⚑ PICKUP (2026-09-14 morning corpus session — SELECTIVE corpus load, the heat trial;
  arc in TICK-LOG).** (1) **#1231 verdict is the operator's** — seat recommendation posted on the
  Goal (validated, narrowed: acceptance-1 leg observed under #1640 acceptance 6; #1238 re-parents
  to #1640 beside acceptance 8 because its `default-pin` arm and the [Go rail](../glossary.md) both change under
  theme 1; #1237 stays seat-run, any sitting). **After the label:** re-parent #1238, file theme
  1's five children from the gated drafts (scratchpad `theme1/*.final.md` — re-draft if lost:
  `Base=goal/1640-router`, `Class=build`, `Origin=…#1641`, order 1 → 3 → 2 → 5 → 8), `git merge
  master` onto `goal/1640-router`, queue. **Operator rulings 2026-09-14:** NO interim unfreeze of
  the oracle lane (its five `agent/error` re-latch until theme 1 lands — leave them);
  `goose-32602-truncation` is a per-CELL signal, never a fleet latch (= #1640 acceptance 5; and it
  joins the serving set in acceptance 1 — record on the Goal); effort (FU-174) = a checkpoint-
  formed THEME 3 after #1237's rows + theme 1's merge, round-1-max as an `effort_map` row keyed
  on round-state, later-round "environmental" attributed by theme 2's retry ladder, never by
  inspection. (2) **S8 #1418 ([stint](chainless-redesign.md)) closeout 1 DONE** (12 dispositions, built-vs-left posted; #1424 →
  PR#1648 merged 06:36Z); the tree holds **#1649** (updater park-skip not holding — r3 F3's
  evidence) → quiet window arms from its fix; parent closes at a later sweep. (3) **Retro r4
  (PR#1645, two reports) READ, nothing filed:** opus F3/F4/F6 + deepseek F1/F4/F5 ARE #1640
  acceptances 1/2/3/5 (file as evidence on the Goal, not a batch); **r4 F1** (rounds-exhausted
  park fires on converging PRs, 7/7 human un-parks merged, ~€40/wk) → **#1627 EXTENDED 2026-09-14** (still unqueued: wave-2 dispatch belts or a human queues it); F2
  (ledger stale rows) + F5 (tier-edge guard) standalone-honest, unfiled; r3 F3 = #1649. (4)
  Codeowner reads: #1576 + #1540 merged 06:02Z (isolated replay probes against master, both
  pins non-vacuous); PR#1646 (`GithubVendorOutage` gains `Pull Requests`) merged 06:12Z; five
  audited responder threads closed (#1580 #1584 #1557 #500 #903). (5) Still owed from 09-13: the
  zombie run 34748702282 is UNCANCELLABLE by API (409 "not queued yet" on cancel AND force-cancel
  — the 08-19 class, operator UI or ignore; `CiDispatchStalled runner=unknown` firing on it);
  of#572's 2 h no-re-entry unexplained; the remaining responder threads (1546 = the of#554 read,
  1594 811 542 261 100 1013 114 121 241) + #121's plug-sensor edit → a board-sweep. (6) Live
  facts read this morning: platform claim `deepseek-v4-flash | [v4.1-flash] | shadow`; proxy pod
  up since 21:18Z with 0 `disk I/O error` lines in 9 h and `exacto:no-pin` on coding
  completions; the shadow log's `served=` is the router's decision, not the launcher's model.

- **⚑ PICKUP (2026-09-12, two seats — the drive-fitting day, then thinkcentre's decommission;
  full arcs in TICK-LOG).** Storage work for the day is DONE and verified live.
  (1) **Landed:** garage-1 on its own PM961 (FU-137's dedicated-spindle residual MET); m70s's
  freed Micron + hp-01's Intel 7600p tagged `std`; wk-02's pooled std disk fenced
  (`allowScheduling=false`); **thinkcentre OUT of the cluster** — 16 replicas evicted in 3 min
  19 s with 0 degraded, drained, node deleted, box dark at 0.0 W. PRs #1599, #1601–#1606 merged;
  **#1607** (the decommission + the new runbook recipe) was riding at wind-down — verify it
  merged. ⚠ #1606 was force-merged mid-session because a parked already-applied declaration PR
  makes an unrelated `tofu apply` want to push a stale config to the declared node.
  (2) **std is now TWO schedulable nodes** (m70s + hp-01; 732G allocatable / 147G committed):
  every r=2 std volume holds one copy on each, no third zone to rebuild onto, and
  `replica-soft-anti-affinity=true` means a squeeze is SILENT co-location, not a Pending volume.
  wk-02's 21 remaining replicas leave organically onto the same two nodes — check co-location
  after any eviction (one-liner in the runbook recipe).
  (3) **R12 is DESIGNED and half-BUILT — PR#1608** (ADR-129 + `docs/management-box.md`): NixOS,
  USB install once, two pins (system closure on `nixos/flake.lock`, toolchain on the repo's
  `devbox.lock`), box pulls a reviewed ref, **local** deadman rolls back. `nixos/` evaluates on
  both bootloader branches; `scripts/mgmt-probe.sh` passes 5/5 from the jail; timers built, NOT
  armed. **NEXT (operator, tomorrow): the USB stick + reboot** — before it, drop a real key in
  `nixos/hosts/mgmt/keys/` (an empty dir fails the build on purpose) and read the firmware in the
  installer (`[ -d /sys/firmware/efi ]`) to set `bootMode`; UEFI additionally buys the automatic
  boot-failure rollback. Still gating the box's first REAL job: **FU-097's ruling table**, which
  says which surfaces it may reconcile. ⚠ PILOT, not the permanent box (27.9 W idle, no AES-NI,
  the x16 CPU root port `00:01.0` absent) — private `hardware/requirements.md` R12.
  (3b) **The three-CP promotion is gated on a RIDE BOX**, not on a second hypervisor: it empties
  the kata pool 4 → 0 and ARC's labelled hosts 3 → 1 (ROADMAP §Hardware strategy + the ledger's
  new `need` row).
  (4) **Operator-hands, filed as FU-234:** the two Optane cards → wk-metal-04's free chipset root
  ports (`00:1c.0`/`00:1c.1`) as ride/ARC scratch; until then the `fast` tier has NO backing disk
  (zero consumers, so nothing broke). The x1 AIC form factor is off the market — do not discard.
  (5) **Unverified, worth one probe:** wk-metal-04's `intel1` sits on a chipset root port while
  `intel0` is on the CPU x16 — read `LnkSta` on both; if they differ the bulk pair is asymmetric
  and the ledger's rotation numbers (taken on `intel1`) were on the slower of the two.
  (6) Open, operator-lane: **wk-03 self-rebooted twice in ~19 h** (guest-side; evidence + the
  serial-console and "booted twice in 24 h" detector proposals on **#882**).
  (7) Noted, not a fault: the responder lane exits 1 all evening — the DESIGNED typed defer
  (FU-088, "both rails latched": subscription 7d utilization 0.95 + Go rail limited).

- **⚑ PICKUP (2026-09-11 evening corpus session — ADR-127/128 + deepseek workers; arc in TICK-LOG):**
  (1) **Codeowner queue DRAINED 19:4x–20:1xZ** (#1541/#1543/#1545/#1538/#1542 + sleep-tracking#142 merged; #1540 = the loop's merge-conflict lane, now with a play — PR#1596). **Read next: #1576** — deepseek round 3 was running at 20:1xZ; if it landed the `parity-regex-sigpipe` pin, the codeowner read is the only remaining act (arm is on); if it no-op'd again, that is the first deepseek-vs-haiku data point on directive-following — record it, do not re-poke blind. Was: #1538, #1540, #1541, #1545 bot-approved at head with no
  Follow-ups (re-reviewed under ADR-127 18:32–18:36Z); #1543 labels cleared (waits its master-lane
  review turn); #1542 approved under its Goal-#1231 container. Merge order per the queue spike
  (#1541×#1540 and #1543×#1542 each need one rebase). oracle-fleet#554 is CHANGES_REQUESTED by the
  bot (three in-diff defects) — the oracle loop's round, not ours. (2) **PR#1592 MERGED 18:47Z; PR#1593 (platform claim →
  deepseek-v4-flash / v4.1-flash) bot-approved + armed with CI running at wind-down** — verify it
  merged and `kubectl get agentstack platform -o jsonpath='{.spec.workerModel}
  {.spec.workerModelFallbacks}'` reads deepseek (it read `claude/haiku []` at 19:0xZ); if the
  updater left it BEHIND after the 19:0x master push, `gh api -X PUT
  repos/teststuffstash/homelab/pulls/1593/update-branch`. (2b) **Hotspot + refactor inputs** in
  [`../spikes/change-hotspots.md`](../spikes/change-hotspots.md): proxy + exporter extraction
  (revert class), `agents/replay/**` release from CODEOWNERS, ADR-113 scan/launcher extraction,
  a kind gate for the Argo Sensors — operator direction pending, nothing filed. (3) **ADR-128 trial
  week runs to 2026-09-18 → FU-233** (re-read vs `docs/spikes/codeowner-catches.md`; revert = the
  commented CODEOWNERS lines). (4) **First live signals to look for:** a containerless worker PR
  whose reviewer names out-of-diff paths → does the coordinator widen `Touches` (brief step 7)?; a
  stale human CHANGES_REQUESTED drawing a coordinator ride (ADR-127 says re-open the scan hold on
  the second one); the 5-round cap's first arbitrate at 5. (5) **Design input (operator, deliberately
  not an FU):** briefs/corpus on a diet — rules/rationale split + a no-history lint + a what-stands
  read layer (TICK-LOG 2026-09-11 evening, memory `briefs-rules-only`); the operator calls the
  corpus "too expensive to use" after S5.
- **⚑ PICKUP (2026-09-11 data-gathering seat, no corpus load — NO actions taken, no GitHub
  writes; arc in TICK-LOG):** two audits in `docs/spikes/` for the next corpus session.
  (1) **Codeowner queue** ([`codeowner-queue-audit.md`](../spikes/codeowner-queue-audit.md)) —
  ACTED ON by the evening session (ADR-127; see the pickup above). (2) **Responder week**
  ([`responder-week-audit.md`](../spikes/responder-week-audit.md)): 19 open responder issues with a
  one-line disposition each — closes: #1557, #1584, #903, #500, #1580 (drop `agent/queued`); own:
  #153 (`maxConcurrency` 20→40, one values line), #1547 (PR#1576 needs the ADR-103 replay pin, then
  codeowner-merge), #1546 (= the #554 read); reads: #857 c6/c7 (cilium-agent memory creep), #811 c2
  (**answers the 09-10 item (4): the Loki WAL triage existed at 00:19Z, delayed ~6 h on a graft
  thread** — verify the daily-budget-spent-on-the-storm hypothesis), #103 (one PromQL: m70s major
  faults vs garage-1 LMDB). (3) **Direction, not decision:** FU-230/231/232 filed from the design
  read (silence + declared window; bucket-first findings + `triage` meta-events source;
  reporter-keyed grafts) — operator's call whether to build; FU-219 currency updated.
- **⚑ PICKUP (2026-09-10 afternoon seat, ~14:3x–19:3xZ — the Garage lessons read + fix list; arc in
  TICK-LOG):** landed + verified #1588 (write probe alive — it had pushed 400s since 09-08; Silent
  absent-safe; GcBacklog 26h = the 24h tombstone delay; 30d SLO recording rules), #1589 (Garage
  CPU request 500m, rolled clean), #1590 (ledger/garage.md currency). (1) **Watch, not act:**
  `garage:cluster_health:availability_ratio_30d` is a ~2-day figure until its 1h source series
  ages (rewritten 09-09) — do not quote it as 30d before ~10-09; `GarageTableGcBacklog` re-pends on
  the new 26h timer over the #547 reap backlog (garage-2, 1.38 M, drains ~24h after each delete
  burst). (2) **oracle-fleet#547 answered** (lifecycle rule fine; the 08-25 restore reset every
  object timestamp → `runs/` expires from ~09-24) — nothing to do until then; `homelab-browse`
  now has read on `allure-reports` (hand-made key, the §Durability sweep list). (3) **Open by
  lane:** FU-229 (30d SLO breached, no burn alert until garage-2 leaves the X240; CI-hour churn
  attribution via the access log), FU-223 extended (depth-one CPU-per-IOP A/B = the raw-XFS
  decision), FU-137 (the garage-2 move — hardware: the 4U at 400 / SFF watch, hardware repo
  STATE). FU-089 archive entry is past expiry (lint warning) — next docs-cleanup.
- **⚑ PICKUP (2026-09-10 early seat, 05:1x–09:0xZ — three oracle handoffs + #884; full arc in
  TICK-LOG):** (1) **Oracle's release landed** (run 34450512688) after three walls in 12 h, all
  fixed: registry cap 48Gi (#1578, the 2× commit rule), `homelab-ephemeral-large` (#1582, #1585
  prefers wk-metal-02) — **oracle must switch `release-corpus.yaml` to `runs-on:
  homelab-ephemeral-large`** (told in the handoff result; unverified until Tuesday's 07:17Z run) —
  and 64 MiB S3 parts (#1583, live 08:46Z): **Tuesday's push is the measurement** (upload phase vs
  2.7 MB/s, commit copy vs ~15 min). (2) **Belts LIVE and replayed:** `garage_bucket_*` gauges +
  `GarageBucketQuotaNear` / `RegistryBucketCommitHeadroomLow` / `GarageBucketGaugesStale`
  (#1577), `PodEvicted` / `EphemeralNodeScratchLow` (#1581). **Firing by design at wind-down:**
  `GarageBucketQuotaNear` on **ert-snapshots 84 %** and **allure-reports 89 %** — both oracle-iac's
  (told); `GarageClusterFlapping` on garage-2 (clears with its 1h window); `GarageTableGcBacklog`
  may fire on garage-2 (549k draining at ~120k/h, ~4.5 h from 09:00Z — the node sits at 1–5 %
  idle meanwhile, consumer p99 inside objective; no action). (3) **agent-transcripts** was at 98 %
  of 5Gi → 20Gi (#1579); **retention policy = FU-228** (new). (4) **Loki was down 11.5 h**
  (hp-01 plug-cycle → index WAL corruption; logs 17:15Z→05:25Z lost for every tenant; recipe in
  runbook §Power-loss) and **no responder issue appeared for an 11-h `KubePodCrashLooping`** —
  open question for a board sweep (dedup against #811 is the first suspect). (5) **Unclaimed in
  the oracle inbox:** `20260908-1857` ARC shared uv-cache `.lock` EIO (third occurrence; the RWX
  share's advisory-lock story) — next handoff sitting. (6) Jail's oracle MCP re-pointed to the
  host root (the 09-03 endpoint move; user-scope config in `~/.claude.json`, defined as code
  nowhere). (7) FU-203's missing half is oracle-iac's untag (#664) — the Sunday GC CronJob
  collects nothing until it lands. Design input, no home yet: the registry exposes no scraped
  metric (debug addr on localhost) — push throughput has no belt; second sighting files it.
- **⚑ PICKUP (2026-09-09 evening seat — the drive-fitting windows; full arc in TICK-LOG):**
  (1) **garage-0 rotation DONE** (2026-09-09 20:05Z → 00:08Z, PR#1573/#1575, ledger row) — both
  zone volumes on `intel1`, SA400 unschedulable + empty. Residuals: **garage-2 meta 88 % full**
  → the rotation loop's job (alert pending at wind-down; if `GarageMetaRotationNotReclaiming`
  fires, read the gate log); the **"worth it for consumers" read is per-pod `UploadPart` /
  `ListObjectsV2` p99 during the NEXT delta run** vs the ledger's 09-08 figures — not taken.
  Also landed en route: the SLO availability rule now counts HTTP 200 (was the degraded regex →
  73 % during any node-down), upstream's Garage dashboard vendored (`garage-upstream`).
  (2) **Hardware arrival read** for the two 7600p (SMART
  `percentage_used`, Opal) via the runbook's privileged-pod recipe → `teststuff/hardware`
  purchases/inventory rows (the operator has an uncommitted `purchases.md` edit there — merge
  around it). (3) **thinkcentre x16 slot never linked** (CPU root port `00:01.0` absent with the
  7600p on the Axagon; the two Optanes sit on the closed x1 slots); untested with a known-good
  card — abandoned for today (operator). m70s waits for a Gembird (LP). hp-01 untouched.
  (4) **Plug ids were crossed since 08-18 → incident
  `2026-09-09-crossed-plug-hp01-outage.md`**; swapped in the HA registry, `power` subcommand
  refuses a loaded socket. (5) Seat reads done: #1561, #1562, #1570 all MERGED. (6) **m70s was
  freed for the oracle delta (oracle-iac#711, requests cpu 2)**: its outage-parked Deployment
  pods moved to hp-01/wk-01 (2126m free on m70s; untainted pool otherwise <1.3 cores each) — the
  PR's node-fit paragraph counted tainted nodes (no toleration anywhere in the path; every delta
  ran on m70s). (7) **CPU discussion (operator, 2026-09-09 late) — write up, don't build yet:**
  cluster 49 allocatable / 22.4 requested / 9.7 used; cilium-agent 5.5 + Longhorn IM 5.4 +
  longhorn-manager 3.0 cores requested use 2.8 → ~1.3 cores tax per 4-core node (FU-112b
  Guaranteed + FU-224). Levers ranked: cilium-agent Burstable 150m/500m (system-node-critical
  already carries the OOM protection), per-node IM CPU on compute-only nodes, sleepers to p95.
  **Ruled OUT: ride preemption** — a failed ride is a coordinator round, not a free retry.
  Kyverno/priority-class exclusivity parked: the fleet direction makes it moot. (8) **Fleet
  direction (operator):** Xeon-class boxes = untainted production/batch compute (never a storage
  zone beyond ONE zone's share); laptops = control planes; gaming PC = rides/ARC/inference
  (tainted); SFFs = std + Garage zones, storage spread equally — **placement rule to write into
  the storage ledger + hardware §Strategy: "no box holds more than one zone's share" (Garage
  places by capacity, Longhorn by free space — a fat box becomes the centre of gravity)**;
  thinkcentre + hp-01 retire once m70s (Gembird → 7600p for Garage, Micron → std) and one more
  SFF (register R3(c)) carry std; wk-02 stays the third zone until the second hypervisor.
- **⚑ PICKUP (2026-09-08 evening seat — the failing-workflows read): DONE, nothing to pick up.**
  Updater (PR#1521), responder model (PR#1522), agent-session bundle vars (PR#1523) merged and
  verified live (16:30 cron green on 12 repos; retro PR#1524 harvested; `respond-wm2cf` ran a real
  triage). Open residue only: **FU-227** (belt gaps) and retro PR#1524 in the reviewer lane.
- **⚑ PICKUP (2026-09-08 afternoon seat, ~14:4xZ wind-down — the pve capacity thread):** all
  applied and merged (PR#1518/#1519/#1520 + 09b81dd9): wk-03 16Gi/12c, ci-runner-01 12Gi,
  `maxRunners` 6; FU-224 limits raised; FU-225 archived (belt `PveHostMemoryLow` live). **Open
  for a fresh session:** (a) **ADR pending — the second hypervisor** (operator direction: the
  dual-Xeon 4U as an independent Proxmox host, three k8s control planes, k8s-layer HA, no
  corosync/Ceph; pulls ROADMAP §HA model forward; the read + pre-bid questions live in the
  hardware repo) — write it only once the operator says the box is bought; (b) FU-218 re-read
  of ARC queue p90 at 07–09/17–19 UTC after ~09-15; (c) FU-224 throttling-panel re-read ~09-15
  → archive; (d) GAPS tofu-apply-G1 (tf-apply exit 127 after a successful apply) is unchased.
- **⚑ OPERATOR — circles-iac PR#108 is UN-ARMED and waiting on you (2026-09-07):** circles' claim
  `egress.profile: none → python`. Its rationale ("static page + helm gate … no pypi") went stale
  when circles gained a uv chassis; flipping `enforce` with `none` would HANG every ride at its
  first uv call. Additive and inert to land (circles already passes `--frozen` everywhere).
- **⚑ OPERATOR (from the 2026-09-06 corpus session):** the #1450/PR#1470 fork above (A vs B).
  (The `agent-running` dashboard apply for PR#1480 landed 2026-09-08 — main root plans clean.)
- **⚑ OPERATOR (physical / decisions), from the 09-05 sitting:** (1) **CI starvation**: one org-wide ARC set of 3 slots (FU-218); homelab ≥300 runs today
  starved oracle (queue p90 22–40 min). Levers ruled/filed: #1452 (fair, platform-native);
  per-stack runner scale sets as the fairness knob (not filed — say so if wanted); wk-metal-04's
  16 GB as capacity after the cable (kata reservation = operator call). **09-08 afternoon: ARC
  is 6 slots now (wk-03 16Gi) — the pve-as-is ceiling; more = the second hypervisor.** App-side: oracle-fleet
  #466/#467 (resume + bundle the 248k PUTs). (2) ~~#1308 leg-1 APPLY on ci-runner-01~~ DONE
  2026-09-08 (VM replaced from tofu, buildx `homelab-mirrors` builder live). (3) FU-215 Unbound capture (unchanged). (3b) **BUY — wk-metal-04's SA400 is the Garage write
  bottleneck and the cable did NOT fix it** (rebuild on the healthy link: 2 h 10 min flat at
  24–32 MB/s = <5 % of the link; MX500 A/B = 0.6–18 ms — `storage-ledger.md` §2026-09-06, PR#1484).
  Replace with a **DRAM-equipped** drive; buying criterion for ANY Garage/Longhorn data disk is
  DRAM cache, not €/GB. Pairs with the FU-137 third-zone box, and
  **the box is BOUGHT, OPENED and ONBOARDED (2026-09-07): ThinkCentre M70s SFF ≈150 €, + 2 ×
  M.2→PCIe x4 adapters ordered, NOT yet arrived (2026-09-09)** — `m70s` @ **192.168.2.56** is a Ready Talos worker, `zone: m70s`, BGP
  `established`, PXE-installed on `/dev/nvme0n1` (matchbox flag applied then destroyed; BIOS is
  PXE-first by operator choice so a network wipe+reinstall needs no console). **What remains for
  FU-137 is the Garage half, not the box**: fit a data disk on one of its two free LP PCIe slots and
  move Garage to a real third zone at rf=3. **Its OEM NVMe reads `MTFDHBA512TDV-1AZ15ABLA` = Micron 2300 512 GB,
  LPDDR4-DRAM + 96L TLC** (not the DRAM-less QLC 2400 the part number resembles) — it meets the
  buying criterion, so the zone can stand up on the box as delivered and is not blocked on a drive
  purchase. Board also has 3 SATA. ⚠ **CORRECTED 2026-09-12 (operator, board-read with the
  brackets in hand): there is NO second x4 — the `x4` silkscreen carries an x1 connector and the
  `x1` silkscreen is unpopulated, so the x16 LP is the box's ONLY x4-capable slot** (one Gembird,
  not two; card 2's home: pve's x16, free since 2026-09-21 — storage-ledger §hypervisor). Detail in `teststuff/hardware`. Disk read via the new privileged-pod recipe (`docs/runbook.md` §Reading a
  fleet disk's identity and health — FU-222 archived): **2% used, 3051 h, 0 media errors,
  PCIe 3.0 ×4**, near-new. Supply side, incl. a specced 25 € DRAM-cached NVMe candidate that
  would also close FU-093's pool gap: private **`teststuff/hardware`** repo on Forgejo (`STATE.md`).
  wk-metal-04's replacement is still open and still wants ≥500 GB — a 256 GB drive would shrink
  the bulk tier. (4) Loop health: `AgentRunPhaseSlow` deferred by the
  responder 17:02Z and never re-triaged (DEFERRED-STUCK — the FU-113(b) retry chain); read the
  respond workflow retries. (5) Seat miss to remember: a zsh `set -- $var` classifier cancelled
  six LIVE CI runs (all re-run) — the card's no-word-split gotcha bites the seat too.
- **✅ Garage rf=3 across three physical zones — LIVE 2026-09-07 (FU-137/ADR-114), executed by the
  evening seat session.** wk-metal-01 / wk-metal-04 / m70s, one pod each on `longhorn-local-xfs`
  (replica-1, XFS, strict-local, WaitForFirstConsumer); layout v2, `Zone redundancy: maximum`;
  garage-0 rotated onto the new class at 22:21Z (the first rotation, run for real; new id
  `a79a04a7`, layout v2 single live version) and **its native resync CONVERGED 2026-09-08 ~05:00Z
  (verified: identical tables on all three, 3 pre-existing corrupted Loki chunks the only errors).**
- **⚑ BOARD (09-05 ~09:45Z — see NEXT for the four open seat/loop PRs; earlier read follows):** in review #1386 (re-review after the seat's fix push) ·
  **18:20–19:00Z sweep:** **#1409 codeowner-APPROVED 18:23Z** (the #1403 fix; auto-merges on
  green) · **#1440's launcher fix landed DIRECT as a quickfix (`12249396`)** — PR#1448 is
  fixture-only now (seat conflict-merge took master's launcher; the loop's round rides on the
  directive amendment on #1440: drop the PARTIAL relaxation of #1205) · #1453 parks
  `blocked-on: issue=1440` until PR#1448 merges ·
  riding #1378 #1392 (r1, deepseek — dispatched before the haiku flip); #1384 #518 completed r1
  → PRs in review · queued this morning by the seat: **or-op#60** (item-2 root; coordinator pod
  up 08:0xZ), **agent-runtime#119 #120** (finalize sprouts), **homelab#1297** (mirror poison
  belt), **#1403** (reviewer false-anomaly, 2 sightings), **#1405** (exporter GraphQL partial data — PR series family absent), **#1412** (README ci.yml→ci.yaml), **#1413** (PyPI consumers, blocked by #1300), agent-runtime **#123 #124** (finalize sprouts); or-op #60/#62 rode and merged (PR#61/#63 seat-approved) · #1300 re-scoped (Touches narrowed off
  the guarded glob, VIP 40.34, 20Gi) and stays queued · de-queued + seat-landed: #1299 (direct,
  9a0354ec), #1207 (PR#1401), #1308 (PR#1402), #1390 (direct, 1907048f), #1200 (PR#1399).
  **Platform claim = `claude/haiku`, no fallback, LIVE 07:54Z (PR#1395; operator: credits to
  burn today)** — the #715 revert clause executed. Park-watcher recipe = poll
  `github_pull_request_codeowner_park` on Prometheus (zero gh calls). Inert with owners: #1069
  (→ item 2 above) · #518 (runner infra) · #628 (container) · #857 (maintenance-session class).
- **⚑ OPERATOR-ONLY — from the four `coordinate-<stack>-1788589800` logs (2026-09-05 06:30Z,
  read out of Loki; every item live-verified the same hour). The machine will never act on
  these; the next session picks them up in this order:**
  1–4. **DONE 2026-09-05 (this sitting):** the five undeliverable queue items re-scoped or
     seat-landed (BOARD above); or-op#60 queued (the #57/#58 ghost-hold root — oracle-fleet#361's
     hold is oracle-iac#485, dispositioned DELIVERED, closes on the oracle jail's side); the
     FU-090 gate adopted #119/#120/#1297, commented #1069 (resolves with #1386), left #857 /
     agent-runtime none / or-op#34 (needs a real 429) as they were; #1249 rides as a seat PR.
     Still theirs: stack sprouts (oracle-fleet 11 + UNBLOCKED #416/#176/#84, sleep 2, circles 5)
     — relay, don't triage.
  5. **Phantom `agent/done` HELD (closed with no merged PR — confirm the close or relabel):**
     homelab **#913 #903**; oracle-fleet #25 #24 #22 #7; sleep #7.
  6. **PRs where a human is the next mover:** sleep-iac **PR#80** (merge conflict,
     seat-authored — the seat's own push); oracle-fleet **#425/#426** un-armed research PRs
     (the operator's `specs/` read, by design); circles **PR#25** un-armed (specs contract —
     arm or park); sleep-tracking **PR#143** ci-red held because #141 is `agent/blocked`.
  7. **Hygiene:** a ZOMBIE hosted run — `update-pr-branch` (retired workflow) queued since
     2026-08-19 04:58Z on `ubuntu-latest`, id 32217689970; cancel says completed, DELETE 403s
     with the jail PAT — an operator-identity/UI delete, or ignore (excluded from
     CiDispatchStalled as `runner=hosted`) · stale agent branches, delete or resume — homelab 11
     (`agent/20260824-104524 …-132129 20260825-171429 20260830-233803 20260901-165514`,
     `fix/cost-rethink fix/issue-126-… fix/issue-500-… fix/issue-721-…
     fix/reviewer-app-statuses-… fix/window-shares`), agent-runtime 1, oracle-fleet 4,
     circles 4, sleep 1 · oracle-fleet#84 carries a RETIRED `Depends-on:` line → native edge.
  8. **Backlog queue calls (suitable-unqueued, `devbox run board -- <stack> --full`):**
     homelab **read 09-05 (operator: "queue the infra now")** — 14 = 3 goal containers
     (#1302 #1231 #1162, not units) + **4 QUEUED from the seat: #1384 #1378 #518 (image half
     only) #1392 (+Touches authored)** + #1316 CLOSED (self-resolved 09-02, residual is
     oracle-fleet's allure-publish timeout) + 6 that stay: #1200 (scripts/** = operator-lane,
     hand-do) · #1370 (needs a cluster diagnosis first — FU-171) · #1280 + #829 (design-shaped,
     corpus sitting) · #1237 #1238 (operator/seat-run spikes) · oracle-fleet 20 (oldest #212,
     08-08) · circles 3 · sleep 1 · or-op 1 (#60 — item 2's root).
  9. **Loop health — READ 2026-09-05 21:0xZ → homelab#1456 (inert):** the 09-04/09-05 `coordinate-*`
     Failed ticks are exit 141 (SIGPIPE) ~70 s after the homelab clone with zero scan output
     (Loki); the producer hunt + a Failed-tick belt are the issue's deliverables. Queue it if wanted.
- **⚑ OPERATOR-OWED (one list):** (#1200 → PR#1399, #1249 → seat PR, both 09-05; residual
  from #1200: no ArgoCD sync-failed/OutOfSync alert exists — a belt to add) · #1370
  (FU-171 resight) · or-op#34 (needs a real 429) · seat sittings #946 (A5 seed) / #1224
  (parts-coverage) / #1237 (E1) / #1238 (E2) · #1308 (BuildKit mirrors queue call) · FU-205
  design pass (WAN accounting) · #1280 held-for-evidence (kind-timing distribution first) ·
  Cloudflare: mint `Cache Purge` onto tofu-apply, or rely on oracle-fleet#414's
  Cache-Control (decision open) · Garage: delete `backups/garage-meta-20260825-prerebuild/` (20 GB) +
  `garage-meta-forensics/` (due since ~09-01). **Garage metadata is UNATTENDED since 2026-09-09**:
  the rotation loop (PR#1549 + thresholds #1551/#1553/#1554) rotated garage-0 on its own at
  08:45Z, 27.83 → 4.68 GB in 4 min (ledger). Residual watch: garage-2's `table_gc_todo`
  (1.77 M earlier, GC failing while garage-0 flapped) should drain now — if it does not, that
  is belted (PR#1558 `GarageTableGcBacklog`; draining ~130k/h, ~10 h). Acceptance PASSED:
  garage-0 ListObjectsV2 p99 1.45 s (was 35.7). Rollouts no longer cost quorum (PR#1555 readiness
  + PR#1556 `minReadySeconds` 300 — the 300 s spacing is untested by a rollout yet; the next
  garage template change is its live test, `GarageQuorumMembersRestarted` must stay silent).
  The 3 ERT giants STAY (docs/garage.md §Durability).
- **⚑ GOALS — verdicts are the operator's, the seat recommends:**
  - **#818 G-B — HELD with a posted 4-clause verdict condition** (teeth drills deferred to
    oracle's production launch; lens posture advisory-steady-state; responder shadow; prober
    = oracle-fleet#344 class-1 pilot, open). The bar is exercised-in-a-stack (GAPS G5), not
    shipped.
  - **#1162 wave 1 — `goal/validated` when the egress soak reads clean** (#1247 closed; drops
    0/4h at 09-02 06:30Z); its close sweep disposes store entries 28–30 + bucket #1170/#1200
    and mints wave 2 (#1211 #1212 FU-199 residue #1198 #1199; #1224/#1225 operator-lane),
    AFTER #1231.
  - **#1231 router-first — machine set G1–G5 all landed 09-02**; remaining = E1 #1237 + E2
    #1238 (operator/seat sittings) → tree-empty → operator's validated read. STRIKE_ENFORCE
    stays OFF (recording precedes policy); hold G4↔G2 coherent at review.
  - **#1302 G-G — post-launch; verdict #1334: checks 1+2 OBSERVED** (api-profile 429 on
    Free; apex `cf-cache-status: HIT`), **check 3 = the RUM residual** — no Web Analytics
    WRITE permission group exists for a user token, so the consumer profile's RUM half is
    undeliverable through `homelab-ingress-write` (design residual for #1311: dashboard RUM /
    account-owned token / drop RUM from the profile; the Workspace stays Synced=False on it).
    #1334 wears `agent/error` until the #1249 damper lifts. Edge legs still platform-side:
    **FU-206** (ops paths blocked at the edge — one more rule in the custom-phase ruleset,
    both profiles, dry-run through the proxy first), cloudflare.md completion rows S4/S5
    (Free managed WAF / ddos_l7 outside the Skip — verify), the `CTR-ACCESSLOG` contract row
    (proposed). oracle-iac#485 (mcp api claim) is the oracle jail's. Operator read, not owned
    here: public `/metrics` on the api hostname (fleet).
  - G-A #775 + G-F #1039 VALIDATED and closed — nothing left here.
- **⚑ CONTAINERS TO CLOSE:** **#1418 S8** — closeout 1 done 2026-09-14; holds #1649 (QUEUED
  2026-09-14, operator); close ≥72 h after it lands · **#1101 retro r2** — closeout 1 done
  2026-09-14; holds #1651 (r4 F2, the IL-T28 reconcile not firing; `agent-fix`, unqueued); close
  ≥72 h after it lands · CLOSED 2026-09-14 at this session's sweep: **#979 S5** (five originals,
  quiet since 09-05), **#949 retro r1** (scored by r2/r3), the G-A/G-F post-launch buckets
  **#787 / #1048** (Goals validated + closed, empty trees). Left alone: oracle-fleet#416
  (post-launch child of closed #386 — a real regeneration item, the oracle jail's).
- **⚑ ORACLE (the platform's half only):** Goal #418 — #432/#433/#428/#429 done; research
  PRs #425/#426 wait on the operator's `specs/` read (by design); #416 regeneration is
  operator-attended (blockers closed). #414 inert (operator queues). **homelab#1381 in
  review** (the arbitrate door files goal children inert with no reader; fix = carry
  `harvest=store` like merged-closeout). Bucket #386 / Goal #176 are the oracle jail's; ⚠
  #176 carries a stale blockedBy on stint #269 (holds nothing; misleads) — un-wire when
  touched. **Handoff inbox (oracle) holds two older tasks**:
  `20260903-1245-ci-red-data-point-391…` (data point + suggestions, "not an ask" — read for
  a new class, answer) and `20260903-1815-in-pod-kind-unrunnable-issue-399-r1` (kind node
  segfault in a kata pod + mirror pull path; needs the ride's transcripts) — next
  `/handoff`. or-op#57/#58 queued (harvested, inert — ordinary board flow).
- **⚑ INFRA / INCIDENT PICKUPS:**
  - **FU-072 soak = two legs**: Service-VIP leg PROVEN (oracle PR#434, zero drops); the
    **dind/kind leg is UNEXERCISED** — needs the first in-pod `devbox run e2e` (a
    `task/build` ride), which also carries the #399-r1 kind segfault above. Regression
    signature: `AgentWorkerEgressDropped` with a bare pod IP; revert `773ad63e`.
  - **pve thin pool 82.2 % — `PveThinPoolFillingUp` FIRING since 09-05 morning** (read 07:40Z);
    `LonghornDiskBelowSchedulingFloor` firing on wk-02 `default-disk` (56 GB free) too — the
    Garage forensic-backup deletion owed above is the lever — the answer is fstrim (twice daily since 09-04) + FU-093's next
    act (Longhorn filesystem-trim), not a threshold bump. Read `pve_lvm_thin_pool_data_percent`
    before/after a 03:17Z fstrim to size the cadence.
  - **Unbound github.com SERVFAIL (FU-215)**: four windows 09-05, self-clearing, one after
    a restart — probable WAN-wide upstream UDP loss (infra cache), NOT DNSSEC (it is off).
    `log-servfail` is ON as code since 18:06Z (PR#1454): after the next `UnboundGithubServfail`
    window, read `diagnostics/log/core/resolver` (search `SERVFAIL`, stamps UTC+3) and decide
    the `serveexpired` belt — the FU carries the evidence + next step.
  - **Git-throttle watch**: every loop clone is preemptively authenticated since PR#1333; a
    recurrence with zero anonymous requests = FU-007 push-mirror becomes the next
    deliverable (incident record §Recurrence; memory `git-preemptive-auth`).
  - **Sentinel latency fix (`cfb98bbb`)**: verify the next runs' bootstrap ≈ 0
    `copying path` lines and the iac-sentinel status floor ≈ scan+queue.
  - **FU-168 soak FAILED 08-25** (cron-woken dispatches persist; #459 closed) — the emitter
    hunt is the next concrete action, tracked on FU-168.
  - Small residue: wk-metal-04 `longhorn_bulk_zone` field-manager conflict on FULL tofu
    applies (unreproducible read-only; verdict = the next full apply) · hp-01
    `install_disk: /dev/sda` is a NAME with two identical disks (repin to WWID, FU-076's
    neighbourhood) · OTLP trace-export spam (`localhost:4318 refused`) in registry + 3
    mirrors — add an `OTEL_SDK_DISABLED`-class env · garage resync workers RESET to defaults 1/2 on
    all three pods 2026-09-09 (the build-out's 8/0 had been left on everywhere, saturating the SA400 —
    ledger §The SA400 zone under rf=3 load) · FU-073/084/089/098 stale-archive entries, 41d old (next
    docs-cleanup).
- **⚑ WATCH-NOISE candidates (next meta-events touch):** FAMINE emits per count-delta not
  threshold-crossing — AND counts `iac-sentinel-edge` convoys (09-05 08:01Z: 10 Pending on the
  sentinel mutex after a 5-PR push burst, 1 subscription pod running — a queue, not a famine;
  exclude sentinel-edge or count per kind); "unlabeled >24h" false-flags containers (wants the
  sprout-report-skips-buckets exclusion); gh `--jq` takes NO `--arg`; reviewDecision never
  changes across CR→CR re-verdicts (key on newest-verdict timestamp); reviewer STEP-0 false
  anomaly on update-branch re-pointed review commit_ids — **FILED homelab#1403 (queued) at the
  2nd sighting (PR#1289, PR#1386)**; NEW sighting 09-05: the in-cluster updater merged master
  into bot-approved + REVIEW_REQUIRED PR#1386 FOUR times in 31 min (07:06–07:37Z) — the #887
  park-skip clause did not hold it; read `agents/update-pr-branch.sh`'s predicate before filing.
  Also: GitHub RE-POINTS a review's commit_id on update-branch (approvals survive updater
  merges — the 2026-09-05 merges of #1388/#1389 confirm; the merge-path.md dismiss-on-push
  worry applies to CONTENT pushes only).
- **⚑ DESIGN INPUTS WITH NO OTHER HOME (operator: deliberately not FUs — pick up in a
  design-agents sitting):**
  - **Drainage economics RULING (2026-08-31, operator-confirmed; TICK-LOG has the arc)** —
    the drainage round/branch/triage design is BANKED (measured 1 stack-blocking : 16
    nice-to-have on the live pile; the seat gate-reads every diff anyway, ADR-110 is the
    binding resource). Standing policy: (1) blocking defects (incoming blockedBy from a stuck
    stack issue / live wedge / 🚨) queue immediately, master-lane, hotfix-class, and every
    filing door wires the edge; (2) the nice-to-have pile is corpus-session batch work —
    no new machinery; (3) the Touches classifier survives as a LINT (#1102, done). The jail
    watches blocking-class parks actively (meta-events BLOCKPARK). Banked, operator's own
    "not yet": an AUTOMATED design-agents corpus read on codeowner-parked BLOCKING issues —
    revisit if parked-PR volume freezes dispatch. Post-launch goal fixes target MASTER (v1.2
    stands). **This ruling has no record beyond this bullet + issue-authoring.md's one
    clause-1 reference — it is ADR-shaped (decision + rejected alternatives).**
  - **Stack→platform routing (2026-08-30) — instances 3+4 undischarged by ADR-119:** (3)
    stack ACCESS/SERVICE gaps have no tracked inventory — no role×stack×service matrix
    exists (grep negative FU/ADR/GAPS); the oracle jail had no read on its own transcripts
    (no coordinator anywhere holds transcript read; the brief's "reads freely … transcripts"
    has no built mechanism — A2 MCP slices unbuilt, FU-058 leg); Loki (ADR-118) is the ONE
    stack-scoped read and the donor shape; TOOL_GAP markers exist only for cluster sessions,
    the jail lane has no channel. Direction to weigh: generate any matrix from grant sources
    (never hand-author — FU-049's pattern), consumer-card + grants file per LIVE service,
    TOOL_GAP extended to jail sessions, the capability-request lane as the routing. (4) a
    fix landed on a `goal/**` branch protects NOTHING on master until assembly (oracle
    PR#280 → master PR#293 hit the same class next day); long-lived RUNNER state is
    untracked platform surface (ci-runner-01 dockerd insecure-registries, stale devbox
    venvs — the y/n prompt class).
  - **v1.3.1 BANKED** (PR#1220, "deserves a place when it works"): `Origin:` line + typed
    defer/release + checkpoint theme-FORMATION are S8 originals — do not build piecemeal
    ahead of S8; delta 1 (park economics) landed independently (PR#1375/#1376/#1352).
  - **The dispatch-declared `requires:` FU is sanctioned to file** (operator's conditional
    after the harness matrix closed on all three arms, 09-02) — not yet filed.
- **Soaks** (each owned by an FU/issue — this line is only the calendar): retro r3 Mon 09-07
  · FU-148 first organic environmental-red retry · or-op#34 first daily-429 ·
  renovate-approve one-approval-per-head (#114) · CiDispatchStalled FIRED 09-05 08:36Z (ARC pool saturated by the seat's PR burst — L-scenario
  churn, not a wedge) → the quiet-month window (FU-150) restarts from 09-05 · FU-192 per-tenant ingest sizing (due ~09-03, PAST) · **paid-flash REVERT EXECUTED 2026-09-05 07:54Z** (PR#1395 — none of #715's three
  triggers had fired; operator-ordered; the FU-095 flip child, if wanted, mints from here;
  Go re-flip = FU-181) · opencode.ai
  rails UN-PARKED 2026-09-14 (`OPENCODE_RAIL_DISABLED` back to `"0"`; FU-213 closed by
  homelab#1640 acceptance 2 / #1667 — the proxy now sends `x-opencode-session`).

## Durable warnings — EVICTED (S4 #765, 2026-08-23)

The section's content moved to its proper homes; this pointer is all that remains:

- Probe & triage discipline (absence-is-fake, deploy-silences-`for:`, info-suppressed,
  counter-vs-throughput, green-surface, bypass actors, written-is-not-applied,
  one-spec-page, operator-lane PRs) → **`docs/runbook.md` §Meta-session probe & triage
  discipline**.
- Shell/tool gotchas (zsh word-split, `--body-file`, `gh --jq`, `gh pr view` merged, python3
  yaml) → **`agents/jail-subagent-card.md`** (applies to the seat too); pipe-filter-push →
  CLAUDE.md §lanes; apostrophe-in-jq → mechanized in `prompt-transport-lint`.
- goal/-prefix arming → `docs/agents/issue-authoring.md` §Base (was a duplicate);
  label caps + branch-rename-closes-PR → same doc; two-readers → **FU-178**; the
  agent-runtime-fixer-lane status note was stable news and is dropped (the
  reviewer.enabled platform trap survives in the runbook bullet).

## Re-arm on a fresh session

⚑ **Per-SESSION-TYPE since 2026-08-19 (operator direction, the watches-for-codeowner-sessions
sitting).** Both jail session types — the mechanical MAINTENANCE session and the CORPUS session
(design-agents corpus loaded: codeowner reads + FU build + subagent waves) — arm the SAME
standing set below; what differs is cadence and the act rule:

- **ONE STINT PER CORPUS SESSION (operator rule, 2026-08-20).** The corpus bootstrap
  (measured 300–350k cache-creation tokens per load, 2026-09-03/04 — `session-ctx.sh --big`)
  costs only ~6–10 turns' worth of high-ctx re-reads, while every turn re-reads the WHOLE
  context at 0.1× — so at ctx ≥ ~500k a NEW stint always starts a FRESH session (break-even
  turns ≈ 470k / ((ctx−400k)×0.1): 500k→~47, 600k→~23, 800k→~12; a real stint is 150–300+
  turns and stints EXPAND). Trailing work of a few dozen turns may stay warm. Measured basis:
  the 2026-08-19 night session — 459 turns, 275.8M cache-read = ~92% of spend.
- **Ctx wind-down (operator, 2026-08-19): end ~50k tokens BEFORE the context cap — never ride
  into compaction** (a compacted corpus session is no longer a corpus session; a fresh one
  bootstraps from this file + TICK-LOG by design, mid-stint included). Measure with
  `bash scripts/session-ctx.sh` at heartbeats once past ~½ window; at the threshold run the full
  wind-down ritual regardless of in-flight work.
- **Cadence**: the corpus session's heartbeat runs UNDER the ~1h Anthropic cache TTL —
  **2700s**, not 7200 — so the belt that catches a stall is also what keeps the big context
  cache-warm (a wake within TTL is a ~0.1× cache read; past it, a full re-read — the Part A″
  arithmetic, [observability-and-retro.md](observability-and-retro.md) §Part A″). Maintenance
  sessions keep 7200s (light context, cold wakes are cheap). An expected wait past the TTL with
  nothing in flight = WIND DOWN deliberately (write the pickup, **push the batched direct
  commits — ONE master push through the githooks/pre-push lint gate, the 2026-08-30 batch
  rule (seat card §How changes land)** — kill monitors by process, run jail-transcripts-sync,
  exit).
- **Act rule**: a watch event outside the session's type is RECORDED for the other type (board /
  a meta-state row), never acted on — design-shaped events don't get improvised without the
  corpus (the /design ruling applied to watch events); agents-lane events don't derail a
  mechanical sweep.
- **Subagent waves**: the standing set is the level-triggered layer; ad-hoc per-PR watches are
  edge triggers on top and must cover EVERY terminal (new changes-requested, CI-red, breaker
  labels — not just merge). A subagent granted the PR flow owns its own cycle
  (`agents/jail-subagent-card.md`); the seat hears terminals only.

- **meta-events loop (REQUIRED, replaces the standalone needs-meta arm)**: `Monitor` (persistent)
  `bash agents/meta-events.sh` — the FU-166(b) consolidated 120s edge-detected loop (needs-meta
  absorbed as a source via `--once`, + goal-thread User comments, aggregated alert set, doorbell
  famine gauge). Cold state re-emits the standing set = the fresh-session bootstrap view. The
  SEATPR source is the anti-stall piece for seat PRs (PR#568 sat changes-requested overnight on
  2026-08-18 with only an ad-hoc watch armed — the standing set would have surfaced it in ≤120s).
- **needs-meta watch (legacy standalone — do NOT double-arm beside meta-events)**: `Monitor` (persistent) `bash agents/meta-needs-attention.sh`
  — unreviewed platform PRs, `agent/blocked` issues, unlabeled>24h, AND (clause 4, 2026-08-08)
  stack-repo codeowner parks (bot-approved+green+REVIEW_REQUIRED on oracle-fleet/circles — it
  caught circles PR#54 on its first pass; oracle PR#217 had sat 17h). ⚠ verify by process AFTER arming
  (`ps aux | grep NEEDS-META` for an inline variant, the script name for the script one — an
  absence is a claim about your grep, proven again 2026-08-08 05:00Z).
- Backstop heartbeat: `Monitor` (persistent) `while true; do sleep 7200; echo "META-HEARTBEAT:
  sweep due"; done` — **2700 on a corpus session** (the per-type cadence rule above) — every
  sweep runs `bash agents/meta-throughput.sh` FIRST (queue-vs-movement; a THROUGHPUT-STALL line
  is an incident, not calm — 2026-08-09 operator catch), then
  `bash agents/meta-alert-crosscheck.sh` + the board/chain check against this file, then
  `bash scripts/jail-transcripts-sync.sh` (the §A1 jail leg, PR#580 — best-effort, loud skip
  while unreconciled; also run it once at wind-down).
- Handoff watch is NOT standing (operator 2026-08-09: special case) — arm `bash
  agents/meta-handoff-watch.sh` only on rollout days / when a stack jail is known active;
  `/handoff` processes the inbox on demand.
- Loop watches (`agents/meta-watch-loop.sh` per stack) are OPTIONAL rollout-time tools now —
  expect ~10 routine events per real signal (operator 2026-08-08: "too many monitors").
- Probe hygiene: probes in SCRIPT FILES, dry-run under the real interpreter; watch the FAILURE
  signature explicitly; `PROBE-FAIL` over silent empty state. Monitors survive `/clear` and are
  invisible to TaskList — find leftovers by process and kill before re-arming.
- **oracle-specs quota** (either jail; oracle-iac#446 merged): verify `garage bucket info
  oracle-specs` shows 5Gi, then any fleet CI re-publish re-materializes the specs sites;
  close-purge of dead pr-*/ prefixes tracked oracle-fleet#318.

- **R12 pickup (2026-09-13 night seat, ~17:4x–21:0xZ — the fail-closed sentinel, cloudflare on
  the box, the box's GitHub traffic; arc in TICK-LOG).** LIVE: #1631 in-cluster no-root poster
  (FU-237 (b), proof 104 s), #1633 + #1635 cloudflare plan-only root + `homelab-mgmt-read` (MINTED,
  stored, pushed to the box 19:2xZ — the box plans cloudflare read-only now), #1637 the box's git
  traffic AUTHENTICATED + ON-CHANGE (was ≈576 anonymous fetches/day; now one API sha check per
  tick, fetch only when master moved — proven on the box 21:00Z), quickfix 8dc8d4c6 (the
  classifier's pipefail rc wedged the apply loop for ~8 min after #1637 — un-wedged, stamped).
  `mgmt-policy-test` is a `ci` step. Direct: FU-007 rewritten to the operator ruling (Forgejo =
  major-outage fallback ONLY, never the live read path — memory `forgejo-fallback-only`); FU-239
  (`jail-read-all`'s standing `~ id` permutation, API order arbitrary, 5.25.0 did not fix it —
  `cloudflare-token-tofu` excludes it by default + reports real +/- elements; CF_INCLUDE_READ_ALL=1
  includes); FU-240 (devbox version skew box↔jail rewrites devbox.lock on the box). Box checkout at
  8dc8d4c6. **Operator:** (1) `mgmt-release` ABSENT — design discussion 21:xxZ leaned to FOLLOW
  MASTER gated by `git diff -- nixos/` (the `/nixos/` CODEOWNERS row is the human gate; the ref
  adds a second promotion, not safety) → an ADR-129 amendment PR next corpus session, then arm
  `mgmt-pull.timer` (needs the mgmt_git auth header too). (2) the doorbell (FU-237 d): ONE socket
  unit, two paths (/sentinel from the iac-sentinel run, /update from the merged-PR workflow on
  the in-cluster runner); the PATH FILTER lives on the RINGER using the inbound webhook payload
  (coarse superset nixos/ tofu/ policy/mgmt/ scripts/mgmt-*), never a fetch on the box; then the
  5-min timers slow to hourly. (3) observability = node-exporter on the box scraped by the
  pve-node `ScrapeConfig` precedent (pull, no credential on the box) + textfile metrics for
  activated commit / belt / sentinel — settles §MB2's "transport UNBUILT"; offered, not built.
  **Seat next:** FU-012's scoped kubeconfig; FU-237 (c) per-role env; `/fu-sweep` (33 STALE
  archive entries, FU-227 oversize).

- **Oracle handoff inbox drained (2026-09-23 seat, ~12:30–14:00Z; arc in TICK-LOG).** All three
  new items answered and moved to `done/`; only the operator-parked 09-11 minutark README link
  is left in `inbox/`. MERGED: **#1942** `.spec.originMark` (PublicRoute edge-asserted origin
  mark — set+strip in one `http_request_late_transform` ruleset, egress address read from the
  `wg.teststuff.net` A record by a `cloudflare_dns_records` data source at every reconcile, so
  the reconciler is provider-terraform's own `--poll=10m` drift loop and there is NO new
  updater); **#1943** the `oracle-feedback` Grafana datasource (uid + ExternalSecret in
  `monitoring`); **oracle-iac#970** the free deepseek cell denied on THEIR claim.
  **OPEN at hand-off: PR#1944** (the model-identity spike + FU-201 (c) third instance + FU-283),
  auto-merge armed, `REVIEW_REQUIRED` at writing — it lands on its own; check it, don't re-open it.
  **Owed and visible only to oracle: the origin mark's SERVE-TIME check.** Entitlement at create
  is not behaviour at serve time (the 09-03 custom-429 precedent). Once oracle-iac sets the knob,
  the next prober tick either shows `homelab` in the feedback `origin` column or it does not — a
  null there means the header is not surviving the tunnel hop, the one link that could not be
  tested without mutating live config. The Result asks them to report either way.
  **Operator rulings this session, both load-bearing:** (1) a platform decision does not go back
  to a stack as a menu — the Infisical-publish shape for oracle-iac#953 was RULED, not offered;
  (2) no small router fix now — "free vs paid and model vs family is a bigger topic, there is a
  lot of deepseek-flash out there" → written up as `docs/spikes/model-identity-free-vs-paid.md`,
  with the actionable half on Goal #1640 via FU-201 (c). **Seat next:** FU-283 (hung-CI-run
  watchdog — pick the 2×p95 belt before the runner-side dig); FU-282 (repoint the origin mark off
  the WireGuard-named record, needs a live OPNsense apply); and ⚠ our own platform-stack deny
  `deepseek/deepseek-v4-flash-0731` is INERT against the permaslug-spelled cell — worth checking
  whether it was ever meant to cover it.
