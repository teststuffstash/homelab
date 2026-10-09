# 2026-10-08 — nine hours without WAN: the window-2 failover proof never left CARP maintenance

**Impact.** 2026-10-08 19:40:16Z → 2026-10-09 04:46:09Z (9 h 06 min): the LAN had no internet.
Every LAN-local path stayed up — `.1`, DHCP (Kea HA primary on nx-02), Unbound for LAN names,
HAProxy names, the BGP LB VIPs, the cluster itself. Everything that needed the WAN failed: GitHub
(CI, the agent loop's clones and tokens, the reviewer), OpenRouter, Cloudflare probes, external
DNS, the jail session's own API path. The operator accepted the overnight loss as the price of a
BACKUP join done without the WAN cable ("my call"); this record exists for the mechanism and the
recovery findings, not the blame.

**Timeline (UTC).**

- 18:59 window `seat-1791485956-9934` opened; 19:00–19:12 the 10-02 "standby served DHCP" trip
  investigated and explained (a relayed frame — [router-move.md §Status](../router-move.md));
  19:17 #2389 (tap `flood off`) merged, applied on pve 19:18.
- 19:28 #2390 (window-2 change set) merged; 19:29–19:36 kill switch retired, main root applied
  (on_boot, Cilium peer `.71`), nx-02 converged (Kea HA primary), pve converged (BACKUP, Kea HA
  standby). Both checks green, 13 BGP sessions each, `RouterPairMasterCount` 1.
- 19:40:13 proof: `POST carp_status/maintenance` on nx-02 → pve MASTER at 19:40:13.785 (0.5 s);
  19:40:16 nx-02's WAN gate drops its WAN (no advert); 19:40:13.9 pve's gate raises a WAN tap
  with no carrier. Probes: `.1`/Unbound/HAProxy/LB VIPs served from pve; DHCP leasing from
  nx-02's Kea (HA primary, independent of CARP); 1 lost connection of 1152 at 10 Hz; WAN dark.
- 19:41:21 "back out": `POST carp_status/enable` → `{"status":"ok","action":"enable"}`. nx-02 stays
  BACKUP. 19:42:02 the script logs `.70=BACKUP .71=MASTER` and continues to its probes; the probes
  pass (every leg but WAN was fine) and the script ends 19:42:18 "proof end". The seat's own API
  path rode `.1` → EAI_AGAIN; the session is blind until the operator's hotspot.
- 19:44 → 21:11 the alert cascade: `UnboundGithubServfail`, `GithubExporterPartialData`,
  `EndpointProbeFailing`, `TargetDown`, `KubeDeploymentReplicasMismatch`, `KubePodNotReady`,
  `RegistryMirrorBlob5xxRate`, `KubePodCrashLooping`, `GithubTokenMintStale`, later
  `IacSentinelSilent`, `ArgoWorkflowsFailing`, `AgentLoopWorkflowsFailing`, `CloudflareEdgeProbeBlind`,
  `CloudflareSpendProbeBlind`, `CloudflareExporterDown`, 01:17 `ArgoLockPlaneWedged`.
- 04:40 operator on a mobile hotspot; the session reads the proof log and the CARP state.
- 04:46:07 `POST carp_status/maintenance` again (the toggle) → `leave_maintenance`; 04:46:08
  nx-02 MASTER; 04:46:09 its WAN gate raises the WAN; 04:46:2x the LAN reaches 1.1.1.1 and GitHub.
- 04:48–05:03 the WAN-dependent alerts clear on their own (see Recovery).

**Root cause.** OPNsense's `diagnostics/interface/carp_status/{status}` runs
`carp_set_status.php`: `maintenance` is a TOGGLE (flag set → leave + demotion back to default;
else enter + `net.inet.carp.demotion` 240); `enable`/`disable` flip `net.inet.carp.allow` and
bring VIPs up/down — `enable` on a node already enabled is a no-op and never touches the
demotion. The proof script assumed enter = `maintenance`, leave = `enable`, and did not read
the demotion or the VIP state before declaring the step done; its own log line (`.70=BACKUP
.71=MASTER` after the "enable") recorded the failure, and nothing read it.

**Contributing.** (1) The proof ran unattended inside the one hop it was about to break: the
jail's internet rides `.1`, so a failed back-out blinds the operator's tool. Window 1 used the
same shape deliberately (an unattended cutover script) and got away with it. (2) The verb was
read from `router-move.md`'s drill table ("API `diagnostics/interface/carp_status/maintenance`")
for entering; leaving was guessed, not read from `carp_set_status.php`, which was one `sed` away.
(3) No belt says "the pair's MASTER has no WAN": `RouterWanGateSilent`/`RouterPairMasterCount`
were green (one master, gate alive), the WAN gauges (`router_node_wan_link{9171}=1` on a port
with no carrier) carried the fact without a rule reading it.

**Recovery findings — what healed on its own, what needed a hand** (the operator's question:
Telia has downtime too; are the workflows resilient and do they leave junk?).

- Healed on its own within ~15 min of the WAN return: every WAN-dependent *detector*
  (`TargetDown`, `EndpointProbeFailing`, the Cloudflare and GitHub exporters, `IacSentinelSilent`,
  `MgmtLeaseLoopStale`/`MgmtApplyLoopStale`/`MgmtBeltCheckFailing` — the box's systemd timers
  simply ran green again), the crash-looping pods, the deployments' replica counts.
- Needed a hand (both in the maintenance-window skill's known list): CI runs stranded in `queued`
  (ARC listeners do not re-claim across the gap — 3 homelab + 1 oracle-fleet, cancel + rerun);
  five responder workflows that had exhausted 5 retries each and sat in a **4-hour retry backoff
  holding all five `subscription-capacity/claude` semaphore slots** → 20 workflows Pending,
  `ArgoLockPlaneWedged` (fired correctly at 01:17, after 30 min). They WOULD have retried at
  ~00:00–01:30 and again at ~04:00–05:30 and succeeded once the WAN was back — "self-healing" with a
  4-hour lock-plane wedge as the cost. Stopped by hand at 04:55 → the queue drained in 2 min.
- Junk left behind (read at +17 min and +37 min): still present at +17 and +37 min: the 20 `Failed`
  workflow objects of the outage (five respond-*, the cron runs that fired into the dead WAN —
  iac-sentinel, ledger-reflex, retro-activity-collect, update-pr-branch-cron, coordinate-* in three
  stacks, review-*, probe-oracle, oracle-fleet/retention, fix-debounce-backstop) and two `Error`
  pods (agent-coordinator, cnpg-system). Whether Argo's TTL reaps them is the next day's read; the
  retro counts them as pain either way (`ArgoWorkflowsFailing` 219 in 6 h, `AgentLoopWorkflowsFailing`
  per stack — both age out by themselves). The oracle-fleet PR branch's red CI run re-ran on its own.
  Nothing else was left: the box's four timers were green at +0 (`Result=success`), the router pair
  exactly as before the proof.

**Actions.**

- DONE #2395 (merged 05:21Z — admin merge: the branch updater re-based it on every master push and the sentinel's 5-min tick never caught the current head; the diff it judged twice was unchanged): `scripts/opnsense-router-node.sh carp-maintenance <node> enter|leave|status`
  reads the demotion first, toggles only when the state differs, verifies the VIP after; the
  window-2 recipe names it and forbids the raw API.
- DONE (record): router-move.md §Status carries the window and the incident.
- Open, for the tracker (the seat files): a belt for "MASTER with WAN down" — `router_node_carp_master
  == 1 and on(vmid) router_node_wan_link == 1` is the gate's view; the missing half is carrier
  (or the node's `WAN_GW` dpinger state via the OPNsense exporter) — `RouterMasterWanDark`, for: 2m.
- Open: a responder retry backoff must not hold a subscription slot (release the semaphore across
  the backoff, or cap the backoff below the lock-plane alert) — design-agents material.
- Open: an unattended proof that can cut the seat's own path runs with a dead-man: a timed
  `leave` the script arms BEFORE entering maintenance (`at`/systemd-run on the hypervisor), so a
  missed back-out reverts itself.
