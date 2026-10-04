# meta-state — in-flight operator chains (tiny, transient)

One bullet per pending meta-coordinator chain with its NEXT concrete step; delete bullets when
done. **TICK-LOG carries history — this file carries ONLY what a fresh session must pick up.**
(Keep it short: a bloated meta-state is the token-waste a fresh `/meta-coordinate` bootstrap is
meant to avoid — and every design-agents corpus load pays it too: at 75 KB this file cost
~20k tokens per corpus session before the 2026-09-05 prune. A wind-down writes the PICKUP,
never the session's arc — that is TICK-LOG's.)


## Live state (pruned 2026-09-26 by the fu-sweep — every bullet re-verified against GitHub/the cluster that day; history is TICK-LOG's; the forward plan is the ROADMAP work map)

- **⚑ PICKUP (2026-10-02 night — helm provider 3.x applied under evidence; TICK-LOG 2026-10-02 evening).**
  (1) **#2183 merged unread by the operator** (author==codeowner waiver) — the box apply loop now DEFERS
  inside [declared windows](../glossary.md); operator to read its three calls: `MgmtApplyDeferredByWindow` at 6 h, the
  reconciler's node windows hold the apply loop, `--admit-apply` separate from `--admit-reconciler`.
  Confirm the box's next pull runs it (a `DEFERRED` line the first time a window is open). (2) The
  `fu-mint-gate` hook is a TRIAL (operator: replace it if it doesn't change behaviour). (3) FU-299: daily Longhorn job + UniFi
  `.unf` LIVE (PR#2196/#2197: schedule as code + UnifiAutobackupStale) — glance at the 10-04 01:00Z `.unf` +
  02:00Z run; off-site PARKED by the operator.
- **⚑ PICKUP (2026-10-02 afternoon — retro activity windows LIVE; TICK-LOG 2026-10-02 afternoon).**
  `retro-activity-collect` runs every 30 min (warm ~2 min) and `retro-findings-reconcile` at 07:30Z; the first
  reconcile is the first real-Garage `publications()` run — read it 10-03. **Before Mon 10-05 05:00Z:**
  if the rank fix #2170 (queued) hasn't merged, decide whether r7 runs on the old rank (it samples
  PRs on cancellations only and misses blocked issues). PR#2172 = ADR-146 Proposed, awaiting the operator's read.
- **⚑ PICKUP (2026-09-27 night — FU-289 hardware half DONE, unattended; TICK-LOG has the arc).** nx-02 boots
  from the SA400 (root+swap; `local-lvm` 700 G thin pool on it; the WD is a spare still in the bay), the
  LSI HBA now exposes 2 INT13 disks, ci-runner-02 is UNPARKED (#2048 applied 21:16Z), the window is closed.
  **Read (1):** run 36351320341 landed on ci-runner-02 — "Preparing nodes" **3.9 s** (failure 397/67 s,
  runner-01 2.5 s), e2e green 7m11s, swap 0 B, no `PveHostSwap*`/`PveNuma*` fire; …24933 was cancelled by
  the concurrency group, …30352 ran on ci-runner-01-2 (~0 s, image cached). One sample — the belts judge the
  week. (2) DONE 2026-09-28: the operator PULLED the WD spinner, so the SA400 is the only INT13 disk —
  the BIOS-priority question is moot. (3) Board, 2026-09-28 morning session: `LonghornNodeOverProvisioned`
  on wk-metal-01 CLEARED — it was registry-data's replica, replenished onto the mx500 at 19:01Z while wk-04
  (nx-02) was down in the FU-289 window (the runbook §Single worker maintenance 600 s class, not FU-285's
  co-location); the seat deleted that replica in a window and Longhorn rebuilt it on wk-04's sn530.
  `GithubStorageHeldHigh` = oracle-fleet's `unit-allure-results` artifacts on the 90-day default (853 ×
  2.1 MB); old ones deleted by API, oracle-fleet#763 sets `retention-days: 1` — expect the alert to clear
  as the 24 h average catches up. The `agent/error` trio #2037/#2046/#2047 was the 2026-09-28 process session's material — see the
  S9 bullet below. `MgmtBeltCheckFailing`×3 + `MgmtReconcileLoopStale` fired 13:17–19:56Z 09-27 on the #2043 class — un-wedged
  by hand, fixed by PR#2045 (init every run in probe + reconciler). **Retro r6 = PR#2050, merged 05:36Z
  by the agents App 6 s after the bot approval — the "HUMAN-GATED, auto-merge NOT armed" gate in
  `retro-argo.yaml` is defeated by `review-reflex.sh`'s C9 re-arm (worker-App author, no parking marker:
  C9 honours only `major/awaiting-human`, `major`, `agent/error`, `research/*`); r4 #1645 went the same
  way (8 min), r5 #1819 only waited because the reviewer requested changes. Operator's call which marker
  the retro PR should state (both existing ones carry other semantics) — one line in retro-argo.yaml's
  `gh pr create` once chosen. Prior-art grep FU/GAPS/merge-path: nothing on retro PRs specifically.**
