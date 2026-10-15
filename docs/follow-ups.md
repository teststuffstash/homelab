# Follow-ups (the FU tracker)

Running list of loose ends and deferred work — the stuff intentionally not finished yet. Bigger
parked *features* live in `ROADMAP.md` → "Backlog / parked features"; this file is the operational
tracker.

**Conventions (the contract):**

- Every item has a stable id **`FU-NNN`** (3 digits, sequential, **never reused**).
  Next free id: **FU-313** (2026-10-13: FU-312 minted for in-cluster pulls of registry.teststuff.net stalling mid-stream on the router hairpin (oracle handoff, the ert-corpus roll). 2026-10-10: FU-311 minted for the jails' shared user-PAT rate pool (#2442, claude-jail#4). 2026-10-09: FU-310 minted for dind's HTTPS-first probe of the HTTP-only registry mirrors (a drop + dial timeout per pull, `AgentWorkerEgressDropped`) — operator weighing hosts.toml vs mirror TLS. FU-309 minted for the descheduler — displaced pods never move back after a window, operator-deferred. FU-307 minted for the "MASTER with WAN down" belt the pair lacks — blocked on an attended gate restart; FU-308 for a dead-man `leave` on unattended router proofs — both from the 2026-10-08 incident. 2026-10-08: FU-306 minted for the ci-runner VM replace the box cannot yet run itself — the attended verb is proven. 2026-10-07: FU-305 minted for the box loops a devbox bump wedged — sentinel silent). (2026-10-05: FU-304 minted for the laptop CP that cannot hold the apiserver — the sizing lever is the operator's, the detector shipped first (PR#2264). 2026-10-03: FU-303 minted for the etcd/scheduler/controller-manager scrape gaps the ADR-148 upstream classification found. 2026-10-02: FU-299 minted for Longhorn having no backup at all, FU-300 for the box's window-blind apply loop, FU-301 for helm_release applies (evidence first), FU-302 for the box's missing Prometheus-free view of the cluster. 2026-09-29: FU-298 minted for the OPNsense plays not converging a FRESH router (found by the FU-297 test VM). 2026-09-29: FU-297 minted for the OPNsense test VM on nx-02 that validates router-config PRs against a real 26.1 API (#2033 first). 2026-09-28 night: FU-295 minted for the box sentinel never reporting on homelab goal/** PRs (found by the ADR-142 control drill), FU-296 for governance-lint's untested worker match (found by drill D3). 2026-09-28: FU-294 minted for the npm Renovate lane no fixer ride can serve (lockfile regeneration needs a registry, homelab's claim egress is `none`, no baseline npm mirror) — #2032 parked on a human; FU-293 minted for the flat `scripts/` directory that path-based CODEOWNERS rules cannot cut, the iac-lane.md debt parked 2026-08-12. 2026-09-27: FU-292 minted for the runtime-major adoptables harvest gap — a dependency PR has no container, so the lens's follow-up bullets land nowhere. 2026-09-27: FU-291 minted for late-round reviewer findings. 2026-09-25: FU-290 minted for the homelab-agents GraphQL pool exhaustion under Renovate PR churn (the detector fix is PR#1979). FU-289 minted for nx-02 NUMA pressure swapping CI memory after wk-04 PCI passthrough. 2026-09-24: the counter read FU-288 after FU-288 was minted — corrected by the fu-sweep. 2026-09-23: FU-287 minted for the kernel-oops counter re-counting old
  lines on every Alloy restart, measured at the belt's own acceptance; FU-286 minted for the box's talosctl trailing the fleet by a
  minor, which devbox cannot resolve past yet — found by the belt's own FAIL, which nothing read;
  FU-285 minted for the replica co-location a disk pull
  caused, which `replica-replenishment-wait-interval` did NOT prevent; FU-284 minted for
  fleet-wide disk-health metering — nothing watched any drive's SMART and the fleet buys used
  drives with disclosed defects; FU-283 minted for the hung-CI-run watchdog, from oracle's
  fleet-strike handoff; FU-282 minted for the origin mark's `wg.`-named egress
  record, deferred because it needs a live OPNsense apply; FU-281 minted for the goal-checkpoint trigger side waking on
  nothing — operator's fix; **FU-280 is taken by the registry-backend spike, PR #1905 in flight**.
  2026-09-24: FU-288 minted for `node-maintenance` having no IPMI/BMC power path, found when nx-01 would not boot after a drive fit.
  2026-09-22: FU-279 minted for the uncollected Garage-side multipart debris, found running the registry GC by hand; FU-278 minted for the rollout's missing workload-health hold; FU-277 minted for the Talos 1.14 DHCP search-domain → loopback trap; FU-276 minted for the reconciler's failure paths found on nx-01 in the first box-run rollout; FU-275 minted for the canary override's seed-image churn; FU-274 minted for first-party images off the ghcr pull-through mirror; FU-273 minted for the substrate rollout's missing soak/halt + version-split attribution. 2026-09-21: FU-269..272 minted for ADR-139 (broker split, agent-gateway, gateway HA) + the vendor-status split; FU-268 minted for the CP-divergence/undeclared-component detector (#1845); FU-266 minted for the single CI runner VM (pve window), FU-267 for cilium-agent at its 512 Mi limit; FU-265 minted for wk-metal-04's unparseable firmware boot entry, found by the worker rollout; FU-264 minted for the Talos API CA rotation the public-master talosconfig leak makes necessary; FU-263 minted for the nocloud-VM substrate-upgrade fork found bumping the CPs; FU-262 minted for wk-metal-02's now-misleading name, deferred to its next reinstall.
  2026-09-20: FU-261 minted for the PXE chainload gap found reinstalling wk-metal-02; FU-260 minted for the Argo controller's apiserver-restart
  hot-loop flooding Loki; FU-259 minted for `talos_cluster_kubeconfig` rendering a stale
  endpoint while plan reads clean; FU-258 minted for Cilium dropping the `kubernetes` Service
  backend on an apiserver restart, parked behind the 1.20.2 upgrade; FU-257 minted for the ownerless loop-CNP enforce flip;
  FU-256 minted for the worker-rides-into-`<stack>-agents`
  question, from oracle's corpus-bucket handoff; FU-255 minted for the mirror floating-tag
  revalidation audit, homelab#1739/#1779/#1796.
  2026-09-18: FU-254 no detector for a substrate version going stale or EOL, FU-253 the VMs' generic+stale declared `install.image` — both from the upgrade-verb probes; FU-252 the management-apply refusal has no detector — it stood four days and 1101 ticks unseen. 2026-09-17: FU-251 the opencode.ai re-park after the session header proved wrong, FU-250 the RUM 403 wedging the consumer Workspace red, found at FU-206's build. 2026-09-16: FU-246 the workers' Talos version, FU-247 the kernel-oops alert, FU-248 the targeted-apply guard, FU-249 the responder pause; FU-242 the tofu-controller spike, FU-243 the CP endpoint VIP, FU-244 transient PXE flags out of git — the box-first program, ADR-132/-133. 2026-09-15: FU-241 minted for the shared pve/nx-02 SSH seed key, #1718. 2026-09-13: FU-240 minted for the box↔jail devbox version skew; FU-239 minted for the read-all token's standing group-order permutation; FU-238 minted for the box planning tofu/github; FU-237 minted for the management sentinel build, ADR-131; FU-236 minted for the sentinel-App cutover, ADR-130. 2026-09-12: FU-235 minted for the kata-label drift; FU-234 minted for the homeless Optane/`fast` tier after thinkcentre left cluster duty. Previously 2026-09-10: FU-229 minted for the Garage SLO/churn loose end; a SEVENTH mis-mint of the 09-07 shape — a grep for `\*\*FU-228\*\*` matched THIS line and the author minted 229; renumbered before merge. The counter lagged a SIXTH time — it read FU-214 while FU-215 was live; before that it read FU-209 while FU-210..212 were live — FU-200/FU-201 minted 2026-09-01 while it read 200; before that FU-190..194 / FU-183/FU-185. ⚠ 2026-09-07 was the OPPOSITE failure and is worth its own line: the counter was CORRECT at FU-223, and the author minted FU-224 anyway — having grepped `FU-[0-9]{3}` and matched this very line, reading the counter's own value as an existing entry. Caught in review, renumbered. Grep for a `**FU-NNN**` ITEM, never a bare id, and trust this line.). Burned ids (issued, then retracted without ever being work) are declared
  right here in the form `FU-NNN burned — <why>`, permanently — the declaration IS the record, and
  the lint reads this line so a reference to a burned id doesn't register as dangling:
  **FU-122 burned** — filed then retracted 2026-07-31 as already-shipped (ADR-093).
  **FU-226 burned** — minted 2026-09-08 for a pve GPU swap, retracted the same hour: a hardware
  want, not a platform loose end — it lives in the private hardware repo (R9), homelab has no stake.
  **FU-141 burned** — filed 2026-08-05 for un-reaped ephemeral OpenRouterKey CRs, retracted the
  same day: already **openrouter-operator#10**, and a fixer-enabled repo's own issue is where that
  belongs (routing table) — the prior-art grep covered this tracker but not the repo's issues.
  **FU-175 burned** — skipped in numbering, never issued: FU-176/FU-177 were filed without
  touching the counter (found by the PR#596 review reconciling it, 2026-08-19).
- **An archive entry may stamp the date after the id or at the end of the entry** — both
  `- **FU-NNN** *(archived YYYY-MM-DD)* — …` and `- **FU-NNN** — … *(archived YYYY-MM-DD)*` are
  read by the freshness check. Prefer the first; it sorts and scans better.
- **Terms link on first use, items link their evidence.** A ⚓ term from [`glossary.md`](glossary.md)
  used in an item links its owning doc or the glossary on first use (`docs-graph-lint` check #3 reads
  this file as one doc); a doc an item links back to must mention the id (`follow-ups-lint`).
- **This file is the only tracker.** Everywhere else — docs, code comments, commit messages —
  reference the id (e.g. `FU-007`), never a free-floating `TODO`. Detailed context may stay near
  the code/doc it concerns; the item here carries the one-liner and links to the detail.
- **An item is ≤10 lines** — symptom, why it's deferred, the next concrete action, a link. That's
  the whole contract, and it is the one that gets broken: between 2026-07-03 and 07-31 the open
  count grew 14% while the file grew 288%, because items became documents.
- **Outgrown it? Make it a POINTER.** The detail moves to a doc (routing table in `CLAUDE.md` →
  "Where things get written down") and the item keeps **status + next action** only. Split of
  authority: **the FU line owns "is it done, what's next"; the doc owns mechanism, evidence and
  history.** The doc backlinks the id. Never grow a second copy here afterwards — edit the doc.
  A pointer's doc **survives archival**: it's documentation, not tracker residue.
  Postmortems go to `docs/incidents/`, programs to `ROADMAP.md`, decisions to `docs/adr.md`.
- **THE BAR — the tracker is for work someone must do LATER, and nothing else.** Measured
  2026-08-07, and the trend is the argument: creation ran **2.4/day** over FU-050→100 and
  **4.4/day** over FU-100→153 — the last 53 ids took 12 days against 24 for the first 100. The
  Agents share of OPEN items went **34% (ids <100) → 92% (ids ≥100)**. The block did not grow
  because the loop has more debt; it grew because every finding became an entry.
  Before adding OR extending, three tests:
  1. **Can I just do it?** Context in hand, ≲5 min, safe now → **do it**. ⚠ **This applies to
     EXTENDING an existing item exactly as it applies to filing a new one** — it keys on the
     ACTION, not the artifact. Adding "Next: port the hold to `ci-red`" to FU-146 was deferring a
     five-minute fix I had already written twice; "I'm only updating an FU" is not an exemption,
     and that is precisely how it was rationalised (2026-08-07).
  2. **Is there a next action someone could start today?** No → it is NOT an FU. A finding goes
     to the owning doc, a session's story to `agents/coordinator/TICK-LOG.md`, an undecided fork
     to `docs/spikes/`. "Watch whether X recurs" is an observation, not a deferral.
  3. **Does an existing item already own this?** Extend it — but re-run test 1 first.
- **Resolving an item:** move it to [`follow-ups-archive.md`](follow-ups-archive.md) in the same
  commit as the fix, trimmed to the grep residue (what shipped / when / acceptance evidence /
  gotcha — a few lines) with an *(archived YYYY-MM-DD)* stamp. References elsewhere stay legal
  while the id is archived; when the entry expires out of the archive (≈a month, once stable),
  delete it and scrub only the **TODO-shaped** references — `FU: FU-NNN` gap-register cells and
  `Tracked by` lines (ADR-116, the name-anchor ruling). Every other reference is a **provenance
  name** — a stable coordinate in a never-reused namespace — and stays untouched, forever.
  **Repointing a TODO-shaped ref = the doc link survives**: the pointer loses the `FU-NNN` but
  gains a link to the doc that outlived it, so the trail doesn't go cold.
  `devbox run follow-ups-lint` checks all of this (TODO-RETIRED fails, TODO-ARCHIVED warns).
  **Then ask who was waiting on it** — `grep -n 'FU-NNN' docs/follow-ups.md` and re-read every
  hit as if filed today. Resolution is a graph walk, not a single edit: the item you just closed
  is often the reason another was deferred, and that one may now be a five-minute fix that
  unblocks a third. Keep going until a pass turns up nothing — one closure can drain a chain, and
  a chain left un-walked is how items outlive their blockers (23 of 57 open items cite an
  already-archived id, 2026-08-07).
  **Check for this actively:** FU-080 sat open at 91 lines with zero remaining work because its
  last leg was archived under a different id. A long item is a good place to look for a done one.
- **Adding an item:** next free id, into the fitting theme section (ids don't encode theme), bump
  the counter above.
- **Single-writer contract (2026-07-10):** this file is operator/meta-edited ONLY — agents never
  append here. The sequential ids + the counter line make it a guaranteed merge conflict under
  parallel writers, and it doesn't scale past platform loose-ends anyway. Agent-discovered
  shortfalls go to the governing repo's `specs/` as id-free `⚑ gap` flags (ADR-086, oracle-fleet
  ADR-OF-003); coordinator session findings go to the TICK-LOG.

_Last updated: 2026-10-14 (fu-sweep: machine lane reconciled since 10-03; GitOps & platform, Hardware & nodes, Secrets, One-time ops fully classified + the Agents items touched since 10-03 or lint-flagged — slice rule, no corpus load. **Archived (4):** FU-304, FU-312, FU-296, FU-260 (+FU-225 expired). **Soak FAILED:** FU-032 (flapped again 10-12, now on a CP). 26 items pointer-ized or trimmed to ≤10 lines, detail moved into their docs; lint 0 OVERSIZE. Previous pass 2026-10-03: fu-sweep over the WHOLE tracker, no-judgement scope — four parallel
slice subagents, machine lane reconciled since 09-24, Agents classified WITHOUT the corpus load
(operator-typed only), so design-shaped agents items were left untouched. **Archived (10):** FU-246,
FU-212, FU-129, FU-219, FU-154, FU-148, FU-150, FU-224, FU-097, FU-151 (+FU-173/149/184 expired). **Soaks FAILED:**
FU-134 (both real-ride `/search` calls timed out), FU-102 (6/28 probe ticks die at max-turns inside a
Succeeded workflow). **PRs:** #2198, #2201, sleep-tracking#168, snore-recorder#43 + #2199 (FU-244),
circles#97 (FU-151) merged; #2200 (Argo v4.0.8, FU-198/FU-260) unarmed — a live controller restart.
Previous 2026-09-24 (fu-sweep over **Hardware & nodes + GitOps & platform**, the two fastest-growing
sections since 08-25; the Agents block was out of scope. **Archived:** FU-215 (quiet 8 d after the do-ip6 fix),
FU-203 (the 09-23 GC took the bucket 19.6→9.8 GiB), FU-076 (now a detector, `MgmtNodeInstallDrift`).
**Soak FAILED, re-scoped:** FU-224 (bucket-sync still 58–70 % throttled at 2 CPU → it is CPU-bound).
**Re-scoped on evidence:** FU-192 (b) answered — the largest tenant peaks at 1.23 MB/s against 8, so the
limit stays; FU-235 (all 7 axes 0 on 13 nodes → only `install_disk` left); FU-208 (the pve hold is
gone at 48 %); FU-274 (the store is the fs volume now). **DO-NOW:** FU-286's talosctl pin → PR#1963.
FU-288 moved into its section, and the counter was corrected. Previous 2026-08-25 (fu-sweep after the evening board-sweep, machine-lane reconciled by
substance: **FU-149 archived** — the 14d read says ordinary days 0–6, the cap bound only on real
storm days; **FU-168's (a) soak read FAILED** — cron-woken dispatches persist (2 and 5 in 24h),
the emitter hunt is live on #459; **FU-147 fired live 2026-08-24 and mis-fired** — the landing-PR
class fixed via #868→PR#873, one clean organic fire still owed; FU-058 re-fire DELIVERED r1
(PR#918) + the batch filed #927–#932; FU-093's Garage-metrics leg queued as #934, fstrim
scheduled PR#925; FU-102's first enablement = platform, wedged on #933 (checkpoint counts the
post-launch bucket as an open child — G-B cannot assemble); FU-173 pinned + archived. Previous
2026-08-11 (fu-sweep over the Observability & evidence subsection, after the
first board-sweep: **FU-058 corrected** — the 08-10 "guard-refused" reading was false, five
latent retro-lane bugs fixed + first report DELIVERED (PR#246); **FU-133 pointer-ized** —
remaining legs (a)/(c) queued as homelab#252/#253 (#253 blocked-by #244); FU-159 + FU-158 to
the operator (FU-158's self-test pattern hit its third instance); FU-164/140/160/102/067 still
valid; out-of-scope flags for the next pass: FU-147, FU-144 (Merge-path/Dispatch). Previous
pass 2026-08-07 (fu-sweep over the Dispatch + Merge-path subsections: **FU-111
archived** — body-line dep reader retired after native edges proven flowing, oracle-fleet#84
migrated first; FU-133's set-pass watch VERIFIED on the first live ≥2 set (#68 vs #118, correct);
FU-143 UNBLOCKED (#34 in the pinned image) — re-soak gated on homelab#118; FU-146 2-of-3 clauses
proven live via Loki; FU-144/FU-150 pointer-ized. Previous 2026-08-06 (docs-cleanup comb:
FU-130 re-scoped after its three merges, FU-106
widened to own the schema-blind kinds, FU-046/FU-102 pointers corrected, **FU-144 filed**.
Previous pass 2026-08-05 (bug sweep before the next stack launch): archived FU-068, FU-120,
FU-128, FU-132, FU-138, FU-139; FU-127/130/131/134 part-shipped and re-scoped in place; new gates
`stack-lint` KEY-01/KEY-02/PVC-01/CACHE-01 + `devbox run model-id-test`. Pass 2026-08-03:
six OVERSIZE items pointer-ized into
`docs/agents/{iac-lane,issue-authoring,observability-and-retro,model-routing}.md` +
`docs/storage-ledger.md`)._

## Secrets (the "secret cleanup" track)

- [ ] **FU-005** — Decide whether an Infisical break-glass second admin is worth codifying (one
      super admin today, signups disabled).

## GitOps & platform

- [ ] **FU-299** — **Backups: Longhorn target LIVE + drilled; every CNPG Cluster backed up by default (ADR-147) + drilled.**
      Longhorn → [`longhorn-backup.md`](longhorn-backup.md); Postgres → [`postgres.md`](postgres.md) §Backups (plugin,
      admission-wired, daily + `pg-backup-now`; infisical-pg restore 85 s, 704/704 tables). Rollout incident:
      [`2026-10-03-cnpg-wire-switchover-deadlock`](incidents/2026-10-03-cnpg-wire-switchover-deadlock.md).
      Daily job + UniFi settings-only `.unf` (01:00Z; the never-working autobackup was a corrupt Mongo
      collection, dropped) = PR#2196, applied + first run 2026-10-03 (3 backups, unit = epoch s).
      UniFi schedule as code (init container) + `UnifiAutobackupStale` belt = PR#2197, live 2026-10-03.
      **Next:** off-site copy — PARKED by the operator (2026-10-03: AWS-class target needs IAM + billing
      limits first; no cluster write access to an unbounded store yet) → a periodic restore drill.
- [ ] **FU-298** — **The OPNsense plays do not converge a FRESH router — one defect left.**
      Upstream `oxlorg.opnsense` `acme_account` `register()` POSTs `acmeclient/accounts/register`
      without the uuid → 404 (identical in 25.7.8 and 26.1.11; the controller wants
      `register/<uuid>`); prod hides it (account already registered); the test-VM harness
      pre-registers as a workaround (#2105). (The second defect — `bgpd` never started on first
      enable — fixed 2026-09-29 by #2115, drill green.) **Next:** an upstream issue at O-X-L
      (operator's call), then a pin bump + drop the harness workaround.
- [ ] **FU-297** — **OPNsense test VM + rebuild drill + the CARP pair: POINTER.** Router-config PRs validated on
      VM 9110; a weekly from-nothing rebuild drill on the box (`mgmt-opnsense-drill.timer`) scores prod's click-ops
      residue — [`opnsense-test-vm.md`](opnsense-test-vm.md) (§The realism score has the drill record). The pair is
      COMPLETE (2026-10-09, both windows + WAN leg; history: [`router-move.md`](router-move.md) §Status). Drill GREEN
      since 2026-10-11 (score 56). **Next:** code or accept the 56 click-ops rows the pair left in prod (`OPNsense/Kea`
      36, `virtualip` 17, `hasync` 2); CI for `scripts/opnsense-drill.sh` (#2493 note). Relates FU-013, FU-298, FU-307.
- [ ] **FU-310** — **dind probes the HTTP-only registry mirrors over HTTPS first: one dropped SYN + a dial
      timeout per pull.** Rides list the mirror VIPs as `insecure-registries` (`agents/agent-session.sh` daemon.json)
      and pull by bare IP (`192.168.40.31/playwright/…`), so docker tries :443 before :80; the ride CNP allows :80
      only → `AgentWorkerEgressDropped` (oracle-fleet 12/2 h on 10-09, sleep-tracking 78/7 d). Allowing :443 does
      NOT help — probed 2026-10-09: the VIP blackholes unserved ports (:80 connects instantly, :443 times out, no
      RST). **Next (operator's call):** (b) mirrors as explicit `http://` endpoints (dind `registry-mirrors` /
      containerd `hosts.toml`) so docker never tries HTTPS — covers docker.io-style mirrors, needs a shape for
      IP-addressed refs; or serve the mirrors over HTTPS (LAN CA/cert — removes `insecure-registries`). Relates FU-072.
- [ ] **FU-309** — **Nothing moves displaced pods back after a maintenance window.** 2026-10-09 DIMM
      window: wk-04's pods (grafana, unifi, openrouter-proxy, registry, mcr mirror, …) rescheduled onto
      wk-01/wk-02 and stayed — both at ~99 % of 3900 m CPU requests while wk-04 sat at ~20 % of 15900 m;
      the pinned fstrim guards failed admission (`OutOfcpu`) until #2404 gave them a PriorityClass, and
      the preemption victims were single-replica registry services. Priority ranks, it does not rebalance,
      and every host/node window recreates the pile-up (TICK-LOG 2026-10-09 14:05–15:05Z). Operator:
      "I will need one eventually, not a priority now." **Next:** evaluate the kubernetes-sigs descheduler
      (`LowNodeUtilization`, PDB-respecting, as a CronJob or Deployment under `argocd/resources/`) vs
      topology spread on the displaced Deployments; land it the detector-first way (a node-imbalance
      alert from kube-state-metrics requests first). Relates FU-289 (the window), FU-285 (co-located replicas).
- [ ] **FU-307** — **No belt says "the pair's MASTER has no WAN."** 2026-10-08 19:40Z→04:46Z pve
      held `.1` as MASTER with its WAN port carrier-less for nine hours; `RouterPairMasterCount` (1
      master) and `RouterWanGateSilent` (gate alive) stayed green, while the gate's own gauges
      (`router_node_carp_master{vmid="9171"} 1`, `router_node_wan_link 1`) carried the fact with no
      rule reading them — and carrier/`WAN_GW` state is not exported at all. Deferred then by
      the gate restart's WAN blip — UNBLOCKED 2026-10-09: a gate restart on the BACKUP node costs nothing
      (proven in the WAN-leg window; put nx-02 in maintenance first, or roll pve then nx-02).
      **Next:** the gate's textfile adds `/sys/class/net/<wan-nic>/carrier`; rule `RouterMasterWanDark`
      = master ∧ ¬carrier, `for: 2m`, promtool fixture at the 10-08 timestamps. ADR-144/145.
- [ ] **FU-208** — **runner image is oversized for the sentinel (4.9 GiB for a devbox-lint job).**
      Rollout shape SHIPPED 2026-09-04 (PR#1367): two DaemonSets split on `topology.kubernetes.io/zone`
      — metal two-at-a-time, pool VMs one-at-a-time behind an init gate on
      `pve_lvm_thin_pool_data_percent` < 75. The 09-05 "permanent hold" (post-trim floor ~80 %) is gone:
      pve's pool reads 48 % on 2026-09-24 and `runner-image-prepull-pve` is 4/4 Ready. **Next:** a
      sentinel-scoped closure (or a second, small image for `agents/coordinator/sentinel-argo.yaml`) —
      hundreds of MB, not 4.9 GiB. Relates FU-015, FU-093, FU-207, #80.

- [ ] **FU-205** — **WAN-upstream accounting: one view of what hits GitHub/PyPI/ghcr/… from
      where** (operator ask 2026-09-02, after two same-day WAN-limit incidents). **Hard constraint
      (operator): FAMILY traffic must never reach the cluster.** Raw router NetFlow therefore cannot go
      to Prometheus unfiltered, and flowd has no src-CIDR filter. So it is either the **homelab VLAN**
      (per-interface capture as a structural filter) or router data stays router-local. The CI VMs and
      the jail host are outside Hubble and need host-side counters (nftables per-provider sets →
      textfile). Live already: Hubble DNS/drops, `github_rate_limit_remaining`, Insight on-router.
      **Next:** the design pass (VLAN vs router-local, the VM counter leg, the Grafana join). Link:
      the 2026-09-02 loop-outage postmortem §Residuals.

- [ ] **FU-204** — **C4/C5's bare-mention exclusion is a silent-stall limbo** (2026-09-02, fleet#345: r1 died
      on a rate-limit, assembly PR#346's coverage-map bare mention held it out of the stall wake AND the review
      flip). **RULED 2026-10-14** (design-agents sitting): neither age-bound nor wake-with-marker — the #1720
      precedent: `C4C5_SEL`'s open-PR test reads `STRONG_LINK_JQ` (false hold = indefinite stall, false release =
      one wasted ride + the launcher's open-PR refusal). **Next:** homelab#2562 (queued); archive when it merges.

- [ ] **FU-223** — **Does Longhorn honour `fsync` end-to-end — and what does it cost in CPU?** The
      2026-09-07 A/B measured a Longhorn replica-1 volume at **1.9× the fsync'd IOPS of raw XFS on the same
      device**. That is not physically possible for a flushed write, so the engine plausibly acks flushes
      it has not pushed. It matters because ADR-114's `metadata_fsync = true` exists to stop the LMDB wipe
      mechanism, and on a Longhorn meta volume it may not mean what it says. The same rig answers the CPU
      question (the engine's cost is CPU: `instance-manager` 0.5–0.9 core per zone node). Numbers:
      [storage-ledger](storage-ledger.md) §2026-09-07 + its amendment. **Next:** one experiment,
      same device: write with fsync → hard-stop the replica → verify the acked writes survived, and
      measure CPU per fsync'd IOP at queue depth one, raw XFS vs replica-1. It settles fsync honesty
      AND whether Garage moves to node-local storage. Not on the X240. Link: ADR-114, FU-137.

- [ ] **FU-229** — **Garage SLO breached on its own 30-day window and nothing alerts; CI-hour
      write churn unattributed.** 30-day reads 2026-09-10: availability garage-0/1/2 98.0/99.90/98.1 %
      (objective ≥ 99.95 %); p99 read 4.1 s / list 10.3 s (objectives 2 s / 5 s); rules exist (#1588).
      **No belt yet, by ordering (operator, 2026-09-13):** garage-2 leaves the X240 FIRST (resights 09-13/16/22).
      **Nightly shape (2026-10-03):** Garage's lifecycle worker (00:00Z) expires ~60–72k `allure-reports`
      objects/night since 10-01; meta volumes take 20–44 MB/s until table GC drains (~02:30Z), wk-metal-01
      `sdb` ~90 % busy → `GarageClusterFlapping`. **Next, in order:** (1) garage-2 off the X240 (third std
      SFF; ledger via FU-137); (2) THEN alerts on `garage:s3_latency_seconds:{p50,p99}_5m` + the 30d burn
      rate; (3) attribute one CI-hour window by bucket (the #499 method). Link: FU-093, FU-137.
- [ ] **FU-280** — **The first-party registry left Garage S3; the roll is bound by pve's uplink, not the volume. POINTER.**
      CUT OVER 2026-09-24 (ADR-121 amended): `registry.teststuff.net` = `registry-fs` on the 150Gi `registry-data`
      volume. **2026-10-14 the whole S3 half is gone** (#2558, #2560; FU-279's MPUs aborted first). Re-measured
      10-14, network first: ~75 MB/s uncontended; the 10-13 ~10 MB/s does not reproduce (a latency stall during
      the m70s PAUSE storm). A two-node roll from pve VMs saturates pve's 1 GbE (the hairpin through the wk-04
      ingress VIP). **Next (operator):** shorten the path (registry-fs beside the ingress, or in-cluster pullers
      off the VIP) vs accept ~21 MB/s per pve node; separately, `intel1` co-location (registry-data beside
      garage-0). Evidence: [`spikes/registry-filesystem-backend.md`](spikes/registry-filesystem-backend.md) §2026-10-14 re-measure.
- [ ] **FU-274** — **First-party images still ride the ghcr pull-through mirror.** Its three biggest
      tenants are ours (`oracle-fleet-ingester`, `agent-base`, `oracle-fleet-static-site`: 320 revisions on
      2026-09-22), so our release churn sets the mirror's size. The registry's only size knob is the TTL, and
      that TTL nearly filled it (720h left over from FU-196 v0; #1870 set 168h + 150Gi). Serve
      first-party images from `registry.teststuff.net` (ADR-121's "later"). The mirror then holds
      third-party images only. **Next:** per-repo keep-sets there first (only oracle-fleet has a
      retention policy; the store is the 150Gi filesystem volume since FU-280's 2026-09-24 cutover, not
      the 48Gi bucket), then dual-publish → pin flip per image. Relates FU-196, FU-203, FU-280.
- [ ] **FU-194** — **homelab#541's kernel-log carve-out is STILL not true for a jail, after
      ADR-118 shipped** (found 2026-08-27 by testing the claim rather than restating it). The
      carve-out promises "any session with LogQL access reads kernel-log lines" — the motivating
      use case for the whole read door. But `kmsg-reader` runs in namespace `loki`, so its lines are
      tenant **`loki`** (verified: 11 kmsg streams there, 0 elsewhere), and granting a jail that
      tenant hands over the log store's own namespace. **Next:** either move `kmsg-reader` to its
      own namespace so the tenant is grantable alone (one namespace + a RoleBinding), or accept
      kernel truth as operator-only and FIX THE CARVE-OUT TEXT in
      `agents/coordinator/agent-read-rbac.yaml`, which promises a capability nothing provides.
      Detail: [`loki-tenancy.md`](loki-tenancy.md) §How a stack jail reads its logs. Relates FU-193.

- [ ] **FU-193** — **The Loki read door serves a self-signed, unpinnable cert** (2026-08-27,
      ADR-118 step 3). kube-rbac-proxy gets no `--tls-cert-file`, so it generates a cert at startup
      and a new one on every restart — callers use `curl -k` and cannot pin. Authentication is
      unaffected (the bearer token is TokenReviewed server-side), so this is
      confidentiality-vs-LAN-MITM, not identity. **Next:** decide whether a jail-facing API earns a
      `teststuff.net` HAProxy/ACME pair (ADR-088) or whether LAN-trust is the right posture, as
      `argo.teststuff.net` already chose. Detail: [`loki-tenancy.md`](loki-tenancy.md) §How a stack
      jail reads its logs.

- [ ] **FU-192** — **Three residues of the ADR-118 tenancy flip, all deferred deliberately**
      (2026-08-27, step 2). (a) Grafana's tenant list is a SNAPSHOT — Loki has no wildcard tenant,
      so an all-namespace view must enumerate, and a namespace added later is invisible there
      until someone edits the datasource. (b) ANSWERED 2026-09-24: the per-namespace baseline peaks
      at 1.23 MB/s (`argo`, 25 d), next 0.35 (`longhorn-system`), so the per-tenant 8 MB/s binds only
      a runaway and stays — the win is banked (doc updated). (c) the OTel rail writes under a static
      `monitoring` tenant. **Next:** (a) — generate the datasource's tenant list from the live
      namespaces instead of a committed snapshot. Detail + options:
      [`loki-tenancy.md`](loki-tenancy.md) §What tenancy costs the operator.

- [ ] **FU-191** — **The admission-controller seat: engine UNDECIDED (Kyverno vs OPA Gatekeeper),
      gated on a SECOND use case** (operator, 2026-08-27). §L0b settled the **CLI** seat only; a
      webhook in the pod-creation path is a different job (`failurePolicy`, HA — a broken one
      blocks pod creation cluster-wide), so it is decided on evidence per the ≥2-pattern rule,
      not by the CLI incumbent. **Use case 1** is tenant labelling — mutating a pod to carry the
      tenant its namespace declares, which is what would let ADR-118 go tenant==**stack** without
      a namespace→stack map in Alloy ([`loki-tenancy.md`](loki-tenancy.md) §Why tenant ==
      namespace). **Next:** collect use case 2, then judge on webhook blast radius, authoring
      model, and whether ONE engine can serve both seats. ⚠ Nothing is built until it is chosen.
      Relates FU-106 (IAC-G04), ADR-118; the §L0b narrowing is [`iac-lane.md`](agents/iac-lane.md).

- [ ] **FU-190** — **A mounted-ConfigMap change in `argocd/resources/**` does not roll its
      workload; the trigger is a hand-bumped annotation, and forgetting it is SILENT.** Four sightings:
      Alloy + `StatefulSet/loki` (08-27, ADR-118), `blackbox` (08-31, a belt shipped dead), `cf-api-proxy`
      (09-03). **Audit 2026-10-03:** of 20 long-running raw workloads mounting a ConfigMap, 5 use
      `configMapGenerator`, 6 a hand-bumped annotation, 9 NOTHING (blackbox, cf-api-proxy, loki-rbac-proxy,
      3 mirrors, registry, registry-fs, runner-image-prepull-pve). **Next:** choose kustomize
      `configMapGenerator` (proven in [`otel-collector/`](../argocd/resources/otel-collector/kustomization.yaml);
      ⚠ with prune, a rollback references the pruned old CM) or a CI check that reddens when a config
      moves without its consumer's annotation. Relates ADR-083.
- [ ] **FU-137** — **Garage durability + metadata reclamation: POINTER.** Fired 2026-08-24 (meta LMDB
      wiped with the pve thin pool — [incident](incidents/2026-08-24-pve-thin-pool-garage-meta-wipe.md),
      homelab#884). **ADR-114** + addendum + 2026-09-07 amendment answer both halves; mechanism and
      numbers live in [`garage.md`](garage.md) and the [ledger](storage-ledger.md). Done: rf=3 across
      three physical zones (09-07); the unattended rotation loop (09-09); garage-1 on its own PM961
      (09-12); CNPG required zone anti-affinity (09-21, #1840/#1842, oracle-iac#900); CNPG replica-1
      (09-21, #1843 — ledger §2026-09-21; stack clusters wait on a zone node label). **Next:** the
      backup CronJob (ADR-114's logical-deletion class). Operator intent: metadata maintenance is
      unattended. Relates FU-013, FU-012, FU-093, FU-223, ADR-031.

- [ ] **FU-072** — **The kata service-VIP workaround is REMOVED; soaking: POINTER.** PR#1372 (2026-09-04)
      deleted `resolve_ep`, the rewrites and `dnsPolicy: None`, so every ride uses service DNS. The
      service-VIP leg is PROVEN (oracle 432-r1). The dind/kind leg is unexercised. History, symptom
      matrix, the two legs and the regression signature (a bare pod IP in `AgentWorkerEgressDropped`
      → `git revert 773ad63e`): [`spikes/kata-service-vip.md`](spikes/kata-service-vip.md) §Removal
      and soak. **Next:** watch the first in-pod `devbox run e2e` (a `task/build` ride) under kube-dns;
      once soaked, drop the dead CNP LAN-resolver DNS leg and the `endpoints`-read grants. Relates
      FU-116, FU-187.

- [ ] **FU-007** — **Forgejo = major-outage FALLBACK ONLY (operator ruling 2026-09-13, after
      looking at it more than once): keep the cluster alive with the bare minimum during a GitHub
      outage — never the live read path.** The loop and its permissions are GitHub-native; a
      primary-git flip multiplies complexity for no day-to-day gain. WAN minimization is done IN
      GitHub instead: authenticated, on-change fetches everywhere (PR#1333 for the loops; the
      management box's `mgmt_clone` fetched anonymously every 5 min from two loops ≈576/day — fixed
      2026-09-13). History: the `sleep-lab` pull-mirrors broke at the 2026-08-04 DB migration
      (`SyncMirrors`; fix = the idp session's orphaned-repo recipe). **Next:** repair the mirrors as
      the backup-grade belt (≈6h stale is fine for a fallback) + the cutover recipe in
      `argocd/README.md` §Forgejo cutover stays a documented emergency procedure, not a plan.
- [ ] **FU-010** — Infisical↔CNPG uses `sslmode=disable` (node-pg rejects CNPG's self-signed
      cert). Fine pod-to-pod; revisit if Cilium transparent encryption lands.
- [ ] **FU-012** — **Remote/encrypted tofu state backend + the dangerous creds off the jail:
      POINTER.** Hard prerequisite for anything that plans/applies off the operator's machine (the
      FU-097 drift belt, the out-of-cluster applier). Migration state, the per-root cone rulings,
      the `use_lockfile = false` ruling and the runbook: [`docs/tofu-state.md`](tofu-state.md) —
      3 of 5 roots on encrypted Garage state since 2026-08-04; **`main`'s state + the dangerous
      creds MOVED to the R12 box 2026-09-13** (the jail applies main through `devbox run mgmt-tf`).
      **Next:** box-scoped credentials — the `mgmt/scripts/mgmt-provision-secrets.sh` table is the JAIL's
      entries, swapped one line each as minted; **first: a scoped read-only kubeconfig for the box's
      plans** (the #1635 finding — `main` + `cloudflare` plan PR heads with the admin kubeconfig;
      stage 1 denies new `kubernetes_*` data sources / `import` blocks meanwhile). Snapshots: #1834. Relates FU-097, FU-136.
- [ ] **FU-013** — Home Assistant `/config` (and other stateful data) backup → Garage S3 with the
      bucket-id in git — the missing "boot-from-git" DR leg (Longhorn replicates in-cluster, it
      doesn't DR). `tofu/homeassistant.tf`. **Router leg LIVE 2026-09-29:** prod users + keys
      minted (#2108), un-suspended (#2117), first run proven (object decrypts to a valid config,
      metrics in Prometheus); `OpnsenseConfigUnattributedRevision` fired on the root-key mint as
      designed. **Next:** the playbooks move to the `automation` key (ddclient install → assert;
      dnsmasq-dhcp.py off root) — then the click detector is quiet; the HA `/config` leg stays open.
- [ ] **FU-039** — **Platform self-service (XRD claims) — next legs: POINTER.** Design,
      completion table and open legs of the public-ingress leg (test claim, ha retrofit, zone-phase
      rulesets, product zones, the edge-metrics GraphQL poller whose first deliverable is the missing
      edge-5xx belt): [`docs/cloudflare.md`](cloudflare.md) §PublicRoute + §Observability. The first
      consumers are live and checked (homelab#1334). Per-stack thin PRs remain: LAN subdomain opt-in
      (ADR-092), git repos, AppProject/ns. **Next:** zone-phase ruleset aggregation (one claim per
      profile per zone today) and the ha retrofit as consumer #2. Program: `ROADMAP.md` → "Platform
      self-service via Crossplane". Relates ADR-076, ADR-085, ADR-092, ADR-101.
- [ ] **FU-282** — The PublicRoute **origin mark** reads the homelab's WAN address from
      `wg.teststuff.net` — the WireGuard endpoint's ddclient record (ADR-090). Correct value,
      misleading name: a reader of the Composition has no reason to expect the VPN endpoint to be
      load-bearing for an edge header, and renaming/retiring that record would silently break the
      mark. **Next:** give ddclient a second target (`egress.teststuff.net`,
      `ansible/group_vars/opnsense.yml` + a router apply) and repoint `$egressRecord` in
      `argocd/resources/publicroute/composition.yaml` — one line each, but it needs a live
      OPNsense apply, which is why it is not in the build. Cosmetic until then: the mark works.
      Detail: [`docs/cloudflare.md`](cloudflare.md) §PublicRoute — origin mark.
- [ ] **FU-055** — Flip the `oracle-fleet` repo `private` → `public` when that stack reaches its
      planned open-sourcing milestone ("P3" in its design doc, kept out-of-repo). The flip is a
      `tofu/github/repos.tf` visibility change + `allow_forking = true` (GitHub forces forking on
      public repos), applied outside the jail. `oracle-iac` stays private permanently.

- [ ] **FU-051** — **Prove a dep bump flows E2E for the operator-chart and pod-image shapes**
      (the app+chart shape is proven — sleep-tracking digest bump 2026-07-05 → sleep-iac deploy PR
      auto-merged). snore-recorder leg BUILT 2026-08-02 (snore-recorder#15 + sleep-iac#57) and PROVEN
      2026-09-27 (sleep-iac#93 → Pi converge in 3 min); pod-image shape PROVEN (agent-runtime#160 →
      homelab#2062). **Remaining:** one organic, image-affecting Renovate bump on openrouter-operator
      flowing to a deploy PR. Relates ADR-084.
- [ ] **FU-237** — **Build the management sentinel (ADR-131)** — plan-on-PR for the tofu roots,
      evaluated on the R12 box behind a pre-execution input allowlist, verdict-only back under
      `homelab-sentinel`. **Steps 1–3 BUILT 2026-09-13**; (a) the flip LIVE (PR#1617); (b) the
      in-cluster no-root poster LIVE (#1631); `mgmt-policy-test` is a `ci` step; **(e) the
      stage-1-refusal wedge (no merge, no review — #1718) RULED + BUILT 2026-09-16, PR#1721:**
      gate unchanged, `devbox run mgmt-human-plan -- <pr>` posts the human plan's verdict, a full
      `mgmt-tf apply` stamps the apply baseline, `provider "…" {}` denied everywhere — §MB3 "When
      the box refuses". **Next:** (c) the per-role user + env split; (d) the doorbell edge (lower
      priority). Design + build state: [`management-box.md`](management-box.md) §MB3. Relates
      FU-012, FU-097, ADR-130.
- [ ] **FU-241** — **One SSH seed key now opens root on BOTH hypervisors.** `tofu/providers.tf`'s
      `nx02` alias reuses `var.proxmox_ssh_private_key_file` (the pve seed), so a compromise of the
      jail/box key is a compromise of pve AND nx-02. Deferred, not ignored: the key is already the
      root-of-trust for pve and splitting it buys nothing until the two boxes differ in trust (a
      guest-workload hypervisor, or nx-02 leaving after the R11 noise trial). **Next:** mint a
      second seed at the first reason to distinguish them; until then the DR step is written down
      in both `providers.tf` and the nx-02 row of `machines/machines.yaml`. Relates FU-012.
- [ ] **FU-244** — **Transient PXE flags leave git (ADR-132 consequence).** `tofu/provisioning/matchbox.tf`
      says groups are transient and holds none — yet `nx_01_diag` was committed 2026-09-16 (f844711a) because
      the live flag existed in git nowhere. Rule: a flag is procedure state, never a commit. Interim shape:
      `tofu/provisioning/flags.local.tf` (gitignored `*.local.tf`) holds per-node groups; flag = write + targeted
      apply, unflag = delete + targeted destroy; the box's provisioning plan shows a live flag as drift until
      unflagged (the belt); a lint refuses `matchbox_group` in TRACKED provisioning files; provisioning.md
      steps 1/6 + the onboarding skill rewritten around it. (`nx_01_diag` is gone — #1822 dropped it,
      2026-09-21; no flag stands in git.) Shape + lint LIVE (PR#2199, 2026-10-04: matchbox.tf header, `machines-lint`
      check 3). **Next / end state:** the reconciler sets and clears flags inside one sync. Relates FU-235.
- [ ] **FU-239** — **`homelab-jail-read-all` plans as a standing group-order permutation (2026-09-13).**
      The API's read-back order for its 146 + 45 filtered groups is arbitrary (not catalog/id/name
      order — measured), provider 5.x compares positionally, and 5.25.0 (#1636) did not fix it.
      Mitigated: `scripts/cloudflare-token-tf.sh` excludes the resource from plan/apply by default
      and runs a targeted plan that reports REAL `+`/`-` elements (`CF_INCLUDE_READ_ALL=1` to
      include). **Next:** re-test on each provider bump; if a release normalizes group order,
      drop the default exclude. Alternative if it never does: hard-code the id list (rejected
      2026-08-12 as a frozen catalog) or `ignore_changes` (loses the widening signal).
      `docs/cloudflare.md` gotcha 3 addendum. Relates FU-156, FU-157.
- [ ] **FU-240** — **devbox version skew rewrites `devbox.lock` (2026-09-13; root cause 09-20):**
      `plugin_version` is baked per devbox RELEASE (nodejs 0.0.4 ≤0.18.1, 0.0.5 ≥0.18.2) and any
      `devbox run` rewrites it, so disagreeing runners flip-flop the lock. Mitigated: `mgmt_clone`'s dirty
      check ignores the lock. 09-20: converge on **0.18.3** — PR#1809 (ARC ARG + the lock) and claude-jail
      `ENV DEVBOX_USE_VERSION` (6f90815). **Broken 2026-10-02:** Renovate #2186 bumped the ARC ARG alone to
      0.18.4 (jail 0.18.3, box 0.17.2, probed 10-03). **Next:** a Renovate rule grouping/excluding devbox
      (upgrades = ONE change: ARC ARG + jail ENV + host + lock); the box closure overrides `devbox`, then drop
      the exclusion; agent-base's base tag. Relates ADR-129, FU-237.
- [ ] **FU-070** — **Main-repo bootstrap: MIDDLE GROUND BUILT 2026-08-03 (operator ruling —
      template repo REJECTED: unexercised templates stale by construction).** `new-stack --from
      <donor>` mechanically copies the shared surfaces from the LIVING donor checkout (content
      can't stale; the surface LIST asserts loudly when it does) + emits a VANILLA deployable
      chart/Dockerfile (pipeline-proof day one — product shape arrives via specs/goal issues)
      + prints the LLM-adaptation worklist (the judgment half). First consumer circles DONE
      2026-08-03 (circles a34b261). **Next:** the cross-stack drift role (roles.md) owns long-term convergence — this
      item closes when that role exists. Relates FU-052.
- [ ] **FU-016** — SLSA Phase-1: cosign signing + SBOM + scan on the hosted runners (both tiers).
      Plan: `docs/slsa.md`.
- [ ] **FU-017** — Merge the two runner GitHub Apps (`homelab-arc-…` + `homelab-runner-registrar`)
      — both need only org self-hosted-runners R/W. `docs/github-setup.md` §2.

- [ ] **FU-185** — **Shellcheck gate on the agent glue.** The 2026-08-24 audit: ~13 shell
      defects, disproportionately SILENT — SC2318 names the exact `local`-expansion bug that
      killed every scout tick for 6 days (#854). ADR-113 rules the split (bash = glue, logic =
      Python, no wholesale rewrite). Known live instance: `meta-needs-attention.sh` can exit 0
      on an empty read after an inner gh failure — the NEEDSMETA arm mass-clears + re-emits
      (flapped 2026-08-23 ×2; the ALERT arm's twin quickfixed f703ec39). **Next:** shellcheck
      in devbox.json + a required `ci` step (`.github` edit, operator lane) and the ~8
      standing warnings burnt down in the same PR. Relates ADR-113, ADR-103, #854.

## Agents
- [ ] **FU-293** — **`scripts/` is one flat directory and path-based ownership cannot cut it.**
      Inventory by executor 2026-09-28 (~26 CI gates, 16 box, 1 cluster pod, ~45 seat-only; 143/146
      commits in a month seat-authored). First cuts the same day: the box's closure → `mgmt/`
      (PR#2088) and the rest of `scripts/` un-owned + worker-authorable under the
      [ADR-142](adr.md) trial (gate-change lens + gate-drift report). **Next:** the trial
      re-reads 2026-10-05 and 2026-10-28 (revert or keep; the box verbs + `mgmt/` stay owned
      until the box is decided); then decide whether the seat-only scripts move out of `scripts/`.

Sub-grouped 2026-08-07 — the block had reached 34 of the tracker's 57 open items and read as one
lump, so nothing could be scanned by concern. The groups are the loop's own stages, not invented
taxonomy: an item belongs where its NEXT ACTION lands. Keep them; adding a sixth group is a signal
the block needs pruning, not more headings.

### Dispatch & issue lifecycle — the scan's clauses, holds, doorbells, and how an item moves

- [ ] **FU-292** — **Runtime-major adoptables have no harvest.** The migration lens now lists what a new
      Python/Node/Go release lets the code adopt as ordinary `Follow-ups:` bullets (PR#2025 + this
      change), but a Renovate PR has no container (ADR-127), so no merged-closeout harvest turns them
      into an issue — the seat files one backlog issue per runtime bump by hand (openrouter-operator#80
      → the py314 items landed in #82). **Why deferred:** the container rule is a design ruling; the fix
      is a harvest target for dependency PRs (one issue per runtime bump on the repo), not a lens edit.
      **Next:** decide the harvest's owner (coordinator scan at the bump's merge vs the stint closeout)
      in a design sitting with #2014; until then the lens tells the reviewer to write the bullets anyway.
- [ ] **FU-306** — **ci-runner VM replaces are still a human apply; the attended verb is proven.**
      `scripts/runner-maintenance.sh run` recreated both runners 2026-10-08 (incident
      [2026-10-06-ci-runner-disk-full-key-in-plans](incidents/2026-10-06-ci-runner-disk-full-key-in-plans.md)).
      **RULED 2026-10-14 (runner pin):** Renovate-track `github_runner_version`, and a pin bump must NOT replace a VM
      (it lands at the next attended recreate; the runner self-updates in place). Order: homelab#2567 (tofu half,
      queued) FIRST, then the operator-direct `.github/renovate-global.json` regex manager. **Next** after both:
      the box wiring — `policy/mgmt/plan-input.yaml` maps a `ci_runner*` replace → the verb, one VM per tick.
- [ ] **FU-305** — **A devbox toolchain bump wedged the management box's loops; the sentinel failed SILENT.**
      10-07 #2362 → every box `devbox run` exit 1, no sentinel verdict. Class fix #2457 (no gate loop runs devbox;
      iac-sentinel runs the BAKED lock) — docs/management-box.md §Two pins; class-7 lock revert rerun HANDS-OFF
      10-11 (#2503→#2504, dependency-upgrades §Last proven). Flake proposer LIVE: devbox-update (#2471) carried
      `mgmt/nixos/flake.lock` in #2513 (10-12). Caveat: devbox logs `--option access-tokens github.com=<mgmt PAT>`
      into the unit journal on an internal error (root-only) — redact before any box log ships.
      **Next:** `MgmtSentinelLoopStale` (+ replay 10-07 20:15–21:10Z).
- [ ] **FU-290** — **Scans + sessions + reflexes exhaust the shared homelab-agents installation pools (142724430)
      under PR churn.** First 09-25 (Renovate wave); detector blindness fixed (#1979 graphql, #2442 core). Drains
      since: 10-04/10-06/10-07 (sleep-tracking#121 storm, oracle-fleet#798 loop — fixed + belted #2204/#2366),
      10-10 19:00Z (label writes → REST #2483/#2484), **10-12 11:10Z after the REST move** (cause unread).
      Chronology: TICK-LOG 10-04/10-07/10-10. Still GraphQL: `gh pr comment|merge`, `gh issue comment|close`.
      **Next:** the per-consumer points meter (scan vs session vs reflex) — the troughs never ran clean — then
      the lever (per-stack doorbell debounce, query batching, App per stack). Relates FU-125, FU-311, ADR-094.
- [ ] **FU-311** — **Every jail shares ONE user-PAT rate pool.** All mono/stack jail PATs (and their
      subagents, and `exporter-pat`) are the operator's identity, and GitHub counts the primary limit per
      USER: one 5000/h core pool (two PATs read one counter, 2026-10-10). A seat subagent's hand-rolled
      `gh` poll loop drained it ~13:59Z (~140 req/min) — reviews stalled in every jail, `pr-wait` read
      false reds (#2440). Shipped: the pool's real core series (#2442 → `GithubRateLimitLow` sees it) and
      the jail-card rule "wait on PRs through `pr-wait`, ≥1 min polls" (claude-jail#4). Deferred: the
      structural lever — jails off the shared user identity (App installation tokens per jail class
      inside the `teststuffstash` boundary). **Next:** decide that after a week of the series. Relates
      FU-290 (the App-installation sibling), FU-084.

- [ ] **FU-291** — **The reviewer finds in round N what already existed at round N-1's head.** 2026-09-27:
      homelab#2002 surfaced 4 same-class siblings one per round; #2004 round 2's findings existed at round 1's
      head — each = CI run + ride + fix round. "COMPREHENSIVE, in ONE review" (reviewer-session.sh) is prose; the
      reviewer reads hunks, not the branch. **Next (detector first):** `late-finding` count per CHANGES_REQUESTED
      round N≥2 (`git show <prev-head>:<path> | grep -F` the cited text) → ledger → retro; then a branch-wide grep
      per finding term appended to the review. Relates ADR-103, FU-046.

- [ ] **FU-281** — **The goal-checkpoint wakes on nothing — the trigger side is the token sink.** 09-23 read:
      19 rulings on six Goals, 11 on #1640 (4 trigger-(c) fires for ONE new member). WRITE side fixed (PR#1933).
      **RULED 2026-10-14:** one ride per state — the #198 `state-fp` debounce on goal-checkpoint units, trigger by
      trigger: (b) = homelab#2477, (c) = homelab#2565 (blockedBy #2477), both queued. **Next:** measure
      rulings-per-Goal before/after on `goal_timeline_comments` + `last-checkpoint:`.
- [ ] **FU-178** — **Two readers, one mirror: the doorbells read `agents/stacks.json` while the
      scan reads the live cluster claim** — a claim change (chain redirect, knob flip) reaches
      the scan in minutes and the doorbell side only when someone remembers to sync the file
      (found live 2026-08-02: a redispatch rode the file's stale chain two hours after the claim
      moved). Rescued 2026-08-19 (the untracked-work sweep — its only home was a meta-state durable
      warning). **Next:** doorbell-side callers (`coordinator-session.sh`, `agent-session.sh`,
      `coordinate-ring.sh`) read the cluster with the file as the probe-failed belt — the same
      merge `stacks_json()` already does; or extract that seam for the launchers. Relates
      FU-049 (generating the mirror), ADR-085.

- [ ] **FU-168** — **Dispatch revisit (#278 closeout): build + soak.** (a) concurrency shipped 08-12, acceptance
      `AgentDispatchCronWoken` ≈ 0 — soak FAILED 08-25; (b) `Touches:` fence demotion + governance lint = A4.
      Evidence: [`docs/spikes/goal-lane-v1.1-fu165-pilot.md`](spikes/goal-lane-v1.1-fu165-pilot.md) findings 4–5.
      10-03 hunt (oracle-fleet pr-780, ×11 cron dispatches): (A) scan labels `agent/arbitrate`, rings nothing;
      (B) exporter skips CI/conflict rings on arbitrate PRs; (C) a lane walk leaves unit 2 for the cron; (D) the
      gauge stamps before a refused dispatch, `unarmed-major` counts. **Next:** fix A–D (A/C/D `agents/`, B the
      exporter); A4's fence half; close when cron-woken ≈ 0 holds. Relates ADR-106, ADR-094, ADR-097, FU-167.

- [ ] **FU-169** — **Differential coverage as a REVIEW INPUT (operator design, 2026-08-13).**
      The reviewer can't see whether a PR improves or reduces coverage; the blanket per-repo
      % gate can't say WHICH new lines are uncovered. Target (the SonarQube shape): CI computes
      the branch-vs-master diff coverage and the review runs on a coverage-annotated diff, so
      every missed line needs a stated justification instead of a threshold nobody can argue
      with. Stack-repos-first (pytest-cov exists on sleep); homelab's bash/YAML CI mostly
      exempt. **Next:** pilot on ONE stack repo — diff-coverage step in CI + the annotation
      surfaced to the reviewer. Relates FU-095, ADR-103.
- [ ] **FU-170** — **Go-rail spend/limit belts — the residual gauges + alerts.** The silent
      balance-billing failure mode CLOSED console-side 2026-08-17 ("use balance after limits"
      DISABLED — a window at 100% now hard-429s; the self-metered latch + failover handle it).
      Shipped legs: concurrency semaphore (PR#484), observed-429/402 latch + roll-surviving
      persistence (#600→#603, #618→#621), launcher reroute on a latched Go-primary (PR#610).
      **Remaining:** (b) the jail-ingest freshness gauge (age of the last `stack=jail`
      go_usage row — the 2026-08-17 stale-shim under-metering, detection half) and (c)'s
      near-threshold alert half (know we're NEAR a window limit before dispatching into it).
      Design home: [`agents/chainless-redesign.md`](agents/chainless-redesign.md) §cost
      rethink. Relates FU-181, FU-131.
- [ ] **FU-182** — **The pushgateway grows without bound (no TTL on pushed groups).** Writer twin of homelab#807;
      the 08-24 HELP-line log flood fixed (agent-runtime#84, homelab#811). Groups 3223 (10-03) → **3631 (10-14)**,
      ~37/day. Pattern: [`docs/patterns/observability.md`](patterns/observability.md). **Next:** group hygiene —
      a cleanup pass (cron or push-time) deleting terminal-ride groups older than the ledger's retention need,
      sized so reads stay flat. Relates FU-131, observability §B1.

- [ ] **FU-181** — **Go-rail post-reset readout = METER-CALIBRATION HYGIENE, not a flip gate**
      (operator re-scope 2026-08-25, recorded on homelab#778; the Go posture ruling —
      janitorial/failover permanently, P4 de-gated from Sep-13 — is pinned in
      [`agents/chainless-redesign.md`](agents/chainless-redesign.md) §The OpenCode Go rail).
      On the first clean window after Sep-13: (1) #540's meter-vs-console parity on a clean 5h
      window; (2) the refusal shape on the first organic limit fire (the gometer latch is the
      only brake on Go spend meanwhile); (3) the persisted latch (#618/#621) survives a roll
      while held. Big-pickle-as-deepseek-shadow (the G-E $0 arm) is #778's thread.
      Relates FU-170, homelab#540, homelab#778.
- [ ] **FU-174** — **Reasoning effort is unmodeled fleet-wide (operator, 2026-08-17).** The DeepSWE
      numbers behind the flash slot ran `[max]`; the fleet runs provider defaults — the jail shim
      even DROPS `thinking` on translated legs, so no Go model ever sees an effort signal.
      Shape (seat-ruled): an `effort_map` beside `urgency_map` in model-classes.json — same
      ADR-094 precedence (explicit round-state → labels `agent-budget/lg|xs` → role → default),
      resolving an ABSTRACT tier; the injection points (proxy Go leg, jail shim) translate to
      each model's surface knob. Effort-before-model as the ladder's cheapest escalation rung.
      **Next:** matrix-spike rows (which opencode surfaces accept which knob), then a two-arm
      flash default-vs-max experiment (pass-rate/rounds/window-draw — effort multiplies draw;
      couples FU-170). Design home lands with the build: model-routing.md §effort (beside M11).

- [ ] **FU-201** — **The arbitrate "re-dispatch stronger" verdict has no carrier to the router.** Ruled 09-01: the
      carrier is the EXISTING size label. **Next:** (a) `agent-budget/*` RE-GRADE by arbitrate/breaker plays
      (label_map md/lg rows); (b) a brief section naming the label vocabulary per play; (c) strikes gain the
      served-provider column, serving-shaped strikes exclude the (model, provider) pair on re-pick — BUILT but
      dead in production 3× (#1268; 09-13 `no-output`; 09-23 `repetition-loop`) → homelab#1640 acceptances 1+3.
      Rejected options + history: [`chainless-redesign.md`](agents/chainless-redesign.md) §cost rethink; identity:
      [`model-identity-free-vs-paid.md`](spikes/model-identity-free-vs-paid.md). Relates FU-174, FU-186, ADR-094/096/115.

- [ ] **FU-283** — **A hung CI run has no run-level watchdog, so the ci-red directive never
      fires and the issue stays parked** (oracle handoff, 2026-09-23). oracle-fleet PR #716's run
      35839762985 sat `in_progress` from 08:54Z — the `ci` job hung 53 min on attempt 1 and 41+
      min on attempt 2 against a normal 16–31 min wall — and the coordinator's ci-red directive
      gates on a run-level `failure`, so a run that never FINISHES is invisible to it: #709 parked
      at 10:35Z and stayed there until a human cancelled at ~13:20Z. **Next:** pick the cheap belt
      (alert or cancel at 2× that workflow's p95 wall), then find what hung — ARC runner pod stuck
      on the large-runner set vs. a test that never returned; the runner-side logs are the
      platform's, the stack sees only the run view. Relates FU-200.

- [ ] **FU-202** — **A key-class failure strikes the MODEL, losing the primary rail for the
      whole task** (#1151, 2026-09-01): r1's xs session key died mid-ride
      (`budget-exhausted-key`, proxy auth circuit-open 08:02Z) and was treated as a
      (task, model) STRIKE — deepseek blacklisted for #1151, so rounds 1–6 rode subscription
      haiku ×5 + Go flash ×1 (both rails ruled WRONG for cheap coding: Go = janitorial
      posture, haiku = the shared pool) for want of a $0.25 re-mint. M1's own table says
      budget-403* is "neither round nor strike"; the raw-log subclass `budget-403-key` = mint
      defect. **Built 2026-09-02** (homelab#1233 / PR#1253: key-class → `KEY-RETRY:` marker +
      same-model re-dispatch with a fresh key; the fleet reader excludes key-class). **Next:**
      archive on the first organic `KEY-RETRY:` that re-dispatches on the same model. Relates FU-201, agent-runtime#85, FU-180.

- [ ] **FU-171** — **A >~30-min session outlives its ~1h git token — any rail, both arms.** 3 sightings: 08-14
      reviewer #447 (47 min, verdict lost); 09-01 coordinator oracle #328 (29 min — `LOOP_FETCH` mints once at
      PREP, no refreshable mount in `<stack>-agents`); 09-01 reviewer PR#1228 (31 min, subscription — verdict
      unpostable, pod key held re-dispatch ~46 min). Interim: reviewer Go failover → deepseek-v4-flash.
      **Next:** re-mint on 401 in the gh wrapper, both arms; re-verify on the next >30-min review. Relates FU-170, #435.
- [ ] **FU-172** — **#447 r1 review residues (operator merged wittingly, 2026-08-14).** The
      verdict died in posting (FU-171); the operator merged #447 direct (08:11Z). Findings are
      preserved in S3 (`reviewer-r1-20260814T075318Z`). Remaining: (1) only-free guardrail
      admits ANY `opencode/` id on the paid key — sentinel warns only (ACCEPTED RISK under the
      "assume free for now" direction; fail-closed decision later); (2) the zen metering
      self-test is vacuous (≈0.0 passes with no row recorded); (3) pre-existing hole: the
      only-free check admits `opencode-go/<id>:free` before the rail denial; (4) `_opencode_scrub`
      drops OpenAI-shaped function tools on the /api surface (since #421; relates #448).
      Next: (2)+(3) small PR; (1) decide with FU-170's signal choice; (4) rides the #448 probe.
- [ ] **FU-167** — **Replay-harness cleanup: POINTER.** Plan, evidence, and per-move status —
      including stint #661's bulk execution (table batches 2–4, move-7 suite fold-in, the #354
      adversarial acceptance PASSED first try):
      [`agents/replay/README.md`](../agents/replay/README.md) §The cleanup contract.
      Moves 1 + 4 and sprout #678 DONE (verified 2026-10-03). **Next (fix-density, no deadline):**
      straggler small families as touched.
      Relates ADR-097, ADR-103, FU-168.

- [ ] **FU-147** — **Code landed `15ef9cb`, unproven on live traffic — and it found FU-115b
      broken.** A `changes-requested` round that pushes nothing was invisible (circles PR#39
      r3); reusing FU-115b's predicate exposed two bugs in IT (committedDate read at the wrong
      level → "no-op" for every PR; and a good round posts stats AFTER its push). **Counting**
      is the fix (`>= 2` stats after the newest non-merge commit), one shared `NOOP_ROUND_JQ`.
      **Fired live 2026-08-24** (the #862 arbitrate cycle) — and MIS-fired: it re-labeled over
      a newer arbitration ruling on a LANDING PR (state-fp mutates every tick post-approval,
      3 sessions/5min) — fixed via #868 → PR#873 (SELECT excludes APPROVED+armed, "gated on
      fresh evidence"). **Next:** one CLEAN organic fire on a genuine no-op round post-#873.
- [ ] **FU-090** — **Sprout index / issue authoring: POINTER.** All legs, the breaker-#1 gate,
      the shipped sub-issue lineage (2026-08-02), the `Touches:` contract (ADR-097) and the
      retro-checkpoint terminal: [`docs/agents/issue-authoring.md`](agents/issue-authoring.md).
      Sprout series shipped (#209 `goal_sprouts_filed_total`; IL-G04 closed 2026-10-14), depth gate in the reviewer
      (rule 7) — **no machine Next left**; what remains is the operator-deferred list below.
      **Operator-deferred:** leg (c) goal-budget decomposition, `issueAuthoring.selfQueue` (10-13: subscription
      rides now settle at $0 in the pre-flight — #2545, retro r8 F2);
      the goal lane's PHASE-keyed model/checkpoint design (a `GOAL_MODEL` knob turns the wrong
      axis — [`model-routing-history.md`](spikes/model-routing-history.md) §M10 ⚖, 2026-08-11; design before wiring).
      Relates FU-087, FU-044, FU-111, ADR-094, TICK-LOG §Loop safety.
- [ ] **FU-199** — **Silent holds freeze whole lanes invisibly: POINTER.** Faces + fixes:
      [`agents/coordinator/README.md`](../agents/coordinator/README.md) §"FU-199 (2026-09-03)" (the 09-08 face: TICK-LOG 2026-09-08). Fixed: state-fp
      fingerprint faces (PR#1352), cap split (PR#1375/#1376), arbitrate rule-2 capacity re-arm (#2546, r8 F5 —
      the deferral is still coordinator prose, not a launcher marker). Open: the RULED-BUT-NEVER-DISPATCHED
      arbitrate face (09-08, PR#1513/#1515 — no re-arm for a ruling with no round behind it, or dispatch BEFORE
      the comment). **Next:** honest strike-held rows + hold-chain propagation; that re-arm. No-strike C4/C5
      limbo is FU-204's. Relates FU-187, FU-143, FU-147.

- [ ] **FU-200** — **The brief's fleet-strike rule: reader BUILT, re-key open.** "Same `error_class=` on ≥2 issues
      in 24 h ⇒ one `AGENT_ERROR` + one platform issue" (retro r4 F2) was prose; 09-01's four `unknown` strikes went
      uncorrelated. Reader BUILT (#1235; IL-T30 in [`issue-lifecycle-fsm.md`](agents/issue-lifecycle-fsm.md));
      09-13 it latched five ISSUES for one PROVIDER fault. **Next:** re-key provider/model/neither = homelab#1640
      acceptance 5 (open). Relates FU-199, agent-runtime#85, model-routing §M1a.

### Merge path, CI & deploys — reviewer, auto-merge, first-party bumps, the gates

- [ ] **FU-218** — **ARC runner memory: a node-sized limit, not node removal: POINTER.** The runner
      requests 1536 Mi with no limit, so jobs size to the HOST (`pytest -n auto` = one worker per CPU)
      and vanish on 8 GB nodes; the recurring "move off 8 GB" pressure. 2026-10-02 evidence: the same
      suite fits an 8 GB node once workers are bounded (oracle-fleet #783: 3 workers, 3.1 GiB, pass).
      Option A spike DONE (PR#2185: in-place `pods/resize` proven on nx-01). **Next (operator):** the
      spike's sizing calls (8 GB acceptance line, dind inside/outside the budget, per-runner cap) → ADR. Design, history, options, acceptance:
      [`spikes/arc-runner-memory-budget.md`](spikes/arc-runner-memory-budget.md). Relates FU-208, ADR-082.
- [ ] **FU-221** — **The updater burns a CI cycle per pass on a PR whose red is RELATIONAL (diff × base).** The
      pick has no green requirement on purpose — wrong for a gate a catch-up merge cannot move (PR#1468: 26 merges,
      never green, pool starved — FU-218). #1489 (ADR-103 addendum) shrank the class to all-vacuous PRs.
      Candidate: skip when the newest CI failure is the ADR-103 ratchet step, report-only. **Next:** build only on
      a second sighting (ratchet-step red through ≥3 catch-up merges). Relates [`merge-path.md`](agents/merge-path.md)
      MP-T02, ADR-111.

- [ ] **FU-220** — **Locked python rides no longer use the PyPI cache; recovering it needs a
      TRANSPARENT cache, which is a trust decision.** `UV_FROZEN=1` (2026-09-07, PR#1485) stops uv
      rewriting committed locks to the LAN index, at the price of `--frozen` installs fetching
      files.pythonhosted.org over the WAN — all three python-profile repos commit a lock, so the
      `/packages/` zone is fed only by unlocked paths now. Mechanism, the measured uv behaviour
      and the two named costs of the transparent shape (forged certs for public hostnames in
      sandbox pods; hostAliases delete the upstream fallback) live in
      [`patterns/python-stack.md`](patterns/python-stack.md) §caches. **Next:** measure what the
      bypass costs (wheel bytes/ride × rides/week) before spending anything — operator decision.
      Relates homelab#1300/#1413.

- [ ] **FU-197** — **manifest-lint fetches every kubeconform schema from raw.githubusercontent.com
      on each CI run — uncached, so a GitHub-raw hiccup reds the required check.** Bit PR#1099
      (2026-08-31): the runner got HTTP 400 on a schema fetch (a guaranteed-404 kustomization
      lookup; the jail saw 404 for the same URL) and kubeconform hard-failed the lint. The
      kustomization class is excluded now (`manifest-lint.sh`, same commit), but every REAL schema
      fetch (~101/run) still rides the public internet with no mirror — unlike images (ghcr/MCR
      mirrors) and nix (shared /nix). **Next:** vendor the used schema set into the repo (or bake a
      `-schema-location` cache into the warm ARC runner volume) so the lint is hermetic; grep
      showed no existing FU/ADR covers schema caching (FU-144 is the schema-BLIND-kinds half).
- [ ] **FU-255** — **audit remaining floating-tag pulls through `mirror-docker-io`/`mirror-ghcr`
      for the same live-revalidation exposure homelab#1739 found.** Neither mirror bounds its own
      upstream fetch (no `REGISTRY_PROXY_*` timeout — ADR-091 update, 2026-09-20), and a *tag*
      pull always revalidates live against the real upstream on every request (only digest pulls
      are pure cache); measured blob-GET p99 spikes to 9–52s against a 0.2–0.9s baseline. Fixed
      on the crossplane engine image + both composition function packages (#1779, #1796,
      digest-pinned). **Next:** grep both mirrors' known consumers (ARC runner images, kata ride
      base images, anything else pulling `docker.io/`/`ghcr.io/` by tag through either VIP) for
      ones sitting on a bounded CI/render timeout the same way `publicroute-tf-validate` was —
      those are the ones actually exposed, not every tag pull equally.
- [ ] **FU-152** — **One version file for the agent-coordinator image.** The kustomize conversion shipped
      (`agents/coordinator/kustomization.yaml` `newTag`); residue: 5 literals in the AgentStack Composition (the
      per-stack scan/review/janitor CronWorkflows, live `2026.8.7`) + 1 in `gc-mirrors.yaml` (`2026.7.25`) vs the pin
      `2026.10.12`. **RULED 2026-10-14:** two homes held equal by a rule — agent-coordinator#27 (deploy-pin sweeps
      both files, auto-merge armed) + homelab#2566 (bump + equality check in `manifest-lint.sh`, queued; land AFTER
      #27). **Next:** archive when both merged and one bump PR rode green.
- [ ] **FU-153** — **in-pod CI and in-CI CI disagree under kind, and no lever says which is right.**
      circles#19 r2 reported `ci_passed: true` from the ride; Actions failed the SAME gate twice
      (`HTTP 000000`, 4 assertions). Not a missing capability — the claim carries
      `repos[circles].fixer.docker: true` (flipped FOR #19) and the pod really is kata +
      native-sidecar `dind` + `DOCKER_HOST`, so the worker CAN run kind. The two environments simply
      differ (kata microVM dind vs the ARC runner). The re-run lever now EXISTS (FU-148 archived
      2026-10-03: environmental reds retry once via `actions:write`); the in-pod re-run and the
      which-environment-is-right reveal remain. **Operator direction
      2026-08-07:** give each stack coordinator both levers, and make the lever REVEAL which
      environment is telling the truth. Relates FU-148, FU-072 (kata networking), ADR-097.
- [ ] **FU-130** — **CI-gate WAN fetches: FIXED, all three merged 2026-08-05.** helm-unittest now comes
      from devbox (`kubernetes-helmPlugins.helm-unittest`, `$HELM_PLUGINS`) instead of a 23 MB
      GitHub-release pull per run — circles#15 (the `new-stack --from` donor) + sleep-tracking#115,
      both verified locally. agent-runtime#30 switches the ride's nix `extra-substituters` → `substituters`, so a
      LAN miss no longer reaches cache.nixos.org (28 lookups in one harvest; a hang once egress
      enforces). homelab side landed: `stack-lint` CACHE-01 probes what the LAUNCHER probes
      (anonymous ghcr pull of `<repo>/devbox-cache:latest`) + `new-stack` step E2. **Next:** confirm
      on a post-merge ride that no WAN fetch remains, then archive. Residues: `tofu validate`
      (`dependency-upgrades.md`); ARC stale-warm-store —
      [incident 2026-08-11](incidents/2026-08-11-wk-metal-02-default-route-loss.md).
- [ ] **FU-044** — **Roll-FORWARD on a broken deploy — the remaining LLM half: POINTER.** Deterministic rollback
      LIVE (argocd-notifications → `/deploy-degraded` → `deploy-revert`); first hop dead 07-27→10-04 (#2217, belt
      `ArgoCDNotificationDeliveryFailing`); trigger now needs a Degraded caused by THIS deploy (#2539, fail-closed);
      multi-source `oncePer` fixed (#2538); parse belt `ArgoCDNotificationTriggerStalled` (#2541). Design, rulings,
      history: [`docs/agents/iac-lane.md`](agents/iac-lane.md) §"ArgoCD health is NOT the post-deploy gate" +
      §"Auto-revert does NOT generalize". **Next:** dispatch a worker against the APP repo off ArgoCD health
      events, in-cluster; operator prereq: app CI hardened. Deep acceptance = FU-102. Relates FU-041, FU-090.

### Models, cost & routing

- [ ] **FU-251** — **opencode.ai: headers PROVED on the wire; the knob is an operator flip.** Proxy forwards UA +
      session header (PR#1760); no session header ⇒ `400 MissingSessionID`. Knob back to `"0"` 09-17 18:35Z
      (`c5138ed0`) while the 7d subscription window sat at 0.95. Proof + seams: [`chainless-redesign.md`](agents/chainless-redesign.md)
      §Proved on the wire. **Next:** the three seams — UA substitution narrower than the vendor's rule 2;
      claude-code <v2.1.86 sends the session id only in `metadata.user_id`; an anonymous client buckets coarsely
      on the credential ref.

- [ ] **FU-180** — **Subscription budgets + fair-scheduling window shares (chainless
      cost-rethink directions 3–4).** Goal budgets on the platform stack stay CAP-PHANTOM until
      subscription budgets exist (#278 closed at $76/$60 phantom vs ~$0 real); the design —
      work-conserving per-stack window shares, budgets metering TOTAL cost across roles/rails —
      is [`chainless-redesign.md`](agents/chainless-redesign.md) §The cost rethink. Rescued
      2026-08-19: its build home was "a later wave of #420", which closed at the stint pilot.
      **Next:** the accounting half rides FU-131/#278's rail-aware summation; the scheduler
      half is a design sitting before any Goal whose `Budget:` must be real. Relates FU-088.

- [ ] **FU-161** — **Scout v3: POINTER.** Design + mechanism (variant filter, benchmark
      cross-check, typed cell-keyed canary verdicts, the ⚖ filing gate's evidence-bearing
      partition): [`model-routing-history.md`](spikes/model-routing-history.md) §M7. Legs 1–2 shipped 2026-08-11
      (#282); legs 3–4 + the filing gate (operator, 2026-08-17: an all-unbenched, uncanaried
      digest posts nowhere but the log) shipped via #469→PR#499 + #506's whole-set common-cause
      rule. **First fire PROVEN** — weekly organic digests (#1647/#1821/#2053), #2053 with three typed
      `clean` canaries. #778 released unbuilt 2026-09-02 (Go cells mooted by the 08-25 ruling; hygiene →
      FU-181). **Next:** rung-2/FU-095(c), pool depth, void the tainted 08-10..08-17 rotation rows (no
      owner since #778). Related: #235's belt (machine lane owns it).

- [ ] **FU-186** — **Provider selection priced per successful job (ADR-115): POINTER.** Design +
      evidence + 4-step build order: [`docs/spikes/model-routing-history.md`](spikes/model-routing-history.md)
      §M14 (Exacto delegated for cheap coding; pin-v2 with the overhead-cost term for priced
      classes; the scout rides its class's provider policy; `@` arms = the experiment
      instrument, shipped PR#963). **Step 1 FLIPPED 2026-09-13 (PR#1639; operator: the five
      open-inference tool-loops ARE the trial) — the suffix rides paid OpenRouter picks only.
      Next:** the standing re-read = homelab#1640 acceptance 8; the 0731 matrix run (step 2,
      #1238 — open; parent Goal #1231 closed 2026-09-14, so unparented). Relates ADR-115, ADR-096 §M4/M8, FU-095, homelab#966 (intake digest),
      the #783 provider-attribution legs.

- [ ] **FU-095** — **Task-class model routing + multi-harness evidence: POINTER.** Design,
      pilots, the strike/§M10 rulings: [`docs/agents/model-routing.md`](agents/model-routing.md)
      + ADR-096/ADR-112. Legs (b)+(c): G-A child #778 was released unbuilt 2026-09-02 (Go-posture
      ruling); no current owner. Flip evidence COMPLETE (2026-08-25, #775 — the 123 deferred rows are
      `chain-exhausted` on subscription-only classes, a served-walk candidate-injection gap,
      NOT capacity; shadow resolves haiku cleanly on every row). **Next:** the flip child =
      the ladder promotion into the served path + env/claim flips (acceptance: zero
      chain-exhausted defers on subscription-only classes); SEQUENCING RULED **A** (operator,
      2026-08-25) — flip at/after the ~2026-09-03 PR#715 paid-flash revert, the checkpoint
      mints the flip child, the `rails:` knob builds post-flip. Relates ADR-096, ADR-112, FU-046.
- [ ] **FU-127** — **One model-id parser LANDED; the structured claim field is the rest.**
      `agents/model_id.py` is the single `{rail, harness, model}` implementation (overloaded
      prefixes incl. the cloaked `openrouter/<codename>` case); migrated callers =
      agent-session.sh, research-fanout.sh, `estimate_budget.normalize_model`; the proxy's
      unavoidable copy is drift-pinned by `devbox run model-id-test` (AST-extracted).
      **Next:** the structured `{rail,harness,model}` form in claims + `stacks.json` (string
      stays canonical; also where a future local-vLLM rail lands). The routed-RESPONSE carrier
      shipped as G-A child #776; the claim-field half rides the goal's checkpoint-minted claim
      reshape. **Gates ADR-139 step 3** (FU-270): `routing` joins as a field. Relates FU-095, ADR-096.
- [ ] **FU-269** — **The git credential broker leaves `openrouter-proxy` (ADR-139 step 1).**
      `/git-token` + `/loop-git-token` are stateless (read the minted `agent-git-<ns>` Secret,
      TokenReview, short cache) yet roll with every router change — oracle-fleet#679-r2 cloned at
      16:59:04Z mid-roll and died with an empty password (2026-09-21). **Next:** a separate
      Deployment + Service in `agent-egress`, ≥2 replicas + PDB, its own SA with the Secret-read
      grant (removed from the proxy's), launcher `GIT_CRED_BROKER_URL` repointed; agent-runtime#144
      (retry) stays. Relates ADR-087, FU-089.
- [ ] **FU-270** — **`agent-gateway`: the island is BUILT and LIVE in parallel (2026-10-16, #2606); the
      consumers have not moved.** ADR-139 step 3 executed as the in-monorepo island `gateway/` (P2 ruling,
      not a separate repo): specs-first (`gateway/specs/`, 14 `GW-*` rows), own toolchain/tests/image CI
      (`.github/workflows/gateway-image.yaml`, pinned-image deploy = FU-044 class), `POST /sessions` +
      per-session model, three rails canaried. The OLD proxy stays untouched (operator, 2026-10-15); no
      launcher calls `/sessions` yet; the ADR-096 ladder / FU-088 latches / `/route` are `⚑ gap` rows.
      Unblocked from FU-127/FU-269 (nothing left the repo). **Next:** (1) `agent-session.sh` → `/sessions`
      for ONE role on the platform stack (env names differ today: goose = GOOSE_PROVIDER/OPENROUTER_HOST,
      opencode = OPENCODE_CONFIG file — `GW-SESSIONS-ENV` ⚖ rows); (2) wire the specs lens
      (`docs/agents/specs-reviewer.md` §wiring — identity question open); (3) the ladder as GW rows.
- [ ] **FU-271** — **Gateway HA waits for a measured store (ADR-139, deferred).** In-process
      semaphores/breakers/in-flight/latches double every cap at 2 replicas, so HA needs a session
      store (Redis/Valkey-class — not a platform service today) + a durable one (CNPG or SQLite).
      **Next:** measure store ops per request × RTT from a wired-node pod per candidate, against the
      LLM budget (p50 6.4 s / p10 2.1 s, 2026-09-21); then pick, then 2 replicas. After FU-270.
- [ ] **FU-272** — **Vendor status pages out of `github-exporter`.** 11 of its 13 collectors read
      GitHub; `collect_vendor_status` + `collect_anthropic_status` poll vendor status pages — scope
      creep under a source-named exporter (exporters are named by the system they read, ADR-139).
      **Next:** a small `vendor-status` exporter owning those two (same ConfigMap-script pattern),
      metric names unchanged so dashboards/alerts keep reading. Glossary: pending renames.
- [ ] **FU-131** — **Cost-ledger accuracy: harvest FIXED; the T+1 sweep DROPPED (ruled 2026-10-14).** Harvest backoff
      2/5/15/45 s + `openrouter_generation_harvest_total{outcome}`; live 10-14: missed 0 vs ~6,840 stored in 21 d.
      The sweep needed an in-cluster management key (ruled out) — replaced by a belt: homelab#2564 (queued).
      Remaining ledger-accuracy leg: agent-runtime#173 (standing-key `cost_usd` = siblings' spend; queued 10-14).
      **Next:** archive when both land. Relates ADR-096, FU-095.
- [ ] **FU-126** — **Multi-model spec-writer fan-out: same mission → N researcher rides on N
      models → N un-armed `research/*` PRs → operator compares and cherry-picks.** Platform legs
      BUILT 2026-08-02: `agents/research-fanout.sh` (per-model task keys, ephemeral budget keys,
      `AGENT_WIP_LIMIT=N`) + model-slug branch rules in both research recipes + oracle
      research.yaml. Process home: [`research-and-specs.md`](agents/research-and-specs.md).
      **Remaining:** first consumer run (idp-system specs — needs the idp stack bootstrap; the
      mission must package the private teststuff spec doctrine into specs/conventions.md;
      per-goal FQDNs via extraFQDNs). Reference output = the nemotron run in `/workspace/idp`.
      **The idp run = research run 2** — settles the doc's Unsettled register and is FU-162's
      acceptance. Relates FU-095, FU-090(c), ADR-104.

### Observability & evidence — alerts, transcripts, retro, the prober

- [ ] **FU-303** — **etcd is not scraped; scheduler + controller-manager only on cp-01.** Found by the
      2026-10-03 upstream triage classification (ADR-148): no etcd job in `up` at all, so the 13 stock
      etcd alerts can never fire on a 3-CP cluster (ADR-133); `kube-scheduler`/`kube-controller-manager`
      targets exist for cp-01 only — cp-02 and wk-metal-02 are unwatched. Deferred: the fix is a Talos
      machine-config change on all three CPs, a maintenance window. **Next:** metrics listen addresses
      (`cluster.etcd.extraArgs listen-metrics-urls`, scheduler/controller-manager `bind-address`) via
      the CP config patch, then the chart's `kubeEtcd`/`kubeScheduler`/`kubeControllerManager` endpoints.

- [ ] **FU-228** — **`agent-transcripts` has no retention — 5Gi → 20Gi bought time, not a policy.**
      The bucket sat at 98 % (5.3 GB, 26.7k objects, ~1 GB/week of ride exhaust) the hour
      `GarageBucketQuotaNear` first ran (2026-09-10, #1577); the 2026-08-03 claim was "11× actual".
      A refused put is a lost transcript — the writer key is put-only, nothing retries — and the
      transcripts feed the retro (observability-and-retro.md §A1/B) and doc-heat (FU-164). Cap raised
      to 20Gi (#1579) ≈ 4 months at today's rate. **Next:** decide what to keep (per-issue tail? the
      retro's window? everything, and a bigger claim?) and implement it as an S3 lifecycle rule or a
      sync-job sweep — the design question belongs to `docs/agents/observability-and-retro.md`.
      Read 2026-10-03: 7.2 GB / 20 GiB (33 %), ~0.6 GB/wk → ~5 months runway. Sibling: `allure-reports` at 89 % of 10Gi is oracle-iac's (their alert, their retention).
- [ ] **FU-210** — **Responder transcripts: POINTER.** A triage that filed nothing used to leave
      nothing — the 2026-09-03 forgejo-pg-1 session marked the subject triaged, filed no issue, and
      the probe lane deferred to it as COVERED while the alert stood 8 h. The lane was the one role
      outside §A1. Mechanism, layout and the write-only-key ceiling:
      [`agents/observability-and-retro.md`](agents/observability-and-retro.md) §A1 (responder row +
      hook point); gate = `responder-behaviour-test.sh` §FU-210. Shipped PR#1749.
      **Next — the acceptance, which cannot run while the lane is paused:** at FU-249 step (3) (the ADR-148
      `now` routing — the lane is replaced, not un-paused), read one prefix end-to-end and confirm a report-only session that files no issue still leaves
      a readable decision. Relates FU-231, FU-249.
- [ ] **FU-187** — **Quiet-stall detection: a Running agent pod with a silent rail is invisible
      to every belt** (issue-272-r1, 2026-08-26: opencode slept ~3h on a black-holed proxy IP,
      0-byte run.log, until the 4h activeDeadline reap — which ALSO skips finalize: no strike,
      no label flip, the goal child re-entered the FU-143 ⛔ hold; both costs paid on #272 in
      one day). The storm watchdog matches run.log LINES so an empty log can't trip it;
      `AgentQueueStalled` is suppressed BY the running pod; phase metrics push only at finalize.
      **Next:** pick the cheap belt — a no-growth clause in agent-storm-watchdog (run.log
      unchanged Nm ⇒ the same kill path WITH strike bookkeeping, beating the reap), or the
      proxy-side signal (key silent Nm while its ride pod Runs); the SIGTERM-trap finalize on
      deadline is the agent-runtime half. Relates FU-072 (this trigger's cause).

- [ ] **FU-188** — **Reviewer 404-loop / the combination table — POINTER.** Postmortem, belt audit, yaml-in-git
      ruling, legs: [`incidents/2026-08-26-reviewer-404-loop.md`](incidents/2026-08-26-reviewer-404-loop.md) §Residual
      work. Build = the dated role×harness×rail×model table in git; router filters on it, launcher derives from it.
      (b) router half SHIPPED (PR#1929); (d) failure half SHIPPED (`ArgoWorkflowsFailing`), verdict-throughput half
      open. Reviewer pin LIVE; its deletion = #1769 acceptance 4 (Goal open). **Next:** schema design pass, then
      the issue tree.

- [ ] **FU-164** — **doc-heat — POINTER.** Doctrine, v0 (`devbox run doc-heat`), settle runs 1–3, serving plan:
      [`docs/spikes/doc-heat.md`](spikes/doc-heat.md). PROMOTED 08-30 (docs-cleanup input); post-S5 read 09-05
      (trims = homelab#1393). **Next:** the v1 cluster leg (spike §v1 — `s3://agent-transcripts`, path
      normalization, separate + combined views), which also delivers context-repos.md's measurement sweep.
      Relates FU-058.

- [ ] **FU-058** — **Retro P3: POINTER.** Design + run history: [`docs/agents/observability-and-retro.md`](agents/observability-and-retro.md)
      §B2. Weekly retro LIVE through r8 (published 10-12 #2522 after #2519 state slimming + #2523 block-less
      partial); r8 F1–F5 executed by the seat 10-13 (TICK-LOG 19:00Z — the jail holds no bucket writer key, so
      `retro_pipeline.py accept` cannot run there). **Next:** goose cell's `retro-findings-json` compliance (one
      sighting — watch r9, then the brief); the stack-retro split (ADR-146 PR#2172). Absorbs FU-057's residue.
      Relates FU-095, ADR-103 (rule 3).

- [ ] **FU-067** — **Hubble flow EXPORT → Alloy → Loki (denied-flows event drill-down) — only if
      the drop `destination` label proves insufficient.** Context (2026-07-12): the FU-020 ride's
      ~150 POLICY_DENIED drops were unclassifiable post-hoc (flow ring buffer rotates in minutes);
      fixed at the METRIC level (`drop:…destinationContext=dns|ip` + `dns:query` — Prometheus now
      names denied destinations and attempted lookups, panels on the `agent-issue` dashboard). If
      per-flow detail (pod/port/timing) is ever needed durably: Hubble's built-in
      `hubble.export` (static filter verdict=DROPPED → node file) tailed by the existing Alloy
      DaemonSet into Loki — ALL maintained components. Explicitly REJECTED: the `hubble-otel`
      OTLP adapter (blog-circulated pattern) — the project is archived/unmaintained; Cilium has
      no supported native OTel emitter. Relates FU-020.
- [ ] **FU-102** — **Prober role (the contract probe): POINTER.** Brief + machinery checklist +
      build state: [`docs/agents/roles.md`](agents/roles.md) §"Role machinery checklists" →
      prober (report-only by construction). **LIVE** on platform (`probe-platform` */6, 133 runs) and
      oracle (`probe-oracle`). 2026-10-03 read: 6 of 28 ticks/7d die at max-turns 30 inside a Succeeded
      workflow (FU-227(b)'s shape). **Next:** fix the max-turns death (raise or split the brief), then
      the sync-succeeded edge + 🌱 issue filing. Composes with FU-044.

- [ ] **FU-230** — **The responder cannot see seat-driven change: POINTER.** (a) silences PR#1601, (b) declared
      windows PR#1750, ownership by SILENCE #2418 (10-09). Mechanism: [`agents/roles.md`](agents/roles.md) §responder;
      evidence: [`spikes/responder-week-audit.md`](spikes/responder-week-audit.md) §2026-10-09 gap 1. **Proven 10-13**
      (window seat-1791909319-922): `KubePodNotReady` grace 16:59Z → claimed 17:00Z → respond 17:13Z, no session;
      post-`up` pod silence ran 10-10 (wk-04). The grace's exit 1 reads as a hard-failed pod in `maint check`.
      **Next:** a real window's named-but-UNCLAIMED alert triaged with the window in the brief.
- [ ] **FU-231** — **Findings to the bucket, issues only for actionable verdicts: POINTER**
      (operator direction 2026-09-11). Producer half shipped PR#1749 — a typed
      `finding.json` (`responder-finding/v1`) beside every transcript, the no-issue triage
      included. ⚠ **The SWITCH stays OFF and cannot be flipped as sketched:** report-only issues
      are DECIDED-ONCE's anchor (#1733), and moving that anchor into the bucket needs a pod read
      the write-only transcripts key will never grant. **Next, two independent legs:** (a) the
      CONSUMER — now the output of FU-249 step (4), the grouped deep dig; (b) re-read the switch at
      FU-249 step (3), against an anchor
      that does not need an open issue. Evidence + the MCP exclusion:
      [`../spikes/responder-week-audit.md`](spikes/responder-week-audit.md) §Design read.

### Roles & platform capabilities — new lanes, sandboxes, context delivery

- [ ] **FU-216** — **Rides' test IO rides virtiofs onto the shared laptop disk — try a memory-backed
      `/tmp`.** The 2026-09-05 specimen (oracle-fleet#370 r2): 24 of 30 min were `devbox run ci`,
      pytest 641 s in-pod vs 381–430 s on ARC, node IO pressure-stall 82–91 % the whole ride — a
      Longhorn neighbour on the same partition; the pod has NO volume for `/work`/`/tmp`, both are
      rootfs over virtiofs. Findings + envelope math + kata-ci-gate precedent (3 Gi tmpfs guest-OOMed):
      [`spikes/ride-latency-breakdown.md`](spikes/ride-latency-breakdown.md) §Second specimen.
      **Next:** one measurement ride on `wk-metal-04` with `emptyDir: {medium: Memory}` at `/tmp`
      (+ `TMPDIR`) and `du -sh /tmp /work/repo/.venv` at exit → that number sets `sizeLimit`; then
      the launcher flag. Operator: pick up on a slow day, AFTER oracle's own ci/e2e big wins.
- [ ] **FU-217** — **Goose's 600 s shell-tool timeout is shorter than oracle-fleet's suite — rides
      re-run or die on it.** #370 r1 looped 300→600→500 s and died exit 255 (no transcript, no
      strike); r2 lost a full 600 s run, then wrapped the second in a 900 s poll. Not a named strike
      class (model-routing.md's `timeout` is the provider one). Evidence: the same spike section.
      **Next:** either raise the worker recipe's tool timeout above the measured suite (or make it
      per-project), or teach the recipe scoped pytest (touched paths / `-x -q`) — decide once
      oracle's suite is optimised, since that may shrink under 600 s on its own. Second half
      (oracle handoff 2026-09-03, #355 r5): a round that dies on its OWN tool timeout is a
      "gate not observed" outcome — the ride stats/verdict must distinguish it from "gate
      observed red" so it never counts as a fix round or feeds a ci-red hypothesis. Relates FU-216.

- [ ] **FU-106** — **Build out the -iac lane: POINTER.** Role, doctrine, lane taxonomy, the
      IAC-G01..G10 gap register with per-gap status, assurance layers and the sentinel
      (G01 ENFORCEMENT FLIP live since 2026-08-18 — §L0b has the full state):
      [`docs/agents/iac-lane.md`](agents/iac-lane.md) (+ `iac-lane-fsm.yaml`, lint-checked).
      **Next:** the G06 advisory lens. (Flip soak ANSWERED 2026-10-03: real `iac-sentinel` reds gated
      #1945/#2177/#2190 and cleared on fix.) Relates FU-087/FU-093, FU-176, ADR-084, ADR-076.
- [ ] **FU-177** — **Make conflicting IP assignment impossible (operator ask, 2026-08-18).**
      Host IPs live in FOUR uncoordinated homes — `opnsense/dnsmasq-dhcp.py` (reservations),
      `machines/machines.yaml` (cluster hosts), `tofu/variables.tf` var.nodes (VM statics),
      `SERVICES.md` (VIPs) — and nothing checks cross-file uniqueness: the U6LiteBasement
      reservation sat on wk-03's static .63 until it caused a day of readiness flapping
      (#553; docs/ip-plan.md governs RANGES, not addresses). Next: rung 1 = a `devbox run
      ip-lint` that parses all four sources and fails CI on any duplicate address (cheap,
      catches the whole class); rung 2 (the real fix, decide after rung 1) = machines.yaml
      or a sibling becomes the ONE address book that dnsmasq-dhcp.py + tofu consume, per the
      machines.yaml generator pattern. Relates ADR-088, FU-049.
- [ ] **FU-134** — **Web research is a platform capability — soak FAILED, cause unknown.** `POST /search` on the
      egress proxy (OpenRouter `openrouter:web_search`, caller's own key ref, no new credential/egress; refused
      for anthropic-tier refs) returns `{answer, citations[]}`; verified live 2026-08-05. Detail:
      [`docs/agents/roles.md`](agents/roles.md) §Context delivery. Only real-ride calls (09-27 ×2) timed out;
      0 calls in the 7 d to 10-14. **Next:** find the timeout (model/provider vs `SEARCH_TIMEOUT_S` 120), re-read
      one successful real-ride call, then archive. Relates FU-117, FU-095, FU-020.
- [ ] **FU-019** — Migrate the worker plain `Pod` → agent-sandbox `Sandbox` CR (ADR-078).
      `agents/agent-session.sh`.

- [ ] **FU-094** — **Tiered spec gate — PROPOSAL ONLY (operator 2026-07-24: "will consider
      once I have more data and cleaned up the specs").** Write-up:
      `docs/agents/spec-gate-tiering.md`. Kernel: meta-9 measured 16 codeowner spec gates/72h
      with 0 rejections — the gate's value migrated to issue-time ⚖ pre-decision; ~half the
      gates were mechanical diffs (marker flips, event-list syncs, provenance notes). Do NOT
      implement before the operator re-opens this.
- [ ] **FU-059** — **W1 DECIDED + built (2026-07-10, ADR-086): coordinator commits ⚑ spec gap-flags
      to open agent PR branches during merge-forward arbitration (record-in-git; issues = work
      pointers only). Remaining scope = W2+ (direct fixes/seeds), still needs design.** Original:
      **Coordinator write tiers (W1/W2) — needs its own ADR first.** Today the coordinator's
      stack-repo clones (`/work/<repo>`, the per-stack context — platform-and-stacks.md) are **read-only reference**: its
      only writes are labels/comments/merge-state via `gh`. A future tier could let the coordinator write
      *directly* to a stack repo (open a PR from the clone, push a trivial fix, seed a spec) instead of always
      dispatching a worker — but that blurs the coordinator(orchestrator) vs worker(builder) split and touches
      budget/credential/review-gate assumptions, so it must be designed in an ADR before any code. Relates
      the `AgentStack` claim (would carry the tier as policy — platform-and-stacks.md) and the merge-path reflexes.

- [ ] **FU-093** — **Storage-tier ledger + metering: POINTER.** Rule, history, meters, status:
      [`docs/storage-ledger.md`](storage-ledger.md). Shipped: Longhorn + Garage metering, pve fstrim, thin-pool
      meter (`PveThinPool*`, PR#1367). Standing `LonghornDiskBelowSchedulingFloor` ×2: hp-01/hg5d (57 GB = a
      Longhorn REBUILD snapshot that merges itself — never clear it; alert text wrongly blames the image store)
      and, new 10-14, wk-metal-04 `intel1` 75 % (garage-0 + registry-data; ledger L121 still says intel0 —
      shared with FU-280). **Next:** fix the alert text; (a) Longhorn `filesystem-trim` RecurringJob; (b) metal
      fstrim for the image store (SA400 holds no replica since 09-09). Relates ADR-089, ADR-114, FU-211, homelab#934.
- [ ] **FU-211** — **The storage ledger's numbers are hand-typed — generate them.** PR#1368 took three bot rounds on
      transposed figures in the buy-a-disk cell; "Current shape" is a 08-25 snapshot. Truth is LIVE (Longhorn
      disk status, `pve_lvm_thin_lv_size_bytes`, ResourceQuotas, Garage Workspaces — `scripts/storage-ledger-check.sh`
      sums these). **Next:** a `--render` rewriting marker-delimited blocks in [`docs/storage-ledger.md`](storage-ledger.md)
      stamped with the read date, per `machines/generate.py`; judgments stay prose. Relates FU-093, FU-177.

- [ ] **FU-049** — **Platform services published as XRDs supersede `SERVICES.md` as the source of truth.**
      Provisionable capabilities (S3/Postgres/…) become typed Crossplane XRDs; discovery is a cluster query
      (`kubectl get xrd`) and the human catalog is *generated* from them rather than hand-curated. Open:
      build-time discovery for an app repo with no cluster creds may still want a generated static catalog.
      **Inherited from FU-107 (2026-07-27), same generation class:** agentstack.md's "what a claim
      renders" table generated from the XRD/Composition, and the stacks-state table from
      `kubectl get agentstacks` (plus `agents/stacks.json` itself — the original mirror problem).
      Design: [`docs/agents/platform-and-stacks.md`](agents/platform-and-stacks.md) §2, ADR-085. Relates
      [[service-discovery]], ADR-076 (app-owned resources via Crossplane).

- [ ] **FU-227** — **Two silent-failure shapes the workflow belts cannot see — POINTER.**
      [`incidents/2026-09-05-updater-node-cap-responder-dead-triage.md`](incidents/2026-09-05-updater-node-cap-responder-dead-triage.md)
      §Residuals; belt home FU-188 (d). **Next:** (b) a triage session dying inside a Succeeded workflow (156 in 7 d;
      the prober's max-turns deaths are the same shape) — push `responder_triage_sessions_failed` from
      `responder-budget.sh`, alert ≥3/24 h (no rule yet, 10-14). (a) PARTIAL: `AgentLoopWorkflowsFailing` (PR#1515)
      per namespace; per-TEMPLATE rate is the residue (no template label — a Workflow-CR read or the exporter).
- [ ] **FU-256** — **Worker rides share a namespace with the stack's prod workloads; should they
      move into `<stack>-agents`?** FU-080 moved only the LOOP there; a fixer ride still runs in
      the repo namespace (`NS="$PROJECT"`, `agents/agent-session.sh`), beside the database and
      the writer-key Secret, separated by zero RBAC + the worker CNP. Operator raised it
      2026-09-20 ("so any rules apply equally") and deferred it: a bigger rollout than oracle's
      data-access need, which `fixer.egress.ownServices` answers in either topology. Everything
      keyed on ns==repo moves with it (git-token scoping, TokenReview identity, per-repo egress
      profile, scratch quota, `agent-read-app` bindings, tenancy labels). **Next:** a
      `/design-agents` pass that inventories those surfaces and rules go/no-go — ADR-shaped.
      Relates FU-080 (archived), FU-068 (archived), ADR-093.
- [ ] **FU-257** — **The loop-ns `agent-loop-egress` CNP is monitor-only with no owner for its
      enforce flip, and it is NOT clean.** Hard-coded `enableDefaultDeny.egress: false`; the
      Composition comment cites Goal #1162, which closed 2026-09-14 and excluded the flip.
      7-day DNS read (`hubble_dns_queries_total`, 2026-09-20) — would-drop from `*-agents`:
      `agent-loop-eventsource-svc.agent-coordinator` (the `/coordinate` doorbell — oracle,
      platform), `mcp.minutark.ee` (oracle-agents ~1k; a worker `extraFQDNs` entry the loop CNP
      never receives), `cafe.github.com` (all four, unclassified — no worker ns queries it).
      DNS-only: IP-direct flows unseen. **Next:** add the doorbell leg; decide whether
      `extraFQDNs` render loop-side; classify `cafe.github.com` from a flow capture; make
      enforce a per-stack dial; re-harvest, flip oracle first. Relates FU-020 (archived), #1056.
- [ ] **FU-258** — **Cilium drops the `kubernetes` Service backend on an apiserver restart — POINTER.** Evidence +
      settling experiment: [`docs/spikes/cilium-apiserver-restart-backend-loss.md`](spikes/cilium-apiserver-restart-backend-loss.md).
      **PARKED (operator, 09-20)** behind 1.20.2. Guard: `cp-upgrade` gates the backend (`devbox run maint
      cilium-check`); every OTHER apiserver restart is unguarded — run it by hand. **Next:** the attended bump of
      `cilium_version` to 1.20.2 (class 6, never Renovate; `MgmtSubstrateBehind` standing), then the spike.
      Relates FU-246, FU-253.

## Hardware & nodes


- [ ] **FU-289** — **nx-02 swaps CI memory despite free host RAM; NUMA/VFIO placement. POINTER.**
      [Diagnosis, counters, placement, detectors, boot-disk move, the DIMM window](spikes/nx-02-numa-placement.md).
      Done: detectors (#2040/#2042), wk-04 `numa_pin`, SA400 boot disk, ci-runner-02 unparked (#2048); DIMM
      window closed 2026-10-09 13:47Z (nx-02 125 GiB, nx-01 64 GB mixed parts). **Next:** `PveNumaNodeMemoryLow`/
      `PveHostSwapUsed` silent through 2026-10-16 (clean since 10-09 13:40Z), then the VM memory re-plan
      (wk-04/cp-02/ci-runner-02) is the operator's. Relates FU-266, FU-280.
- [ ] **FU-285** — **Pulling a Longhorn disk silently CO-LOCATES both replicas, and
      `replica-replenishment-wait-interval` does NOT prevent it.** 2026-09-23 wk-metal-04 swap: all four
      `bulk` cache volumes rebuilt onto `wk-metal-01` with BOTH copies on one disk, despite the interval
      raised 600 → 28800 s. **Found 2026-10-03 (Longhorn v1.12.0 source):** co-location is governed by
      `replica-disk-soft-anti-affinity` + `replica-soft-anti-affinity` (both `true` live; per-StorageClass
      override exists); the wait applies only while a failed replica is "potentially reusable" (FailedAt,
      NodeID+DiskID set, retries < max, not EvictionRequested). **Next:** name which condition a pulled
      disk fails, then name it in [`runbook.md`](runbook.md) §Single worker maintenance (the knob is
      named there since 2026-10-03). Relates FU-093, ADR-089.
- [ ] **FU-284** — **Disk health is metered fleet-wide; two gaps remain: POINTER.** `smartctl_exporter`
      on every Talos node + a textfile twin on pve/nx-02, nine growth-based belts (BUILT 2026-09-23).
      Mechanism + evidence: [`storage-ledger.md`](storage-ledger.md) §Build (Disk HEALTH metering).
      **Next:** (a) `DiskMediaErrorsGrowing` is blind on nx-01's BC711 (`media_errors` 1.388e26, a parse
      artifact); a PromQL clamp/exclude cannot restore sight (the +1 is lost at float64 ingestion, 2026-10-03)
      — choose an explicit "implausible counter → blind" belt or a host-side raw read, promtool fixture
      either way; (b) decide whether NVMe lane width wants a standing metric beyond the fit-time `LnkSta`
      check in [`runbook.md`](runbook.md) §Reading a fleet disk's identity and health. Relates FU-222, FU-093.
- [ ] **FU-288** — **Maintenance verbs lack a usable BMC path** (BMC boxes from `machines.yaml` `remote_power`).
      Half landed 2026-10-09: `host-maintenance up nx-02` powers on via ipmitool keyed to wallet entry
      `nx-02-bmc-password` (#2401) — the entry does not exist, so the 10-09 window hand-typed it again.
      `node-maintenance.sh` (nx-01) has no BMC path; CPs have no `down` verb (GAPS `maintenance-window-G2`).
      Design: [`management-box.md`](management-box.md) §MB4 item 7. **Next:** wallet entries for both
      BMCs (operator; rotation rides the management-segment move), then `--bmc` in node-maintenance
      `up`/`down` keyed off `remote_power`, plus the `cp-down`/`cp-up` pair. Relates FU-284.
- [ ] **FU-287** — **Every Alloy restart re-counts the kernel-oops lines still in the kmsg-reader's
      container log, so `KernelOopsCaptured` re-fires on old faults.** Measured 2026-09-23 at
      FU-247's acceptance: with NO new line injected, deleting the `alloy` pod on wk-03 brought the
      counter back at **2** — both synthetic lines re-read from the start of the reader's container
      log (Alloy's positions live on the pod's `emptyDir`). Two consequences: a config-hash bump or
      a node reboot re-fires the alert for any node whose reader log still holds a fault dump, and
      for ~5 min after a restart BOTH series exist (old one stale-pending), so `sum by (node)`
      transiently doubles. **Next:** decide between persisting Alloy's positions (a hostPath dir on
      the node, which is a DaemonSet change) and making the rule restart-insensitive; the lines
      themselves are never lost — they are in Loki. Relates FU-247, FU-190.
- [ ] **FU-286** — **The management box's `talosctl` pin is a nixpkgs rev, not `latest` — revert when
      devbox's index catches up.** devbox's index tops out at 1.13.8 against a v1.14.1 fleet, so
      **PR#1963 (merged 2026-09-24)** resolves talosctl from `github:NixOS/nixpkgs/4975466d…#talosctl`
      (1.14.1), the first flake-ref package in `devbox.json` — `devbox update` cannot move it, so it goes
      stale silently. The belt's `talos` check cleared 2026-09-24 17:00Z (verified 10-03). **Next:** switch
      back to `"talosctl": {"version": "latest"}` once `devbox search talosctl` lists ≥ 1.14.1 (still
      1.13.8 on 2026-10-03; look at the Monday `devbox-update` run). Relates FU-240.
- [ ] **FU-155** — **PSI-stall shared-fate kills RECUR on hardened nodes: POINTER.** Mechanism, evidence
      (incl. the 2026-09-16 FU-246 driver, the 2026-09-28 wk-03 thrash with no kill) and the ⚖ recommendation:
      [`spikes/talos-psi-thresholds.md`](spikes/talos-psi-thresholds.md) §5/§7 (symptom thread homelab#857).
      **Next:** operator rules tune-vs-accept (the Option A pin experiment first, all metal nodes;
      cilium-agent's Burstable pod exposure folds in). Relates FU-139/FU-112, ADR-044.
- [ ] **FU-250** — **The apex consumer claim's Workspace is permanently red: RUM is undeliverable.**
      `pr-oracle-fleet-minutark` fails `POST …/rum/site_info → 403` because no RUM write group exists to
      grant (the #1311 residual). The claim's other resources DO apply, but `Synced=False` is then
      permanent: a state lock stale since 09-09 sat unseen underneath it for a week. A red that is
      always red detects nothing. **Next (operator):** drop `cloudflare_web_analytics_site`/`_rule`
      from the composition (it has never once applied), or gate it on a claim field that defaults off.
      Either way the Workspace must be able to go green. Link: [`docs/cloudflare.md`](cloudflare.md)
      §PublicRoute completion table (RUM row, #1311).

- [ ] **FU-249** — **The ADR-148 lanes (`now` responder + grouped deep dig) are LIVE since 2026-10-04 (PR#2212); the
      old per-blip lane is gone: POINTER.** Steps (1)–(4) done (labels PR#2193; subject residuals, `now` routing,
      filter deleted, deep dig PR#2212). Evidence + the 10-07→10-09 mapping (seven gaps, owners named):
      [`spikes/responder-week-audit.md`](spikes/responder-week-audit.md) §2026-10-09. **Next:** (a) LANDED #2415 (re-dig skip keyed on harvest-stamped
      members) — proof owed: a re-firing subject the dig skips. (b)+(c) reader LIVE: `/board-sweep` (#2416), first
      run 2026-10-14 set a `dig-explained:` marker (#2555); its lane anomalies are the next input (dig 10-10 "5
      findings, wrote 2"; no responder triage 10-11/10-14; dig TOOL_GAPs — TICK-LOG 2026-10-14). (d) `now`-lane
      grouping; (e) the lane's own dependency cone. oracle-fleet's 5 rules lack `triage` (stack lane). Relates FU-230, FU-231.
- [ ] **FU-247** — **Alert on a captured kernel oops.** The `page_table_check` oops sat unread in Loki
      for six days (2026-09-10). **Detector LANDED + PROVEN LIVE 2026-09-23** (#1948): an Alloy
      `stage.metrics` counter on the kmsg stream → `KernelOopsCaptured` per node, a sender-side metric
      (ADR-118; [`loki-tenancy.md`](loki-tenancy.md) §The belt could not stay in the ruler); synthetic
      `kernel BUG at` acceptance on wk-03. **2026-10-03:** both firings since (wk-04 10-01, nx-01 10-02) were
      memcg OOM-killer `Call Trace:` dumps, not oopses — RESOLVED 2026-10-10 (#2428: the marker is now
      `RIP: 0010:`, kmsg fixture in `prometheus-rules-lint`; OOMs stay `PodSigkilled`'s). **Next (install-time, the console half):** nx-01's BMC SOL is `ttyS1`, the metal image
      ships `console=tty0` only — add `console=ttyS1,115200` to the image-factory `extraKernelArgs`. Relates FU-155.
- [ ] **FU-234** — **Ride scratch and the `fast` tier: HOMED 2026-09-24, one loose end left.**
      `fast` had no backing disk from 2026-09-12 (the Optane pair left with `thinkcentre`) until
      nx-01's freed Intel 7600p took the tag — chosen over `bulk` because `bulk` is also read by
      `longhorn-bulk` (replica-2) and that would have made the RIDE/ARC box a service replica host
      (operator, 2026-09-24). **Open:** `longhorn-scratch` (best-effort/`bulk`) and `longhorn-fast`
      (strict-local/`fast`) are **one replica-1 class too many**; retiring one needs a consumer
      migration, not a tag. **Dropped 2026-09-24 (operator): the Optane pair is NOT fitted.** Each
      M10 is 16 GB (~13 G after the 25 % floor), a ride's docker-lib claim is a fixed 20Gi that cannot
      span disks, `longhorn-fast` has no claims, and `fast` has a 238 G home. They'd cost wk-metal-04's
      two free root ports for nothing. Detail: [`docs/storage-ledger.md`](storage-ledger.md) §the scratch class rides `bulk`.
- [ ] **FU-235** — **Declared node state vs live: detected on every axis but one.** The box belt's
      `mgmt_node_drift{node,axis}` (#1828/#1831/#1859/#1861) covers reachable/version/schematic/
      registered/labels/taints/ephemeral_disk, alerting via `MgmtNodeMissing`/`LiveStateDrift`/
      `InstallDrift`; the reconciler (#1864) did its first live sync as the 1.14 rollout (#1879, 13/13,
      2026-09-22). Read 2026-09-24: all seven axes 0 on all 13 nodes, including the kata-label and nx-01
      taint drift this item was filed for. `kubernetes_node_taint` still cannot own `.spec.taints`
      (home = `machine.nodeTaints`): it is detected, not fixed. **Next:** the `install_disk` axis.
      [`management-box.md`](management-box.md) §MB2/§MB4. Relates FU-218, FU-072, FU-252.

- [ ] **FU-277** — **Talos ≥ v1.14 puts the DHCP search domain in every metal-node pod's resolv.conf.**
      v1.14.0 "applies DHCPv4 search domains": `teststuff.net` (dnsmasq) → pod search + ndots:5, so
      `x.ns.svc.cluster.local` tried `….teststuff.net` first → the CF `*.local` wildcard → 127.0.0.1.
      2026-09-22 ~12:50–13:50Z: Forgejo (moved wk-04→hp-01) + Alertmanager→responder dialled loopback.
      Mitigated at the router: Unbound NXDOMAIN for `local.teststuff.net` (opnsense-unbound
      `unbound_nxdomain_wildcards`). VMs are static — unaffected. **Next:** decide whether nodes drop
      the DHCP search (Talos ResolverConfig) so cluster lookups stop leaking to the router; and a
      detector — an in-cluster FQDN probe from a metal node (nothing named the cause; ~1 h down).
      [`cloudflare.md`](cloudflare.md) rollout gotcha 1.
- [ ] **FU-268** — **No detector for control planes that disagree, or for undeclared cluster components.**
      wk-metal-02 ran without the CP cluster patch for ~10 h (2026-09-21): flannel on all 13 nodes
      beside Cilium, and an apiserver refusing kata rides. Nothing fired; oracle's issue found the
      admission half, a seat `talosctl` read found flannel ([controlplane-ha.md §CP9](controlplane-ha.md)).
      Not FU-235's drift: live matched git, git differed per CP. #1848 fixes this path; the belt
      catches the next one. **Next:** alert on CP config divergence (the `cluster:` section's hash
      per CP, via the box or an exporter), and/or on a `kube-system` DaemonSet/Deployment missing
      from git. Detector-first: replay against 2026-09-21 05:50–16:20Z. Relates FU-235, FU-243, #1845.
- [ ] **FU-262** — **`wk-metal-02` is a control plane wearing a worker's name.** One of the three
      CPs since 2026-09-21 (ADR-133), still `wk-` in `kubectl get nodes`, etcd membership, BGP peer
      lists and every dashboard. The convention is settled — [ADR-137](adr.md): CPs are `cp-NN`,
      workers keep ad-hoc names — so the target name is **`cp-03`**.
      **Why deferred:** the hostname is pinned at INSTALL (`HostnameConfig`, `metal.tf`, provider
      #296); changing it on a running node ghosts it, and the rename drops etcd to two members
      while it runs. It also touches machines.yaml, the dnsmasq reservation, `bgp_node_ips` and the
      generated tables. **Next:** do it with the box's NEXT reinstall for any other reason, never
      as its own outage. Relates FU-243.

- [ ] **FU-034** — Buy a network Zigbee coordinator (SLZB-06 class) — unblocks local radios
      (ADR-041, Open).

## One-time ops

- [ ] **FU-157** — **Cloudflare platform tokens are USER tokens; migrate to ACCOUNT tokens
      opportunistically.** All of tofu/cloudflare-token mints `cloudflare_api_token` (tied to the
      operator's user). Account tokens (`cloudflare_account_token`) are org-owned, have a coarser
      catalog (single DNS perm — no DNS vs DNS-Settings split, operator observation 2026-08-09),
      and the provider's 5.13.0 policy-order fix covers THEM (api_token still needs our sort()
      workaround). Not urgent for a 1-person org: migrate per-token whenever one next needs a
      re-mint anyway, never as a big-bang (each migration = mint + store + consumer re-verify).
      Doctrine reminder while doing any of it: permission SEMANTICS come from the target
      endpoint's "accepted permissions" docs line, never the catalog name (`devbox run
      cloudflare-token-audit` renders minted reality readably). Relates FU-156.
- [ ] **FU-156** — **Credential-expiry BELT (re-scoped 2026-08-08, operator: dates-in-git is the
      wrong system).** Gauge `credential_expiry_timestamp_seconds` + `CredentialExpiringSoon` (<30d) /
      `CredentialExpiryImminent` (<7d), `triage: none` → HA; `CredentialExpiryProbeBlind` for a dead
      poller. Design: [`docs/secrets.md`](secrets.md) §Credential expiry is telemetry. **Cloudflare
      live-poll leg LIVE 2026-10-14 (PR #2559, verified: 5 series = the 5 expiring tokens, earliest 2027-01-01;
      probe_ok 1; rules loaded)** (`cloudflare-credential-expiry-probe`). **Next:** the declared-expiry half — `.p12`s (`openssl`), the ghcr classic PAT
      (`GHCR_MIRROR_PULL_EXPIRY`), GitHub PATs — emitting the same gauge under their own `provider`.
      Relates FU-150 (silent-expiry class), FU-039.
- [ ] **FU-036** — AWS cleanup: delete the orphaned Route53 hosted zone `ZCGRPARGVE3CW` (+ the
      leftover ACM/Sectigo certs its `_*` validation records imply). Needs admin SSO (the jail key
      is read-only). Recipe: `docs/cloudflare.md`. Optionally do it as the first `tofu/aws/` root
      (which would also adopt the audit user, `scripts/aws-bootstrap-audit-user.sh`).