- **⚑ PICKUP (2026-09-29 evening — S9: #2033 merged + deployed, prod OPNsense on 26.7.4; TICK-LOG 2026-09-29).**
  **NEXT SESSION = ONE GOAL (operator): software-side prep for the router move — rehearse the
  from-git router VM on nx-02 IN ISOLATION** (WAN = `eno2` passed through but uncabled, LAN on a
  portless bridge; spoofs Big Data's `em0` MAC; WireGuard server key from the wallet; ACME re-issue
  or import) and score it vs prod ≈0 — after moving the drill's series + test-VM baseline to 26.7
  (`trial-26-7-4` on 9110) and a confirming master drill. Also inventory + parametrize everything
  wired for ONE static router at `192.168.2.1`/`opnsense-fw` (ansible inventory + wrapper, the
  backup CronJob target, the box's `OPN_API_*` belts, alerts/probes, the harness's prod guard,
  ddclient/WireGuard endpoints) so a big-bang move is a config flip + one window. **NO hardware
  change** until the switches are in hand (TL-SG1016D ordered, hardware `purchases.md`): the later
  visit = WAN switch (ONT → nx-02 `eno2` + Big Data `em0` powered-off fallback, its LAN cable out)
  + the management switch; Big Data stays intact 1–2 weeks before its card moves to pve.
  **Progress 2026-09-30:** the isolated rehearsal is BUILT + merged (#2131, `opnsense-drill.sh --router`;
  [`router-move.md`](../router-move.md)): PASS, 12/12 probes, score 6 at that point.
  Later 2026-09-30: WireGuard key carried (#2133, `wg_handshake` green), the WAN_GW rows accepted
  in their dead state → **score 0**; the (B) API address read from the inventory (#2132). Rehearsals
  2–4 "network blips" were the jail HOST's new cable + wifi (ARP flux, fixed host-side with
  arp_ignore/arp_announce) — not the rehearsal VM.
  Then (2026-09-30 midday): root = wallet `opnsense-root-password` (#2136); OPNsense 26.7.5 —
  SERIES bumped + 9110 baseline moved (#2134) and PROD updated in window seat-1790760478-4482
  (operator-approved; 16 s, no reboot, all checks baseline); **ADR-144** (#2135): the CARP pair is
  built beside Big Data — nx-02 node `.70`, pve node `.71` (operator buying a 1 GbE x1 card for
  pve: Realtek → host-bridged WAN, not passthrough), each managed at its own IP. **2026-09-30 afternoon:** the standby profile = **#2138**
  (`opnsense_standby`; rehearsal `--router --standby` PASS, 5 inert probes + real cert/WG green) —
  in review. nx-02 WAN **bridged** (operator: if no performance penalty) — the throughput read
  through a bridged rehearsal WAN is unbuilt. **pve's TG-3468 FITTED** (window
  seat-1790772187-4679): `06:00.0` `enp6s0` `ac:a7:f1:b3:25:95`, x1 2.5 GT/s, own IOMMU group,
  unconfigured; the onboard RTL8168 moved to `07:00.0` and is PINNED `nic0`
  (`pve-network-interface-pinning`; vmbr0 = nic0 — unpinned, pve would have booted offline).
  **2026-09-30 evening — nx-02 NODE STANDING + INERT at `.70`** (#2140 bridged WAN
  ~3 Gbit/s; #2141 `tofu/opnsense-router.tf` vmbr3 + VM 9170 applied in window
  seat-1790782366-5635; `bash scripts/opnsense-router-node.sh check nx02` = the read-only
  health read). **2026-09-30 night (goal session, #2142–#2150):** both nodes standing + reboot-proof,
  `/24` ruling (ADR-088 amended; trial VIP `.72`, HAProxy VIPs `lo0` for good), pfsync, the
  hypervisor WAN gate (`router-wangate@<vmid>`, QMP `set_link` keyed on CARP adverts), the belt
  (`RouterPairMasterCount`/`RouterWanGateSilent`); drills PASSED: failover/preempt, hard stop,
  rolling update (3 reboots, flows kept), split-brain (belt fired), cold start — numbers in
  router-move.md. The operator's cable nx-02 `eno2` ↔ pve `enp6s0` stays in (fake ISP:
  `router-node.sh fakeisp up`; a node REBUILD is refused while it gives carrier — correct).
  **2026-10-01 (ADR-145):** window-1 PREP LIST DONE (#2155 Kea-as-code, #2156 Kea HA drill,
  #2157 nx-02 host reboot, #2158 .72 retired + skews + router-ids, #2159 RouterPairMasterCount
  interim `> 1`, #2160 BGP alert per peer — auto-merge pending re-review; #2161 DRAFT = the
  Cilium peer .1→.70, apply IN window 1, plan id 20261001T190057Z-f06b997d, re-plan if stale).
  **⚑ WINDOW 1 DONE 2026-10-02 (window seat-1790960221-62) — nx-02 IS THE ROUTER.** #2166 (change set
  + LAN_GW drop) merged, #2161 (Cilium peer `.70`) applied; `.1` = CARP MASTER on nx-02, WAN
  `176.46.101.184`, BGP 13/13, Kea leasing, WG handshake, backup, HAProxy names, `check nx02/pve` green.
  The WAN loss was the old cable. **Big Data: RUNNING with BOTH cables OUT** — the API `core/system/halt`
  did NOT keep it down (it answered `.1` again within ~4 min → double `.1` until the operator pulled
  its cables). Fallback = router-move §Window 1 step 4 (stop nx-02's VM FIRST, then replug Big Data).
  **Next:** soak 1–2 weeks → window 2 (pve joins as BACKUP; its WAN already on the switch, gate dark);
  write the window's lessons into router-move §Status (halt ≠ off; the ddclient play hung on a
  `pkg update` stuck from the double-`.1` minutes; `mgmt-tf apply` prompts `y`; Kea served only
  after a re-run; `opnsense.teststuff.net` came from Big Data's hostname → static override 3cf5bd16).
  `OpnsenseConfigUnattributedRevision` fires on every jail converge (root key) — FU-013's class.
  **⚠ WINDOW-2 BLOCKER — pve's STANDBY node served DHCP as `.1`:** kill switch tripped 17:14:43Z on
  `02:00:c0:a8:02:47 > mower  192.168.2.1.67 > 192.168.2.150.68 BOOTP Reply` → VM 9171 stopped,
  onboot latched 0 (WAN gate still active). `check pve` was green at 17:02 (DHCP off, switch armed).
  Cause unknown: the seat's 17:02–17:14 acts all targeted nx-02 (`--limit`/`OPN_HOST=.70`); suspect
  the #2166 inventory flip (plain playbook runs now hit BOTH nodes — the box's `--check` belt is the
  routine one) or a pfsync/Kea interaction. **Next:** `killswitch-arm pve` FIRST, boot 9171, read its
  Kea + dnsmasq config and config history 17:02–17:14Z; do NOT reset onboot until understood.
  Open beside it:
  `PveNumaNodeMemoryLow` fired 15:22Z on nx-02 node 0 (wk-04 16 GB pinned + ci-runner-02
  8.9 GB + cp-02 6.6 GB; the router VM sits on node 1) — FU-289's class. Read 2026-09-30 late: no swap, but nx-02 is fully booked (~60/62.5 GiB) → **budget the pve node and any further nx-02 VM against that**; fix = RAM (FU-289 item 3, operator watching for a lot). #2130
  (`experiment/retro-activity-window`, 06:49Z, not this seat's) sits CHANGES_REQUESTED + BEHIND.
  **Identity the new router must carry** (prod config read 2026-09-29): WireGuard server privkey
  (router-only by the role's design — export to the wallet + an import path, OR re-issue the two
  client configs, OR carry it from the backup: operator call); the 3 API pairs (wallet has them →
  seed renders them, so no consumer flips); root password (no wallet entry yet); the WAN MAC (spoof
  `em0`). **Certs + ACME account: IMPORT from the newest encrypted backup** (operator, 2026-09-29 —
  re-issuing 17 per rehearsal risks LE's per-domain weekly limit): decrypt with the wallet age
  identity at build time, carry `cert`/`ca` + the `AcmeClient` section with refids intact (HAProxy
  binds by refid); the registered account comes along, sidestepping FU-298's register-404; acme.sh
  renews on its 60-day interval. Nothing lands in git.
  **Open:** FU-013 next = playbooks onto the `automation` key (needs privileges for the system role's endpoints too);
  FU-298 = the upstream ACME register 404 (O-X-L issue = operator's call); prod LAN is `.1/22`, not
  the `/24` `ip-plan.md` states — the ADR-088 CARP ruling must settle it; the reviewer exit-contract
  keys a merge head differently from the reviewer's standing-aside (false NO TERMINAL; not filed).
  Firmware: official path, no Renovate (operator) — the daily-check belt is not built.
- **⚑ PICKUP (2026-09-28 late night — ADR-142 trial LIVE; TICK-LOG 2026-09-28 (evening → night)).**
  `scripts/` is un-owned + worker-authorable (except `mgmt/scripts/` + the three box verbs);
  the gate is the BLOCKING gate-change lens + ci's gate-drift report. Drills: 2 caught, control
  approved, 1 not run. **Re-reads (operator): 2026-10-05 and 2026-10-28** — count gate-change
  PRs, lens verdicts, DIFFERS lines, any weakened gate found after merge; revert = `/scripts/`
  in CODEOWNERS + `scripts/` in governance-lint GOVERNANCE. Box moved to `mgmt/` (PR#2088),
  re-activated by hand, green. Open from tonight: FU-295 (box sentinel vs goal/** PRs),
  FU-296 (governance-lint self-test). FU-294 CLOSED 2026-09-29 (ADR-143 — see the pickup below).
- **⚑ PICKUP (2026-09-29 morning — ADR-143 live; TICK-LOG 2026-09-29 has the record).**
  mermaid-lint runs on Deno with zero permissions (#2098); `lock-intake-lint` gates every PR's
  lockfile intake in `ci` (OSV incl. `MAL-`, 7-day floor, install-time code, transitive included).
  **#2100 (Renovate mermaid 12 on deno) is RED BY DESIGN** — waits for mermaid-js/mermaid#8278;
  the coordinator ruled no ride (state-fp debounced) — never pin/override it. The npm mirror is
  `npm-cache.teststuff.net` (Unbound, #2101 — Deno cannot use an IP registry). Parked on the
  ROADMAP supply-chain section: master/prod scan (Dependabot vs Dependency-Track + SBOM + Kyverno),
  then stacks via the consumer card — operator decision, homelab first.
- **⚑ PICKUP (2026-09-28 night — the Forgejo chain DONE end to end; TICK-LOG 2026-09-28
  (afternoon) + its Closing paragraph have the record).** Landed by the machine lane: #2078,
  #2082, #2084, #2087 (the drill's findings, four review rounds), drill #2085 → revert #2086
  (alert → merged revert 6.5 min), the box applied the revert 17:40Z, runner on `docker:27-dind`
  2/2. Direct: c18bfe3f (ci.yaml first-parent read via `cat-file` — the #2064 fix had never
  fired on a depth-1 checkout), the Renovate rule arming terraform docker-image majors (ADR-141
  amended). **First reads next session:** (1) #2037 — Renovate's next run should rebase it
  (`behind-base-branch`), the lens re-reviews at the new head, it merges on its own, the box
  applies the docker:29 tag with no rollout wait; if it sticks, the lane reverts it — read, don't
  click. (2) `KubeDeploymentRolloutStuck` on forgejo-runner should be RESOLVED (the drill pod
  was terminating at 17:41Z). (3) agent-runtime#161 parked on its `unit` job (devbox-install-action
  vs pre-installed nix, `.github/` operator-direct — a Renovate/Actions class item). (4) #1988:
  the row is commented; close it when the base-image half has its own home. **Shelf-life finding
  for the operator:** `major/awaiting-human` PRs (#2046/#2047 BEHIND; #2033 merged + deployed 2026-09-29; #2032 closed → #2100) rot
  within hours — decision (a) of the S9 bullet is the open one. **Operator decisions still open:**
  (a)–(e) of the S9 bullet + the retro r6 marker. **S9 closeout residue:** #1991, #2014.
  **Hygiene still standing:** `:dependencyDashboard` in sleep-tracking / sleep-iac / oracle-iac;
  agent-runtime's `deps-pin-guard.sh` pre-#83; dead `update-pr-branch.reusable.yml` callers;
  `coordinatorModel` on `opencode-go/deepseek-v4-flash` (revert to `opus` when the Anthropic 7d
  window resets); the Monday 06:00Z image rebuild did not fire (re-check next Monday).
  `automerge` label = Renovate-only.
- **⚑ PICKUP (2026-09-24 — registry2 / FU-280 CUT OVER).** `registry.teststuff.net` → `registry-fs` on
  the `registry-data` volume since 14:50Z (#1961/#1962); the S3 Deployment runs unrouted as the rollback.
  Next steps + the operator's disk-tag question are on **FU-280**. **FU-286:** PR#1963 (talosctl from a
  nixpkgs rev at 1.14.1) was in flight at the sweep. Once it merges, `MgmtBeltCheckFailing{check="talos"}`
  should clear on the box's next pull. If it still fires, read the box's devbox resolution.
- **⚑ RESPONDER — REPLACED, NOT UN-PAUSED (ADR-148, FU-249, 2026-10-03).** Keep the Sensor filter. Step (1)
  LIVE (PR#2193: every rule carries `triage`, upstream via the relabel map). Next: the subject-key residuals
  (FU-249 (2)) → route `triage="now"` with the crosscheck and §routing test, then delete the filter → the
  grouped deep dig. oracle-fleet's own rules (ert-pipeline ×2, oracle-gateway ×3) still carry no `triage` —
  the stack's lane (`patterns/observability.md` §3).
- **⚑ GOAL #1906 (retro r5 batch, themed).** #1908/#1909/#1911 done. **#1910 is authored and UNQUEUED
  on purpose.** The operator reads Goal pin 3, then either queues it or rules it deferred on the store.
  Theme #1907's assembly (`goal/1906-scan → master`) is the one codeowner read, and it has not been
  opened yet. **#1651** (under retro r2 #1101) closes by hand once #1908 reaches master via that
  assembly. After that, #1101 closes ≥72 h later.
- **⚑ OPEN GOALS / CONTAINERS (verdicts are the operator's):** #818 G-B HELD (4-clause verdict posted).
  #1302 G-G post-launch: check 3 = the RUM residual, #1311/#1334. The consumer Workspace stays red on it,
  and that is **FU-250**. #1640 router Goal. #1769 rails Goal. #1418 S8 [stint](chainless-redesign.md): #1649 landed 09-14, so it
  is due to close at a sweep.
- **⚑ OPERATOR-OWED (one list, verified open 2026-09-24):**
  ((1)/(1b) DONE — `.agents/review.md` carries the intent-review rule (c8e38675) and the standing-gate
  wording; verified by the 2026-10-03 fu-sweep.)
  (2) claude-jail `6f90815` (`DEVBOX_USE_VERSION=0.18.3`, FU-240) is still unpushed in `/workspace`.
  It needs your push + a jail rebuild, and the host profile wants the same export.
  (3) pop-os `~/.talos/config` may still hold the pre-rotation identity (FU-264 rotated the CA 09-22).
  #1882's "3 flagged choices" were never recorded.
  (4) pve's CMOS clear reset "Restore on AC Power Loss" — UNREADABLE headless (no GPU; the 09-30 card
  fit could not check it): a monitor/GPU visit or a deliberate plug-pull test. Until then pve may
  stay dark after a power cut.
  (5) Human-next-mover PRs: **circles-iac#108** (claim egress `none → python`, un-armed; flipping enforce
  under `none` hangs every uv call), sleep-iac#80, sleep-tracking#143.
  (6) Operator/seat sittings, open: #1237 (E1), #1238 (E2), #1224 (parts-coverage), #1280 (held for
  kind-timing evidence), #1370 (FU-171 resight), #1713 (pin-only-lint, operator lane), #1627 (unqueued),
  #1669 (blocked until theme 1 deploys).
  (7) Cloudflare `Cache Purge` onto tofu-apply vs relying on oracle-fleet#414's Cache-Control: undecided.
- **⚑ UNOBSERVED FIRSTS (read when they happen; no action until then):** #1621 is open for its live
  acceptance: the next oracle corpus publish should ring `/corpus-published` → `release-corpus.yaml`.
  `fixer.imageVolumes` (#1808, ADR-135): the first ride with `/corpus` mounted. The first oracle
  closeout under `.agents/closeout.md` (#1806, ADR-134). The first real `CronJobNotSucceeding` fire:
  is a weekly job's 21-day threshold tolerable? The origin mark's SERVE-TIME check (#1942), which is
  owed by oracle: a null `origin` column means the header does not survive the tunnel hop. Also check
  whether our platform-stack deny on `deepseek/deepseek-v4-flash-0731` was meant to cover the
  permaslug-spelled cell, against which it is INERT.
- **⚑ UNBUILT, NO HOME YET (single sightings — detector-first on a second):** `fstrim-guard-<node>`
  is nodeName-pinned ON PURPOSE (the manifest: "must still run when cordoned") — so while a node is
  OFF in a window its guard sits Pending and `CronJobNotSucceeding` fires (2026-09-27, wk-04): a window
  consequence for GAPS maintenance-window-G5's EXPECTED class, not a skip-on-cordon change. `KubeJobFailed`
  fired 45 series during the 09-16 window, and adding it to `DECLARED_ALERTS` was rejected as too broad.
  Separately, the registry exposes no scraped metric, so push throughput has no belt.
- **⚑ HYGIENE:** stale agent branches (homelab 11 as of 09-05, plus agent-runtime 1, oracle-fleet 4,
  circles 4, sleep 1): delete or resume. The ZOMBIE hosted runs 32217689970 and 34748702282 cannot be
  cancelled by API: operator UI, or ignore. Phantom `agent/done` closes: confirm or relabel
  oracle-fleet #25 #24 #22 #7, sleep #7.
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
