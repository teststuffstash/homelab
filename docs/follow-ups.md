# Follow-ups (the FU tracker)

Running list of loose ends and deferred work — the stuff intentionally not finished yet. Bigger
parked *features* live in `ROADMAP.md` → "Backlog / parked features"; this file is the operational
tracker.

**Conventions (the contract):**

- Every item has a stable id **`FU-NNN`** (3 digits, sequential, **never reused**).
  Next free id: **FU-286** (2026-09-23: FU-285 minted for the replica co-location a disk pull
  caused, which `replica-replenishment-wait-interval` did NOT prevent; FU-284 minted for
  fleet-wide disk-health metering — nothing watched any drive's SMART and the fleet buys used
  drives with disclosed defects; FU-283 minted for the hung-CI-run watchdog, from oracle's
  fleet-strike handoff; FU-282 minted for the origin mark's `wg.`-named egress
  record, deferred because it needs a live OPNsense apply; FU-281 minted for the goal-checkpoint trigger side waking on
  nothing — operator's fix; **FU-280 is taken by the registry-backend spike, PR #1905 in flight**.
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

_Last updated: 2026-08-25 (fu-sweep after the evening board-sweep, machine-lane reconciled by
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

- [ ] **FU-208** — **runner image is oversized for the sentinel (4.9 GiB for a devbox-lint job).**
      Rollout shape SHIPPED 2026-09-04 (PR#1367): two DaemonSets split on `topology.kubernetes.io/zone`
      — metal two-at-a-time, pool VMs one-at-a-time behind an init gate on
      `pve_lvm_thin_pool_data_percent` < 75 (no sample = hold); first bake (#1366) took the pool
      71 → 79 % and the gate HELD wk-03, by design. **2026-09-05: the pool's post-trim floor is
      ~80 % (79.6 after the 03:35 trim, 81.0 after a manual one), so the gate is a PERMANENT hold** —
      wk-02's pod sits `Init:0/1`, the kube-prometheus defaults (`KubeDaemonSetRolloutStuck` /
      `KubeContainerWaiting` / `KubePodNotReady`) fire on it, and a runner landing on wk-03 pulls the
      same 4.9 GiB ungated. **Next:** a sentinel-scoped closure (or a second, small image for
      `agents/coordinator/sentinel-argo.yaml`) — hundreds of MB. Relates FU-015, FU-093, FU-207, #80.

- [ ] **FU-205** — **WAN-upstream accounting: one view of what hits GitHub/PyPI/ghcr/… from
      where** (operator ask 2026-09-02 after two same-day WAN-limit incidents; no FU/ADR covers
      it). **Hard constraint (operator): FAMILY traffic must never reach the cluster** — so raw
      router NetFlow cannot export to Prometheus unfiltered, and flowd has no src-CIDR filter:
      either the **homelab VLAN** (capture/export per-interface = structural filter — the real
      argument for the VLAN, reframed from my visibility-only first take) or router data stays
      router-local (Insight, operator-eyes). **CI VMs (ci-runner-01, the jail host) are outside
      Hubble** — they need host-side counters (nftables per-provider-CIDR sets → node-exporter
      textfile) shipping homelab-origin data only. Already live: Hubble per-ns DNS/drops;
      per-identity `github_rate_limit_remaining`; Insight on-router. Next: the design pass
      (VLAN-vs-router-local + the VM counter leg + the Grafana join). Link: the 2026-09-02
      loop-outage postmortem §Residuals.

- [ ] **FU-204** — **C4/C5's bare-mention exclusion is a silent-stall limbo** (2026-09-02, first
      live sighting: fleet#345 — its r1 died on a model rate-limit, the label stayed
      `agent/in-progress`, and assembly PR#346's coverage-map bare mention excluded it from BOTH
      the stall wake and the review flip; only a human re-tick recovered it). The exclusion is
      deliberately conservative (the circles#36 sibling-seam lesson) but has no escape hatch.
      Needs a design ruling: age-bound the exclusion, or wake-with-marker for coordinator
      judgment instead of auto-requeue. Evidence:
      `docs/incidents/2026-09-02-anonymous-git-throttle-loop-outage.md` §Residuals; the clause:
      `agents/coordinator-scan.sh` C4/C5.

- [ ] **FU-223** — **Does Longhorn honour `fsync` end-to-end?** The 2026-09-07 A/B measured a
      Longhorn replica-1 volume at **1.9× the IOPS of raw XFS on the same physical device** with
      fsync after every write ([storage-ledger](storage-ledger.md) §2026-09-07). That is not
      physically possible for a flushed write, so the engine is plausibly acking a flush it has not
      pushed to the device. Load-bearing, not academic: ADR-114 set `metadata_fsync = true` because
      LMDB's `MDB_NOSYNC` default WAS the 2026-08-24 wipe mechanism — on a Longhorn-backed meta
      volume that setting may not mean what it says. **Next:** power-cut or `sync`-semantics test
      (write with fsync → hard-stop the replica → verify the last acked writes survived), before
      Garage metadata rides Longhorn. No prior FU/ADR covers Longhorn fsync semantics (grepped
      `fsync|durability|Longhorn` 2026-09-07). Link: ADR-114, FU-137.
      **Extended 2026-09-10:** the same rig answers the OTHER open question — the engine's cost is
      CPU, not bandwidth (ledger §2026-09-07 amendment: `instance-manager` 0.5–0.9 core per zone
      node, 5–8× Garage; disks 7–15 % busy behind a 34–96 % busy Longhorn device). Measure **CPU
      per fsync'd IOP at queue depth one**, raw XFS vs Longhorn replica-1, same device — one
      experiment settles fsync honesty AND whether Garage moves to node-local storage (the
      `user_volumes` partition, install-time only). Not on the X240: it leaves the zone role first.

- [ ] **FU-224** — **`longhorn-manager` throttles at its 150m CPU limit.** Grafana's throttling
      panel (operator, 2026-09-07) shows 4–14 % of CFS periods throttled per manager pod over an
      hour (`longhorn-manager-fxr4s` 13.9 %), cilium agents 4–13 %. Not a data-path contamination of
      the ledger's engine measurement — `instance-manager` carries the I/O and has NO CPU limit — but
      the manager IS the attach/rebuild/scheduling plane, and the 150m req==limit came from the
      FU-112(b) Guaranteed-QoS ruling, sized for memory not CPU. **Next:** raise the manager CPU
      limit (300m, keep req==limit) in `tofu/longhorn.tf` on a quiet day — it rolls the DaemonSet,
      so not mid-migration; re-read the panel a week later. **Re-sighted 2026-09-08 (operator, the
      panel): `cilium-rzv4p` at 30 %** — that one was wk-03's post-resize restart (53 % at 13:11Z,
      2 % five minutes later: agent start-up at its 250m limit, transient). The steady-state
      picture is the FU's: cilium agents 11–17 % on the slow-CPU boxes (wk-metal-03, hp-01, m70s),
      longhorn-manager 9–21 %, and `transcripts-viewer` 55 % at a 1-CPU limit on hp-01 (all of it
      the bucket-sync container, 62 %). **Applied 2026-09-08 (operator: "run all of it"), PR#1519:
      manager 150m→300m, cilium agent 250m→500m, bucket-sync 1→2** — both DaemonSets rolled with
      the oracle delta job running, volumes healthy throughout. **Next:** re-read the throttling
      panel ≈2026-09-15; if manager/cilium sit under ~5 % and the sync burst under ~20 %, archive.
      No FU/ADR matched `throttl` (grepped 2026-09-07). Link: ADR-089, FU-112.

- [ ] **FU-229** — **Garage SLO breached on its own 30-day window and nothing alerts; CI-hour
      write churn unattributed.** 30-day reads 2026-09-10: availability garage-1 99.90 %, garage-0
      98.0 %, garage-2 98.1 % (objective ≥ 99.95 %); p99 read 4.1 s / list 10.3 s (objectives 2 s /
      5 s). Rules exist since #1588; **no latency/burn-rate belt yet, by ordering (operator,
      2026-09-13): garage-2 leaves the X240 FIRST, or the alert fires on every CI run** — 2026-09-13
      09:30–11:05 showed why: an `allure-reports` burst (+2.5k objects on 635k) with ARC runners on
      the same laptop → PutObject p99 69 s, ListObjectsV2 18 s, garage-2 7.9 s vs 1.7/1.9 s on the
      other pods, Longhorn's instance-manager at 1.5 cores. **Next, in order:** (1) garage-2 off the
      X240 (the third std SFF, fleet-roles direction; ledger via FU-137); (2) THEN alerts on
      `garage:s3_latency_seconds:{p50,p99}_5m` per endpoint + the 30d burn rate, and re-read;
      (3) attribute one CI-hour window by bucket from the S3 access log (the #499 method).
      Resights: 09-16 (oracle handoff) CI PUT bursts 8–13/s → ~500 meta-volume writes/PUT on
      garage-2's Longhorn meta, GetObject p99 17 s; 09-22 16:28Z a runner sync stalled the ert parse.
      Link: FU-093, FU-137, oracle-fleet#499/#518/#547.
- [ ] **FU-203** — **The first-party registry has no retention: POINTER** (born with ADR-121).
      The cap fired 2026-09-07 (20Gi) and 2026-09-09 (32Gi): a blob COMMIT holds the layer twice, so
      `quota − held ≥ 2×layer` — rule, both failures, storage read, retention ownership AND current
      status: the header of [`garage-workspace.yaml`](../argocd/resources/registry/garage-workspace.yaml);
      cap **48Gi** (#1578). **LIVE:** the quota belts (#1577), the collector (`registry-garbage-collect`,
      **daily 03:00Z** since 2026-09-22, #1902), and since 2026-09-14 **the POLICY half** —
      oracle-fleet's nightly `retention` CronWorkflow untags outside its keep-set (02:30Z).
      The SCHEDULE MISMATCH that cost three firings (09-07, 09-15→16, 09-22) is closed by #1902.
      **Next:** watch one unattended daily cycle reclaim (first due 2026-09-23 03:00Z), then archive.
      Relates FU-279 (MPU debris, a pool this misses). ADR-121/-089/-085.
- [ ] **FU-279** — **Garage-side incomplete multipart uploads are debris nothing collects.**
      `UPLOADPURGING` deletes the `_uploads/` objects, `garbage-collect` does not walk MPUs, so they
      accrue forever: 4.3 GB from 2026-09-02/09-10 still held on 09-22. It is **raw disk only**
      (~13 GB at rf=3), never headroom — `garage_bucket_bytes` counts completed objects only, so it
      cannot move `RegistryBucketCommitHeadroomLow`. Mechanism + the 09-22 measurements: the header of
      [`garage-workspace.yaml`](../argocd/resources/registry/garage-workspace.yaml). Deferred by the
      operator 2026-09-22: the reclaim command carries the ☠ in
      [`2026-08-24-…-meta-wipe.md`](incidents/2026-08-24-pve-thin-pool-garage-meta-wipe.md) (an abort
      drops blocks it read to rc=0 — 3,952 blocks lost), scoped to a bucket under recovery, not this.
      **Next:** decide when zone headroom presses (~79/150 GiB); if yes, age-gate + verify rc after.
- [ ] **FU-274** — **First-party images still ride the ghcr pull-through mirror.** Its three biggest
      tenants are ours (`oracle-fleet-ingester`, `agent-base`, `oracle-fleet-static-site`: 320 revisions on
      2026-09-22), so our release churn sets the mirror's size. The registry's only size knob is the TTL, and
      that TTL nearly filled it (720h left over from FU-196 v0; #1870 set 168h + 150Gi). Serve
      first-party images from `registry.teststuff.net` (ADR-121's "later"). The mirror then holds
      third-party images only. **Next:** per-repo keep-sets + quota there first (FU-203: 48Gi cap,
      only oracle-fleet has a policy), then dual-publish → pin flip per image. Relates FU-196, FU-203.
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
      until someone edits the datasource. (b) `ingestion_rate_mb` is PER TENANT, so the flip
      raised the aggregate ceiling ~32x; left at 8 until the flip's own per-namespace baselines
      exist — **due ~2026-09-03**, and until then ADR-118's "per-tenant ingest limits" win is not
      banked. (c) the OTel rail writes under a static `monitoring` tenant. **Next:** (b) — the
      only one with a date and real evidence. Detail + options:
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
      workload; the trigger is a hand-bumped annotation, and forgetting it is SILENT** —
      `kubectl get cm` shows the new config while every pod runs the old, so a probe that reads
      the ConfigMap passes. TWICE live on 2026-08-27: ADR-118's `__tenant_id__` (Alloy pods 1–2
      months old), then `StatefulSet/loki` with **no annotation at all**. Evidence at the sites,
      [`alloy.yaml`](../argocd/resources/loki/alloy.yaml) + `loki.yaml` `config-hash`.
      THIRD sighting 2026-08-31: `blackbox/blackbox.yaml` (no annotation) — PR#1141's
      `dns_github` module synced but the 5d-old pod served 400s to every probe scrape
      (`blackbox-unbound-github` TargetDown ~3h) until a manual `/-/reload`; the new belt
      shipped dead. FOURTH 2026-09-03: `cf-api-proxy` (no annotation, nginx renders the
      ConfigMap at start) — G-G's allowlist synced, the 8d-old pod 403'd the first consumer
      profile apply ("write outside dns_records/cfd_tunnel"); `rollout restart` by the seat. **Next:** audit which other raw resources mount ConfigMaps — the count
      decides between kustomize `configMapGenerator` (no human step, proven in-repo:
      [`otel-collector/`](../argocd/resources/otel-collector/kustomization.yaml)) and a CI check
      reddening on a `*-config.yaml` moved without its consumer's annotation. ⚠ generator +
      ArgoCD prune deletes the OLD hashed CM the moment the name rolls — a rollback then
      references a pruned CM (Brian Grant, itnext.io/…-1431398c0866, bookmarked). Relates ADR-083.

- [ ] **FU-137** — **Garage durability + metadata reclamation: POINTER.** Fired 2026-08-24 (meta LMDB
      wiped with the pve thin pool — [incident](incidents/2026-08-24-pve-thin-pool-garage-meta-wipe.md),
      homelab#884). **ADR-114** + addendum + 2026-09-07 amendment answer both halves; mechanism and
      numbers live in [`garage.md`](garage.md) and the [ledger](storage-ledger.md). Done: rf=3 across
      three physical zones (09-07); the unattended rotation loop (09-09); garage-1 on its own PM961
      (09-12); CNPG required zone anti-affinity (09-21, #1840/#1842, oracle-iac#900); CNPG replica-1
      (09-21, #1843 — ledger §2026-09-21; stack clusters wait on a zone node label). **Next:** the
      backup CronJob (ADR-114's logical-deletion class). Operator intent: metadata maintenance is
      unattended. Relates FU-013, FU-012, FU-093, FU-223, ADR-031.

- [ ] **FU-076** — **Re-check the metal reinstall mystery on the next metal (re)install**: a
      maintenance-mode reinstall of wk-metal-03 applied config verifiably carrying the
      metal_kata installer URL yet produced the plain-metal schematic (fixed via `talosctl
      upgrade`; likely also the origin of the kata `/dev/kmsg` regression, see
      `docs/spikes/kata-ci-gate.md`). Verify install.image is honored from maintenance mode.
- [ ] **FU-072** — **The kata service-VIP workaround is REMOVED; soaking.** The original symptom
      (kata guests black-hole `10.96.x` VIPs, runc pods on the same node fine) was re-probed GONE
      on all four kata nodes 2026-09-03 and never root-caused — but the workaround it justified
      resolved a pod IP once at dispatch and cost three rides in two days (the third to a
      DiskPressure eviction, not a deploy). History, symptom matrix and all three occurrences:
      [`docs/spikes/kata-service-vip.md`](spikes/kata-service-vip.md). **2026-09-04 (PR#1372):
      `resolve_ep`, the three rewrites and `dnsPolicy: None` deleted** — every ride uses service
      DNS; verified by a kata pod under the ENFORCED fixer CNP (proxy/garage/pushgateway VIPs
      answer, `openrouter.ai` still denied). **Soak is TWO legs (operator correction 2026-09-04):
      (1) the service-VIP leg — PROVEN by oracle-fleet 432-r1 (kata, wk-metal-04, 11:40Z, enforced
      CNP): LLM loop + `/report` through the proxy svc name, phase metrics to the pushgateway svc
      name, transcripts uploaded to garage → PR#434 in ~10 min, zero drops; (2) the dind/kind leg —
      UNEXERCISED: only a `task/build` ride runs `devbox run e2e` in-pod (`devbox run ci` starts no
      kind), and in-pod kind has its own open fault (the #399-r1 node-image segfault + the mirror-bypass question —
      [`spikes/kata-ci-gate.md`](spikes/kata-ci-gate.md) §In-pod kind on a kata ride).
      Next:** watch the first in-pod `devbox run e2e` under kube-dns (the only thing the change
      touches for kind: `dnsPolicy: None` → kube-dns). The regression signature stays
      `AgentWorkerEgressDropped` carrying a BARE POD IP as its Hubble destination;
      `git revert 773ad63e` if it returns. Once soaked, drop the now-dead CNP
      LAN-resolver DNS leg and the `endpoints`-read grants. Relates FU-116, FU-187.

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
      **Next:** box-scoped credentials — the `scripts/mgmt-provision-secrets.sh` table is the JAIL's
      entries, swapped one line each as minted; **first: a scoped read-only kubeconfig for the box's
      plans** (the #1635 finding — `main` + `cloudflare` plan PR heads with the admin kubeconfig;
      stage 1 denies new `kubernetes_*` data sources / `import` blocks meanwhile). Snapshots: #1834. Relates FU-097, FU-136.
- [ ] **FU-013** — Home Assistant `/config` (and other stateful data) backup → Garage S3 with the
      bucket-id in git — the missing "boot-from-git" DR leg (Longhorn replicates in-cluster, it
      doesn't DR). `tofu/homeassistant.tf`.
- [ ] **FU-039** — **Platform self-service (XRD claims) — next legs: POINTER.** The
      public-ingress leg's design, completion-state table (built + ARMED 2026-08-08, zero
      consumers) and open legs (test claim, ha retrofit = consumer #2, zone-phase rulesets,
      product zones, the edge-metrics GraphQL poller whose FIRST deliverable is the replacement
      edge-5xx belt — none exists since #350/#363): [`docs/cloudflare.md`](cloudflare.md)
      §PublicRoute + §Observability. Still thin homelab PRs per stack: LAN subdomain opt-in
      (ADR-092), git repos, AppProject/ns. **Next:** zone-phase ruleset aggregation (one claim per
      profile per zone today) and the ha retrofit as consumer #2 — the first consumers are live and
      checked (cloudflare.md completion table, homelab#1334).
      Program: `ROADMAP.md` → "Platform self-service via Crossplane".
      Relates ADR-076, ADR-085, ADR-092, ADR-101.
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
- [ ] **FU-215** — **Unbound SERVFAILs `github.com` names in short windows — reason READ 2026-09-16:
      `exceeded the maximum number of sends`; belt applied; root cause = do-ip6 on a v4-only WAN.**
      Windows 09-05 ×4, 09-16 16:35–17:00Z (browser, jail `gh`/`git`, CI's Actions results-receiver).
      Operator's resolver-log export: 39 SERVFAILs, every one "exceeded the maximum number of sends"
      (retry exhaustion — the nsone authoritatives answered the LAN directly throughout). **Belt
      LIVE** (PR pending, `unbound_advanced`): `prefetch` + `serveexpired` (stale ≤ 1 d, reply TTL 30,
      client-timeout 1800 ms — RFC 8767). **Root cause (evidence):** infra cache holds 389 IPv6
      name-server entries at the never-measured 376 ms placeholder while the WAN has NO IPv6 — OPNsense
      sets `do-ip6` from Interfaces → Settings → *Allow IPv6* (`unbound.inc`), a legacy page with no
      API. **Done 17:55Z:** *Turn off IPv6* ticked (LAN had no v6 at all), Unbound restarted — infra cache
      0 IPv6 entries, github/LAN/public names NOERROR. **Next:** soak — `UnboundGithubServfail` quiet for
      a week → archive; the GUI-only knob is recorded in `docs/runbook.md` §OPNsense as code.

- [ ] **FU-051** — **Prove a dep bump flows E2E for the operator-chart and pod-image shapes**
      (the app+chart shape is proven — sleep-tracking digest bump 2026-07-05 → sleep-iac deploy PR
      auto-merged). **snore-recorder leg BUILT 2026-08-02** (most of it had landed earlier via
      sleep-iac#13-16 — hook, cron, ESO, known_hosts): the residue shipped as snore-recorder#15
      (CalVer + deploy-pin.sh, `ci` script, `.agents/` recipes, dup ansible deleted) +
      sleep-iac#57 (fixer block — snore is IN THE LOOP). Step (1)'s apply turned out ALREADY DONE:
      the operator's 2026-08-12 host-side plan read "No changes" with snore-recorder committed in
      deploy_repos — it rode an earlier apply (~2026-08-04, the circles-secret fix) unrecorded.
      **Remaining:** (1) observe one real snore build → pin PR → Pi converge E2E (organic);
      (2) the first half (operator-chart + pod-image shapes). Relates FU-097, ADR-084.
- [ ] **FU-125** — **Renovate silently REGRESSED to zero dependency PRs — while reporting
      success** (measured 2026-08-01: all 10 autodiscovered repos abort; same silent-success
      class as FU-108/FU-113). Evidence + inventory:
      [`docs/dependency-upgrades.md`](dependency-upgrades.md) §"Ground truth".
      **Next:** absorbed into the Renovate Goal — homelab#502, closed back into the ROADMAP
      work map (row G-D; its body is the launch draft). Acceptance items there: App permission
      diff, liveness gauge, prPriority + `NIX_VERSION` hygiene, the pin-dependencies branch.
      `dependencyDashboard: false` by ruling 2026-08-18 (liveness = the exporter gauge ONLY).
      This item closes when that Goal launches and validates. Relates FU-046, FU-097, FU-016.
- [ ] **FU-097** — **The box's capability ledger** (was: the per-surface ruling table). **Reshaped
      2026-09-22 (operator):** per surface, record what the box has been TESTED doing on its own
      (date + evidence) and its auto-apply TOGGLE. No codeowner column. On box-applied surfaces the
      codeowner read becomes an **intent review**, a new reviewer instruction: does the plan +
      install-impact line do what the issue asked, given what the fleet and the box already run?
      Anchors (2026-09-13): router/CPs/Proxmox stay human; the raw-k8s residue belongs to the box; `provisioning` = canary.
      **First toggle BUILT 2026-09-22:** the loop auto-applies Talos config changes (`no_reboot` only,
      health-gated); `apply_controlplane_config` built OFF, flipped ON 2026-09-22 (operator)
      ([`management-box.md`](management-box.md) §MB3 "Talos config applies").
      **Ledger section LANDED 2026-09-22 (#1893):** management-box.md §The capability ledger.
      **Next:** the intent-review instruction in `.agents/review.md` (operator-direct; draft in
      meta-state). Relates FU-012, FU-235.
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
      2026-09-21; no flag stands in git.) **Next:** the `flags.local.tf` shape + the lint. End state: the reconciler sets and clears flags inside one sync. Relates FU-235.
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
      `devbox run` rewrites it, so disagreeing runners flip-flop the lock: the ARC image pinned
      0.17.5 (it writes the committed lock), the jail's install-script LAUNCHER and the host float
      (0.18.3, dirtying the SHARED tree), the box runs nixpkgs', agent-base rides upstream's image.
      Mitigated: `mgmt_clone`'s dirty check ignores the lock. 09-20: converge on **0.18.3** — PR#1809
      (ARC ARG + the lock) and claude-jail `ENV DEVBOX_USE_VERSION` (6f90815, live on rebuild).
      **Next:** the box closure overrides `devbox` to it, then drop the exclusion; agent-base's base
      tag. Upgrades = ONE change: ARC ARG + jail ENV + host + the lock. Relates ADR-129, FU-237.
- [ ] **FU-070** — **Main-repo bootstrap: MIDDLE GROUND BUILT 2026-08-03 (operator ruling —
      template repo REJECTED: unexercised templates stale by construction).** `new-stack --from
      <donor>` mechanically copies the shared surfaces from the LIVING donor checkout (content
      can't stale; the surface LIST asserts loudly when it does) + emits a VANILLA deployable
      chart/Dockerfile (pipeline-proof day one — product shape arrives via specs/goal issues)
      + prints the LLM-adaptation worklist (the judgment half). **Next:** first consumer =
      circles; then the cross-stack drift role (roles.md) owns long-term convergence — this
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

Sub-grouped 2026-08-07 — the block had reached 34 of the tracker's 57 open items and read as one
lump, so nothing could be scanned by concern. The groups are the loop's own stages, not invented
taxonomy: an item belongs where its NEXT ACTION lands. Keep them; adding a sixth group is a signal
the block needs pruning, not more headings.

### Dispatch & issue lifecycle — the scan's clauses, holds, doorbells, and how an item moves

- [ ] **FU-281** — **The goal-checkpoint wakes on nothing — the trigger side is the token sink.**
      Fleet read 2026-09-23 (comments on the six Goals with a store): 19 checkpoint rulings, 11 of
      them on #1640, where 4 fired on trigger (c) for ONE new member (two were sprouts filed
      minutes after the previous checkpoint; one re-fired on rulings already written) and the
      (a) rides found two thirds of their findings already filed / folded / fixed. Every ride
      cost a sonnet session. The WRITE side is fixed (PR #1933: rulings are store rows, the
      timeline stays flat); this is the READ side. Operator-owned: the pendulum went from
      "not enough" (goal #278 stalled) to "too much". Candidate levers, undecided: debounce (c)
      by member age or fold it into the next (a)/(e) wake; let the scan pre-rule the
      deterministic findings (origin closed by a merged PR, surface+origin matching an open
      issue) so the session sees only the residue. **Next:** operator picks the lever; measure
      rulings-per-Goal before/after on `goal_timeline_comments` + the `last-checkpoint:` line.
- [ ] **FU-178** — **Two readers, one mirror: the doorbells read `agents/stacks.json` while the
      scan reads the live cluster claim** — a claim change (chain redirect, knob flip) reaches
      the scan in minutes and the doorbell side only when someone remembers to sync the file
      (found live 2026-08-02: a redispatch rode the file's stale chain two hours after the claim
      moved). Rescued 2026-08-19 (the untracked-work sweep — its only home was a meta-state durable
      warning). **Next:** doorbell-side callers (`coordinator-session.sh`, `agent-session.sh`,
      `coordinate-ring.sh`) read the cluster with the file as the probe-failed belt — the same
      merge `stacks_json()` already does; or extract that seam for the launchers. Relates
      FU-049 (generating the mirror), ADR-085.

- [ ] **FU-168** — **Dispatch revisit (#278 closeout): build + soak.** (a) concurrency shipped
      2026-08-12 (the A2 famine PR; `AgentDispatchCronWoken` is the acceptance instrument —
      cron-woken ≈ 0 once soaked); (b) `Touches:` fence demotion + governance lint = Bucket A4.
      Evidence: [`docs/spikes/goal-lane-v1.1-fu165-pilot.md`](spikes/goal-lane-v1.1-fu165-pilot.md)
      findings 4–5. **⚠ The (a) soak read FAILED 2026-08-25**: `changes(cron_woken[24h])` = 2
      and 5 — #459 fires legitimately, a dead doorbell edge remains. **Next:** the emitter hunt
      (the scan states wake source per dispatch), on #459; then A4's fence half; close when
      cron-woken ≈ 0 holds. Relates ADR-106, ADR-094, ADR-097, FU-167.

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
- [ ] **FU-182** — **The pushgateway grows without bound and its reads slow linearly (no TTL on
      pushed groups).** 486 KB / 3298 lines at 2026-08-23; serve 3.7–5.3 s — froze goal #775's
      budget gate (homelab#807 fixed the READER; this is the WRITER side). **2026-08-24: the
      growth also LOGGED — the in-pod emitter pushed `agent_run_phase_seconds` without the
      launcher's HELP line, and the gateway logs ~256KB per conflicting group pair per 30s scrape:
      48.7 GiB/day, 98% of Loki ingest, what filled the loki bucket (homelab#811). Emitter fixed
      byte-identical (agent-runtime#84); 148 dead in-pod groups DELETEd one-off.**
      **Next:** group hygiene — a cleanup pass (cron or push-time) deleting groups for terminal
      rides older than the ledger's retention need, sized so reads stay flat. Relates FU-131,
      homelab#807, observability §B1.

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

- [ ] **FU-201** — **The arbitrate "re-dispatch stronger" verdict has no carrier to the router**
      (operator, 2026-09-01: "they did not meet") — chainless deleted the chain-walk, ADR-094
      bars freelancing a model id, and #459/#329 both PARKED human-first while route() already
      honors label-borne class (labels ride /route bodies; label_map is the git home).
      **Ruled same day ("flesh out the existing things"): the carrier is the EXISTING size
      label.** **Next:** (a) escalation = `agent-budget/*` RE-GRADE by the arbitrate/breaker
      plays; label_map gains md/lg rows (lg → floor raise + never-free; FU-174 effort later);
      (b) a brief section naming the label vocabulary per play (cites label_map, never copies);
      (c) provider outranks model class — strikes gain the served-provider column, serving-shaped
      strikes exclude the (model, provider) pair on re-pick (#783 legs; quality = FU-186/ADR-115
      pin-v2 + M14 pair-cooldowns). Rejected: task/build as routing basis, `model/strong`,
      attempt-count auto-escalation (banked, feed-4). (c) is BUILT but dead in production THREE times
      (#1268; 2026-09-13 `no-output` ∉ STRIKE_CLASSES, enforce flag unset; 2026-09-23
      `repetition-loop` ∉ `strike_classes` — oracle's #712/#713 fleet strike was never recorded,
      no cooldown formed, the router re-picked the same cell `[free+half-open]` 13:05:01Z) →
      homelab#1640 acceptances 1+3. The 09-23 round also exposed the identity questions UNDER the
      strike: [`docs/spikes/model-identity-free-vs-paid.md`](spikes/model-identity-free-vs-paid.md).
      Relates FU-174, FU-186, ADR-094/096/115.

- [ ] **FU-285** — **Pulling a Longhorn disk silently CO-LOCATES both replicas, and
      `replica-replenishment-wait-interval` does NOT prevent it.** 2026-09-23 wk-metal-04 swap:
      with `intel0`/`intel1` out ~70 min, all four `bulk` cache volumes rebuilt onto `wk-metal-01`
      with BOTH copies on one disk (498 G → 730 G scheduled, 147 %) — the ledger's soft-anti-affinity
      trap, live — **despite the interval being raised 600 → 28800 s for exactly this.** So a replica
      on a MISSING DISK takes a different path from one on a DOWN NODE; `replica-auto-balance:
      least-effort` is a second untested candidate. Self-repaired on refit, no data lost (re-warmable
      caches). **Next:** find which controller does it and name the knob that actually governs it in
      [`runbook.md`](runbook.md) §Single worker maintenance — a future session reaches for the same
      wrong lever. Relates FU-093, ADR-089.

- [ ] **FU-284** — **Disk health is metered fleet-wide; NVMe PCIe lane width still is not: POINTER.**
      Until 2026-09-23 nothing watched any drive's media — every wear/fault read was a hand-run pod
      (FU-222) — while the fleet buys used drives with *disclosed* defects, so the belts alert on
      GROWTH, never absolute counts. Built: a `smartctl_exporter` DaemonSet on every Talos node +
      the same metric names from a textfile collector on pve/nx-02, nine promtool-fixtured belts.
      Mechanism, evidence and the design call: [`storage-ledger.md`](storage-ledger.md) §Build.
      **Next:** `smartctl_device_interface_speed` is SATA-only, so **NVMe lane width is uncovered**
      — the trap that left x1-wired adapters in both NX boxes. Fit-time check is in
      [`runbook.md`](runbook.md) §Reading a fleet disk's identity and health; decide whether it
      also wants a standing metric. Relates FU-222, FU-093.

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
      defect. **Next:** strike consumers (coordinator brief chain-walk + launcher re-dispatch)
      treat key-class `error_class` as RE-MINT + same-model retry, never a model strike —
      router-first set (chainless-redesign ⚖). Relates FU-201, agent-runtime#85, FU-180.

- [ ] **FU-171** — **A long Go-served review outlives the ~1h git token (observed 2026-08-14).**
      The #447 review ran 47 min (kimi-k3, **$6.33** — balance regime, FU-170); the dispatch-time
      installation token 401'd ~07:50Z BEFORE the verdict posted — a full CHANGES_REQUESTED lost
      (recoverable: S3 reviewer-r1 transcript + pod log); `/var/run/reviewer-git/` never refreshes
      mid-session. Interim mitigation LIVE same day: reviewer Go-failover model kimi-k3 →
      deepseek-v4-flash (direct-to-master, operator) — cheaper/faster rounds fit the token window.
      Next: mid-review token refresh (re-mount/re-mint on 401); re-verify on the next >30-min
      review. Relates FU-170, #435 (review-state snapshots proved their worth here).
      **RESIGHTED 2026-09-01 on the COORDINATOR arm** (oracle #328 item session, 09:20–09:49Z,
      only 29 min): `LOOP_FETCH` mints ONCE at PREP and the per-stack ns holds no refreshable
      mount, so a broker token already partway through its hour 401'd every write — the session
      misread it as "coordinator-git Secret empty" (the Secret is absent BY DESIGN in `<stack>-agents`)
      and could not even restore its item to `agent/queued`. Same fix shape: re-mint on 401 in the
      gh wrapper, both arms.
      **RESIGHTED 2026-09-01 (3rd, REVIEWER arm, subscription-served)**: PR#1228's 31-min sonnet
      review completed but `/var/run/reviewer-git/GH_TOKEN` was gone at submit — verdict
      unpostable, exit contract failed closed (pod Error, correct), and the (repo, pr, head-sha8)
      pod key then held every re-dispatch for the pod's lifetime (~46 min stall; re-dispatched
      clean at pod death). Not Go-specific — any >~30-min review on any rail. The header damage
      this resight repairs (FU-202's filing ate this item's header line) is unrelated.
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
      **Next (fix-density, no deadline):** move 1's maintenance half (`record` wrapper +
      `--rerecord`), move 4's pins↔FSM bidirectional lint, straggler small families as touched;
      sprout homelab#678 (fold the #668 fixtures into the go-rail-latch table).
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
      **Next:** the exporter sprout-RATE gauge + the depth-aware harvest gate reading it.
      **Operator-deferred:** leg (c) goal-budget decomposition, `issueAuthoring.selfQueue`;
      the goal lane's PHASE-keyed model/checkpoint design (a `GOAL_MODEL` knob turns the wrong
      axis — [`model-routing.md`](agents/model-routing.md) §M10 ⚖, 2026-08-11; design before wiring).
      Relates FU-087, FU-044, FU-111, ADR-094, TICK-LOG §Loop safety.
- [ ] **FU-129** — **`gh issue view <n> --comments` renders EMPTY (exit 0) — ROOT CAUSE CONFIRMED
      2026-08-05: it is gh SEMANTICS, not the image or the token.** `--comments` switches to a
      comments-ONLY view (the body is not printed), so an issue with zero comments — every fresh
      goal issue — yields empty output and exit 0. Proven both ways in the jail: circles#1
      (0 comments) prints nothing, homelab#101 (has comments) prints only comment blocks. Image
      exonerated (agent-base `2026.8.4-g90b229060e57`: `PAGER`/`GH_PAGER` unset, `gh config pager=`
      empty, gh 2.97.0 — and gh never pages a non-TTY). Interim: circles recipes read
      `--json title,body,comments` (96fe003); homelab itself never uses the flag. oracle-fleet
      ported 2026-08-07 (operator, oracle-fleet#173). **Next:** the sleep-tracking recipes —
      the donor for the next `new-stack --from` must already have it. Relates FU-114.

- [ ] **FU-199** — **Silent holds freeze whole lanes invisibly.** Faces: the C4/C5 goal-child
      hold ignoring strike + resumable-branch evidence (oracle#329 ×2, homelab#1149); class
      `held-merged-unlinked` misnamed; footprint-held siblings with no `who=operator` row; the
      PR-cap hold (the 2026-09-01 board freeze); **+2026-09-03: the state-fp debounce** — a
      completed no-op round after an arbitrate re-dispatch (oracle PR#391, 7.5h silent) and a
      capacity-deferred ci-red dispatch (PR#394) both hash identical, so "DEBOUNCED, a human is
      the next mover" is reported and no human is told. **2026-09-04:** the fingerprint faces
      FIXED (#1345 → PR#1352); the CAP SPLIT is complete — updater park-skip (#887 → PR#1375,
      measured 39/41 CI runs on unchanged parks before it) + parks counted BLOCKED|BEHIND
      (PR#1376). **+2026-09-08: the RULED-BUT-NEVER-DISPATCHED face** — both arbitrate sessions
      on PR#1513/#1515 posted their re-dispatch ruling, removed `agent/arbitrate`, then died on an
      Anthropic-side 522 at 13:14Z (`coordinator-homelab-pr-1513` exit 1) before the round-4
      `agent-session.sh` call; the ci-red cap re-labelled both at 13:20Z and the arbitrate
      fingerprint then read "ruled" for 5h (the seat executed both by hand). The ci-red clause
      has the FU-199 (2) re-arm ("no stats newer than the marker ⇒ stale"); the ARBITRATE
      clause has none for a ruling with no round behind it — that re-arm, or the play ordering
      dispatch BEFORE the comment, is the fix. **Next:** honest strike-held rows + hold-chain propagation (the remaining
      board faces); the C4/C5 goal-child limbo with NO strike evidence (oracle#432 today —
      FU-072's dead IP ate the strike post) is FU-204's. Relates FU-187, FU-143, FU-147.

- [ ] **FU-200** — **The brief's fleet-strike rule has no deterministic reader.** "Same
      `error_class=` in `AGENT_STRIKE:` comments on ≥2 distinct issues inside 24h ⇒ ONE
      `AGENT_ERROR` + one filed platform issue" (coordinator README, retro r4 F2) is a prose
      play executed only if one session happens to see both issues — item sessions see one.
      2026-09-01: FOUR goal-#326 r1 strikes with identical `error_class=unknown`
      (oracle-fleet#328/#329×2/#330; three = homelab#1186, one open) were never correlated —
      the operator + seat did it by hand via #330's triage. Prose-warned classes recur,
      executable gates hold (ADR-103). **Next:** a scan-side fleet-window count (the scan
      already greps `AGENT_STRIKE:` per issue for the chain-walk) emitting the breaker +
      filing per the brief's contract; same surface as the #1163 scan theme. Reader BUILT
      (#1235); 2026-09-13 it latched five ISSUES for one PROVIDER fault — re-key to
      provider/model/us = homelab#1640 acceptance 5. Relates FU-199,
      agent-runtime#85 (the `unknown` classifier), model-routing §M1a (strike store).

### Merge path, CI & deploys — reviewer, auto-merge, first-party bumps, the gates

- [ ] **FU-218** — **ARC capacity is RAM placement on the compute tier, not slots.** A runner
      requests ~2.5 Gi → one per 8 GB laptop; only wk-03/wk-metal-01/-02 are `homelab.io/ephemeral`.
      Measured 2026-09-05: queue p90 ~10 min while the cap was hit 0–2 % of the time. **Done
      2026-09-08** (PR#1518 + 09b81dd9): wk-03 8→16Gi/12c (funded by ci-runner-01), `maxRunners`
      4→6 — the overcommit ceiling; the sizing lives in `arc-runners.yaml`'s maxRunners comment.
      **2026-09-14 (operator, PR#1671): wk-03 back to 8Gi/6c, maxRunners 6→4** — the pve host
      sat at 0.5–1 GiB MemAvailable (`PveHostMemoryLow`) and 16 Gi packed ~4 dind onto the 40 G LV.
      Open: (a) label wk-metal-04 ephemeral ≈ +3–4 slots shared with kata (operator call); (b) the
      week's re-read of queue p90 at operator hours (07–09/17–19 UTC) — close if under ~2 min.
      **2026-09-10:** `homelab-ephemeral-large` (#1582: metal-only, 16Gi scratch request, max 1)
      for ≥10 GB-scratch jobs — its template is a COPY of the general one, diff on every change.
      Relates FU-208, ADR-082, `docs/spikes/kata-ci-gate.md` §CI side.
- [ ] **FU-221** — **The updater burns a CI cycle per pass on a PR whose red is RELATIONAL, not
      content.** Its documented pick has no green requirement on purpose (2026-07-10: *"a
      base-side CI fix can only reach a PR through an update"*) — true for a CONTENT red, false
      for a gate whose verdict is a function of (PR diff × base), which a catch-up merge cannot
      move. Measured on PR#1468: **26 catch-up merges, ~26 CI cycles, never green**, on a pool
      already starved (FU-218, queue p90 22–40 min). Cheapest candidate: skip the pick when the
      PR's newest CI failure is the ADR-103 ratchet step (a named, stable step id — the
      fleet-fault rule's own identifier discipline), report-only. #1489 decided 2026-09-08
      (the gate's unit is the PR — ADR-103 addendum): the class shrinks to all-vacuous PRs, so the
      belt stays deferred. **Next:** build only on a second sighting of a PR red on the ratchet
      step through ≥3 catch-up merges. Relates merge-path.md MP-T02, ADR-111.

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

- [ ] **FU-219** — **`coordinate-perstack-*` runs die with exit 141 (SIGPIPE), intermittently.**
      8 runs on 2026-09-05/06 (platform-agents ×6, oracle-agents ×2), ~60 s in, last Loki line
      the doorbell-collapse absorbs or the `coordinate(perstack): stack=…` banner; sibling runs
      of the same template succeed. A pipeline writer killed by an early-exiting reader under
      `set -o pipefail` in the scan preamble — the three `| grep -q` sites feed small variables,
      so the site was not named — **named 2026-09-09 by responder #1547: the `coordinator-scan.sh:1495`
      parity-assertion `| head -1` (PR#1576, parked `blocked-on: human`, needs the ADR-103 replay pin).** Surfaced by the switchboard OOM read,
      [`incidents/2026-09-06-switchboard-oom-silent-failures.md`](incidents/2026-09-06-switchboard-oom-silent-failures.md).
      **Next:** on the next 141, pull the run's Loki tail with `container="main"` and bisect the
      preamble between the last printed line and the first GitHub listing; fix = `>/dev/null`
      over `-q` (the reader drains) or `|| true` on the writer.

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
- [ ] **FU-154** — **Closing a PR and opening a new one RESETS the anti-livelock bound.**
      `RED_ROUNDS_MAX=3` counts `Agent run stats` comments **per PR**; circles#19 consumed five
      rounds across PR#50 (2) + fresh #51 (1) after earlier rounds elsewhere. Same class as
      FU-148 — PR identity is the unit of state and re-creating the PR silently resets it — but a
      different actor (worker re-PR, not coordinator close/reopen) and a different reset (rounds,
      not auto-merge arming). Flagged by the circles jail 2026-08-07 (TICK-LOG note, then unfiled).
      **Load-bearing since 2026-08-08**: close-and-re-PR became a DESIGNED play (#210→#221, #214
      re-queue, #209→#218-v2). **Next:** homelab#156 (queued) builds the issue-keyed count —
      status follows that issue; FU-148's re-run lever landed the same day (App actions:write).
- [ ] **FU-148** — **Environmental CI red: the retry terminal, awaiting its first organic
      pass.** Close/reopen (which silently DISARMS auto-merge, FU-079 class) is RETIRED from
      the ci-red play; the coordinator App holds `actions: write` (operator grant 2026-08-08,
      coordinator-git generator only — workers keep no Actions verb) and the play retries ONCE
      with a stated diagnosis (second red ≠ environmental). Permission chain proven live
      ~17:55Z 2026-08-08 (201 on a real rerun-failed-jobs). Founding incidents: circles#44 +
      three on 2026-08-08 (oracle#217/#218, circles#69). **Next:** acceptance = the first
      ORGANIC environmental red self-retries through the play (diagnosis comment + one rerun)
      → then archive. Relates ADR-094, FU-079.
- [ ] **FU-151** — **First-party `-iac` deploy bumps skip LLM review by TIMING, not design.**
      `review-reflex.sh` skips `automerge`-labelled PRs, but app repos open `deploy:` PRs
      UNLABELLED — they survive only because auto-merge beats the 15-min tick; a slow CI
      reverses it (cost already paid: 5 reviewer sessions on 4 one-line pins,
      homelab#102/#104/#105). Fixed where it burned (openrouter-operator#23,
      agent-coordinator#10, oracle-fleet#173); labels exist on all -iac repos; sleep-tracking
      DONE 2026-08-11 (`5b8c384`, meta-delivered beside goal #278). **Next:** circles at unpark;
      snore-recorder rides its #15 (the deploy-pin is BORN there — label at birth).
      Relates [`dependency-upgrades.md`](dependency-upgrades.md) §2.
- [ ] **FU-152** — **One version file for the agent-coordinator image: the kustomize conversion
      SHIPPED** (landed with #113's arc, verified 2026-08-11: `agents/coordinator/kustomization.yaml`
      `images:` transformer holds the tag, ZERO literal tags left in the coordinator manifests,
      the single CODEOWNERS carve-out is in place). **Remaining residue:** the composition
      (`argocd/resources/agentstack/composition.yaml`, 2 sites) still carries the literal — a
      different app that kustomize cannot reach, so each coordinator bump sweeps one OWNED file
      and parks on a codeowner click. Needs a small design (feed the composition the tag) before
      building — NOT an FU-165 goal child for that reason. **Next:** design the composition-side
      feed, or accept the one-click cost and archive.
- [ ] **FU-153** — **in-pod CI and in-CI CI disagree under kind, and no lever says which is right.**
      circles#19 r2 reported `ci_passed: true` from the ride; Actions failed the SAME gate twice
      (`HTTP 000000`, 4 assertions). Not a missing capability — the claim carries
      `repos[circles].fixer.docker: true` (flipped FOR #19) and the pod really is kata +
      native-sidecar `dind` + `DOCKER_HOST`, so the worker CAN run kind. The two environments simply
      differ (kata microVM dind vs the ARC runner). On a red the coordinator can neither re-run the
      job (FU-148, no `actions:write`) nor re-run CI in-pod, so it parks at `agent/blocked` and
      waits for a human — for a class of red that should be retried. **Operator direction
      2026-08-07:** give each stack coordinator both levers, and make the lever REVEAL which
      environment is telling the truth. Relates FU-148, FU-072 (kata networking), ADR-097.
- [ ] **FU-150** — **"CI cannot dispatch" alerting: POINTER.** Analysis + both halves' history:
      [`docs/incidents/2026-08-07-arc-listener-wedge.md`](incidents/2026-08-07-arc-listener-wedge.md);
      `GithubVendorOutage` (vendor half) + `CiDispatchStalled` queued-age alert (OURS half,
      goal #278 child #284, promtool-fixtured against both incidents) are live.
      **Next:** archive after `CiDispatchStalled` survives its first real firing or a quiet month
      (shipped 2026-08-11 — window opens ~2026-09-11).

- [ ] **FU-046** — **Prove the reviewable-dep-bump path E2E on a real major bump.** The split is
      decided and built — `automerge` = mechanical CI-only approval, `deps-review`/major = the LLM
      review path ([`docs/agents/merge-path.md`](agents/merge-path.md) §Decisions;
      [`docs/renovate.md`](renovate.md) §"Coordinator × Renovate PRs"); reflex skips `automerge`,
      `rebaseWhen: conflicted` set. **Unproven, awaiting a real reviewable bump:** an armed `deps-review` PR through
      the **review reflex** (not the coordinator) → CHANGES_REQUESTED → a worker adapting on the
      **`renovate/*` branch** → loop → merge. Verify specifically that **Renovate leaves a
      manually-edited branch alone** and the worker pushes to `renovate/*`, not a new `agent/*`.
      Keep open until one flies. **P3 (later):** a longer cooldown on majors so a human CAN opt into
      an interactive session for the riskiest. Relates FU-041, FU-044, FU-014.
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
- [ ] **FU-044** — **Roll-FORWARD on a broken deploy — the remaining LLM half.** Deterministic
      rollback shipped 2026-07-27 (argocd-notifications → `/deploy-degraded` → `deploy-revert`,
      no LLM); what's left is dispatching a worker against the APP repo, in-cluster off ArgoCD
      health events (never in the Actions deploy run). Deep acceptance stays the FU-102 prober;
      operator prereq: harden app CI so breakages are rare. **⚖ IAC-G09 platform half WIRED
      2026-08-04** (homelab reversible class = first-party image pins only; pin-only predicate in
      `deploy-revert-argo.yaml`, unit-exercised, **never fired by a real Degraded homelab app**).
      Design + rulings: [`docs/agents/iac-lane.md`](agents/iac-lane.md) §"ArgoCD health is NOT the
      post-deploy gate" + §"Auto-revert does NOT generalize". Relates FU-041, FU-102, FU-090.

### Models, cost & routing

- [ ] **FU-251** — **opencode.ai: headers fixed and PROVED on the wire; the knob is an operator
      flip.** The proxy forwards the harness's own UA + session header (PR#1760). Measured
      2026-09-17 against the live vendor: a claude-shaped ride 200s with
      `+oc-session[native]:<uuid>`; affinity follows the id (same id → `cache_read 2176`, a fresh
      id on the same prefix → cold); either `x-opencode-session` or claude's native header works
      alone; with NO session header the rail hard-fails `400 MissingSessionID` (3/3), so the
      pre-fix allowlist would be failing today. Premise corrected: FU-213's value was never
      rejected, only coarse. The "rides reached opencode.ai while parked" seam is closed — the
      knob was `"0"` then (operator). **Flipped back to `"0"` the same evening** (2026-09-17
      18:35Z, `c5138ed0`; live-verified on the pod) — the 7d subscription window sat at 0.95 and the
      reviewer's Go failover was the only path a review could land on. **Next:** the three seams the
      fix left standing — the proxy's UA substitution is narrower than the vendor's rule 2 (a caller
      whose UA is a generic library name rides through as-is), a claude-code older than v2.1.86
      sends the session id only in `metadata.user_id` (no body parse), and a client that identifies
      nothing still buckets coarsely on the credential ref. Detail:
      [`chainless-redesign.md`](agents/chainless-redesign.md) §Proved on the wire.

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
      partition): [`model-routing.md`](agents/model-routing.md) §M7. Legs 1–2 shipped 2026-08-11
      (#282); legs 3–4 + the filing gate (operator, 2026-08-17: an all-unbenched, uncanaried
      digest posts nowhere but the log) shipped via #469→PR#499 + #506's whole-set common-cause
      rule. ⚠ Written-not-proven: no organic scout fire since the merge; every 08-10..08-17
      canary died `nonzero-exit-1` at $0 (runner fault, verdicts void). **Next:** first-fire
      proof, Go cells (post Sep-13), rung-2/FU-095(c), pool depth, void the tainted rotation
      rows — owned by G-A child homelab#778. Related: #235's belt (machine lane owns it).

- [ ] **FU-186** — **Provider selection priced per successful job (ADR-115): POINTER.** Design +
      evidence + 4-step build order: [`docs/agents/model-routing.md`](agents/model-routing.md)
      §M14 (Exacto delegated for cheap coding; pin-v2 with the overhead-cost term for priced
      classes; the scout rides its class's provider policy; `@` arms = the experiment
      instrument, shipped PR#963). **Step 1 FLIPPED 2026-09-13 (PR#1639; operator: the five
      open-inference tool-loops ARE the trial) — the suffix rides paid OpenRouter picks only.
      Next:** the standing re-read = homelab#1640 acceptance 8; the 0731 matrix run (step 2,
      #1238) stays #1231's leg. Relates ADR-115, ADR-096 §M4/M8, FU-095, homelab#966 (intake digest),
      the #783 provider-attribution legs.

- [ ] **FU-095** — **Task-class model routing + multi-harness evidence: POINTER.** Design,
      pilots, the strike/§M10 rulings: [`docs/agents/model-routing.md`](agents/model-routing.md)
      + ADR-096/ADR-112. Legs (b)+(c) ride G-A child #778 (the scout's 3-harness cells ARE the
      (b) surface). Flip evidence COMPLETE (2026-08-25, #775 — the 123 deferred rows are
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
- [ ] **FU-270** — **`agent-gateway`: the proxy as its own image-producing repo (ADR-139 step 3).**
      LLM rails + the ADR-096 router, renamed by role; pinned-image deploy (FU-044 revert class);
      `model-classes.json` stays homelab config, mounted; a compat Service keeps
      `openrouter-proxy.agent-egress` resolving (160 refs in 52 homelab files). Stays single-replica
      on SQLite. **Blocked on** FU-127 (one `model_id.py` home) and FU-269. **Next:** scaffold the
      repo (agent-runtime shape) + image CI; move code with history. Glossary: pending renames.
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
- [ ] **FU-131** — **Cost-ledger undercount: harvest FIXED, the T+1 sweep is what remains.** The
      `/generation` backoff was (2s, 5s) and gave up at ~7s, losing 49% of a fan-out arm's spend
      ($2.196 of $4.328 stored, the stored 29 matching OpenRouter's export to the cent). Now
      2/5/15/45s, and both outcomes are counters — `openrouter_generation_harvest_total{outcome=
      "stored"|"missed"}` on the proxy's `/metrics` — so the blind spot is a series instead of a
      hand-diffed export. **Next:** the T+1 sweep over `GET /activity?api_key_hash=` for whatever
      still misses (per-session keys make attribution exact; needs a management key), and the
      round-2 no-`/report` hole. Relates ADR-096, FU-095.
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

- [ ] **FU-198** — **No belt sees an Argo lock-plane wedge: POINTER.** Three instances: the sync
      manager's in-memory state corrupted under a failure storm (2026-08-31, "5/5" against an empty
      semaphore); a BENIGN twin with the same signature (2026-09-12, latched `respond-*` holding
      their lock across retry backoff); a Running holder with an Errored pod + phantom slots
      (2026-09-15/16, 137 queued, no responder run in 24 h). **Belt SHIPPED 2026-09-16 (PR#1722):
      `ArgoLockPlaneWedged`** — Pending ≥10 while the pool has free slots and no rail is latched;
      replayed: fires 27 h before the operator's read, quiet on the latch day. Postmortem + all
      three: [`incidents/2026-08-31-argo-semaphore-leak.md`](incidents/2026-08-31-argo-semaphore-leak.md).
      **Next:** check upstream sync-manager fixes (`v4.0.7`) before any bump. Relates FU-187, FU-088.

- [ ] **FU-228** — **`agent-transcripts` has no retention — 5Gi → 20Gi bought time, not a policy.**
      The bucket sat at 98 % (5.3 GB, 26.7k objects, ~1 GB/week of ride exhaust) the hour
      `GarageBucketQuotaNear` first ran (2026-09-10, #1577); the 2026-08-03 claim was "11× actual".
      A refused put is a lost transcript — the writer key is put-only, nothing retries — and the
      transcripts feed the retro (observability-and-retro.md §A1/B) and doc-heat (FU-164). Cap raised
      to 20Gi (#1579) ≈ 4 months at today's rate. **Next:** decide what to keep (per-issue tail? the
      retro's window? everything, and a bigger claim?) and implement it as an S3 lifecycle rule or a
      sync-job sweep — the design question belongs to `docs/agents/observability-and-retro.md`.
      Sibling: `allure-reports` at 89 % of 10Gi is oracle-iac's (their alert, their retention).
- [ ] **FU-210** — **Responder transcripts: POINTER.** A triage that filed nothing used to leave
      nothing — the 2026-09-03 forgejo-pg-1 session marked the subject triaged, filed no issue, and
      the probe lane deferred to it as COVERED while the alert stood 8 h. The lane was the one role
      outside §A1. Mechanism, layout and the write-only-key ceiling:
      [`agents/observability-and-retro.md`](agents/observability-and-retro.md) §A1 (responder row +
      hook point); gate = `responder-behaviour-test.sh` §FU-210. Shipped PR#1749.
      **Next — the acceptance, which cannot run while the lane is paused:** at FU-249's un-pause,
      read one prefix end-to-end and confirm a report-only session that files no issue still leaves
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

- [ ] **FU-188** — **Reviewer 404-loop / the combination table — POINTER.** Postmortem + belt
      audit + the operator's yaml-in-git ruling:
      [`incidents/2026-08-26-reviewer-404-loop.md`](incidents/2026-08-26-reviewer-404-loop.md).
      Build = the declared role×harness×rail×model table in git (rows are DATED status claims,
      `works | not-yet | disabled(reason→link)` — strike-out-to-disable replaces bash literals);
      router filters on it + the request's capability vector; launcher derives from it. Legs:
      (a) rideable-rails adoption (b) router refusal + empty-rail skip row (c) reviewer
      api_error → `/report` ⇒ strike (d) zero-output belt — **its `argo_workflows_*` failure
      half SHIPPED 2026-09-06** (`ArgoWorkflowsFailing`, fleet-wide Failed/Error counter >40/6h;
      [`incidents/2026-09-06-switchboard-oom-silent-failures.md`](incidents/2026-09-06-switchboard-oom-silent-failures.md),
      the belt's third silent instance); the verdict-throughput half stays open. **Pin LIVE**
      (reviewer authoritative→shadow, grep FU-188); out with (a)+(b). Absorbs PR#991's literal +
      the AVX2 pin as rows at build. Next: schema design pass, then issue tree.

- [ ] **FU-164** — **doc-heat: transcript-derived read heat over repo markdown — POINTER.**
      Question, heat doctrine (heat × class × age; blind spots; approximate lines), v0 (jail
      parser + static report, `devbox run doc-heat`) and the serving plan:
      [`docs/spikes/doc-heat.md`](spikes/doc-heat.md). **PROMOTED 2026-08-30** (operator —
      settle bar met by run 1): standing docs-cleanup input, wired into the skill's comb step.
      **Post-S5 heat read DONE 2026-09-05** (settle-test run 2 in the spike: windowed to the
      37 transcripts since 08-31, 72 % of corpus lines never targeted; the corpus load itself
      measured 300–350k tokens) → the trims are S5's fifth original, homelab#1393.
      **Next: the v1 cluster leg** (`s3://agent-transcripts`, path normalization,
      jail/cluster separate + combined views — operator requirement), which also delivers
      context-repos.md's overdue measurement sweep. Relates FU-058.

- [ ] **FU-058** — **Retro P3: POINTER.** The 08-24 fire FAILED (529 storm + #861, fixed
      PR#864); **the re-fire DELIVERED 2026-08-25** — platform r1 landed (PR#918), its batch
      filed as #927–#931 (3 queued, #930 seat, #931 operator), plus the silent success-push
      belt defect #932 (queued; fact hand-recorded). Design + history:
      [`docs/agents/observability-and-retro.md`](agents/observability-and-retro.md) §B2.
      **Next:** the Mon 2026-08-31 05:00 UTC cron = the clean unattended acceptance (full
      report per cell — r1 was one — no false RetroReportOverdue, #932 landed); then **STACK
      retros FIRST (priority flipped, operator 2026-09-01** — stack goals carry the deeper
      business-logic + kind-e2e complexity and a different dynamic; §B2 The split): the first
      `retro.enabled` graduation + non-overlap brief; ledger emitter gaps + MCP transcript
      slices behind it.
      Absorbs FU-057's residue. Relates FU-095, ADR-103 (rule 3).

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
      prober (scheduled leg built 2026-08-07, report-only by construction). **First enablement
      = PLATFORM** (G-B child #835 → PR#850 into `goal/818-assurance`: platform probe brief +
      claim `prober` block) — NOT live yet: it lands with G-B's assembly merge, wedged on the
      #933 checkpoint-bucket defect. **Next:** after the G-B assembly, read `probe-platform`'s
      first tick; oracle's probe.md stays #289 (parked with the stack); then the
      sync-succeeded edge + 🌱 issue filing. Composes with FU-044.

- [ ] **FU-230** — **The responder cannot see seat-driven change: POINTER.** 7 of 9
      confidently-wrong writes in the 09-04→11 week had a cause the seat made outside the cluster's
      view. Leg (a) (node/instance/pod-scoped Alertmanager silences) shipped PR#1601; **leg (b)
      shipped PR#1750** after its own trigger fired twice on 2026-09-16 — a seat-written
      **declared window** ([`glossary.md`](glossary.md)) naming the alert CLASSES a planned window
      produces, for the ones carrying no `node`/`instance`/pod label at all — a ConfigMap, so the
      FU-195 durability caveat is retired. Mechanism: [`agents/roles.md`](agents/roles.md)
      §responder; evidence: [`spikes/responder-week-audit.md`](spikes/responder-week-audit.md).
      **Next:** at FU-249's un-pause, run one real `node-maintenance` window and confirm the
      DaemonSet-rollout class costs no triage session.
- [ ] **FU-231** — **Findings to the bucket, issues only for actionable verdicts: POINTER**
      (operator direction 2026-09-11). Producer half shipped PR#1749 — a typed
      `finding.json` (`responder-finding/v1`) beside every transcript, the no-issue triage
      included. ⚠ **The SWITCH stays OFF and cannot be flipped as sketched:** report-only issues
      are DECIDED-ONCE's anchor (#1733), and moving that anchor into the bucket needs a pod read
      the write-only transcripts key will never grant. **Next, two independent legs:** (a) the
      CONSUMER — a `triage` source in `meta-events.sh` over new `homelab/alert-*/` prefixes, using
      the jail-side READER key; (b) re-read the switch after FU-249's un-pause, against an anchor
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
      **Next:** the G06 advisory lens; watch the flip soak (deploy-bump latency +≤ one */5
      tick; first real RED status). Relates FU-087/FU-093, FU-176, ADR-084, ADR-076.
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
- [ ] **FU-134** — **Web research is now a platform capability — soak, then close.** `POST /search`
      on the egress proxy (an ordinary completion carrying OpenRouter's `openrouter:web_search`
      server tool) returns `{answer, citations[]}` to ANY harness, riding the caller's own key ref
      so budget/guardrail/ledger/attribution keep working with no new credential and no new egress
      hole; ~$0.005 + tokens per call, refused for anthropic-tier refs (they have WebSearch
      in-harness). The env card states a guarantee per harness and passes `AGENT_SEARCH_URL`.
      Verified live 2026-08-05 from a ride-shaped pod in ns circles: 10 citations for a
      today's-web question. **Next:** watch a real goose ride actually use it (recipes may still
      carry "no web" folklore — FU-117 class), then archive. Detail:
      [`docs/agents/roles.md`](agents/roles.md) §Context delivery. Relates FU-117, FU-095, FU-020.
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

- [ ] **FU-093** — **Storage-tier ledger + metering: POINTER.** The rule, history (Longhorn
      metering 2026-08-04, the ADR-089 quota arming 2026-08-07, the 08-24 third-100% incident, the
      09-03 fourth) and status detail: [`docs/storage-ledger.md`](storage-ledger.md). Garage
      metrics SHIPPED (#934 → #965); pve fstrim SCHEDULED (PR#925); **pve thin-pool meter BUILT
      2026-09-04 (PR#1367)** — node_exporter textfile on the hypervisor, `PveThinPool*` /
      `PveVmIoError` belts, ci-runner-01's own `fstrim.timer` VERIFIED enabled+active on the
      recreated guest; pool **71 %** after it, the 80 % warning close. **Next:** (a) a Longhorn
      `filesystem-trim` RecurringJob (node fstrim cannot reclaim inside replica sparse files);
      (b) **metal-node fstrim** (2026-09-06) — `node-fstrim` is pve-VM-only by design, and wk-metal-04's
      never-trimmed SA400 writes 26 MB/s at 486 ms (ledger §2026-09-05). Since 2026-09-09 the SA400
      is `slow-bulk` + unschedulable and holds NO Longhorn replica (garage-0 rotated onto the 7600p,
      ledger §The rf=3 build-out as run), so the trim is for the image store only — one-off, then
      weekly `nodeName` blocks if it helps. Relates ADR-089, ADR-114, homelab#934.
- [ ] **FU-211** — **The storage ledger's numbers are hand-typed — generate them, machines.yaml-style.**
      PR#1368 took three bot rounds on transposed/stale figures (408 vs 488 GB promised, 353 vs
      354 GB pool) in the one cell a human reads for the buy-a-disk call; the "Current shape" table
      is a dated snapshot (2026-08-25) nobody refreshes. The truth is LIVE, not a YAML: Longhorn
      node/disk status (raw, allocatable, scheduled, used per tier), the pve meter
      (`pve_lvm_thin_lv_size_bytes` Σ = promised, pool size/data%), ResourceQuotas (scratch caps),
      Garage Workspaces (bucket caps — `scripts/storage-ledger-check.sh` already sums these).
      **Next:** extend that script with a `--render` that rewrites marker-delimited blocks in
      `docs/storage-ledger.md` (tier table, pool line, quota table, the requirements rows' "today"
      figures) stamped with the read date, per `machines/generate.py`; judgments stay prose.
      Relates FU-093, FU-177 (same class: one source, generated blocks).
      **SLO/dashboard leg (2026-09-09):** no Garage dashboard or SLO existed anywhere; queued for
      the loop as homelab#1559 (recording rules + dashboard) and #1560 (client-perspective write probe).

- [ ] **FU-212** — **Responder workflows Error on an RBAC gap and the alert gets no triage at all.**
      Four `respond-*` workflows on 2026-09-04 (08:18, 08:32, 08:37, 08:42 — all `PodSigkilled`,
      while other runs of the SAME alert succeeded, so it is intermittent, not per-class) died with
      `error in entry template execution: configmaps is forbidden: User
      system:serviceaccount:argo:argo-workflows-workflow-controller cannot create resource
      "configmaps" ... in the namespace "agent-coordinator"`. The Role bound to that SA there
      (`argo-workflows-workflow`) grants only `argoproj.io/workflowtaskresults: create,patch` — and
      every stack namespace's Composition-rendered Role (ADR-096 §RBAC) is identical, so this hits
      the whole fleet, not just the coordinator ns. Controller is v4.0.7; what it wants a ConfigMap
      *for* is not established (memoization cache and sync-lock state are the candidates — the
      responder declares a `synchronization.semaphores` configMapKeyRef). An Errored responder is
      silent: no ledger entry, no issue, no notification. **Next:** reproduce against v4.0.7 to name
      the write, then add it to the rendered Role (Composition + the coordinator's own manifest);
      until then `ArgoWorkflowsFailing` (2026-09-06, fleet Failed/Error >40/6h) shows a BURST, not
      four scattered Errors — a per-template belt still wants the RBAC fix. Relates FU-210.

- [ ] **FU-049** — **Platform services published as XRDs supersede `SERVICES.md` as the source of truth.**
      Provisionable capabilities (S3/Postgres/…) become typed Crossplane XRDs; discovery is a cluster query
      (`kubectl get xrd`) and the human catalog is *generated* from them rather than hand-curated. Open:
      build-time discovery for an app repo with no cluster creds may still want a generated static catalog.
      **Inherited from FU-107 (2026-07-27), same generation class:** agentstack.md's "what a claim
      renders" table generated from the XRD/Composition, and the stacks-state table from
      `kubectl get agentstacks` (plus `agents/stacks.json` itself — the original mirror problem).
      Design: [`docs/agents/platform-and-stacks.md`](agents/platform-and-stacks.md) §2, ADR-085. Relates
      [[service-discovery]], ADR-076 (app-owned resources via Crossplane).

- [ ] **FU-227** — **Two silent-failure shapes the workflow belts cannot see (the 2026-09-08 read).**
      (a) a template failing 100 % of its runs stays under `ArgoWorkflowsFailing`'s fleet-wide
      40/6h line — the updater was red on every repo for 65 h at ~4–6 failures per 6 h; (b) a
      responder triage session that dies at launch lives inside a **Succeeded** workflow
      (`claude … || echo WARN`), counts as a spawn in the budget ledger, and is indistinguishable
      from a ride that investigated — 156 dead sessions in 7 days, "8/12 spawned today".
      Postmortem: [`incidents/2026-09-05-updater-node-cap-responder-dead-triage.md`](incidents/2026-09-05-updater-node-cap-responder-dead-triage.md);
      the belt home is FU-188 (d). **Next:** (b) first — push `responder_triage_sessions_failed`
      beside the budget gauges in `responder-budget.sh`'s pushgateway shape and alert on
      failed ≥ 3 in 24 h; (a) PARTIAL 2026-09-08 — `AgentLoopWorkflowsFailing` (PR#1515, the
      #1456 belt) fires per loop NAMESPACE at ≥3 Failed/Error in 1h (would have named the
      updater outage on its first hour); the per-TEMPLATE source (`argo_workflows_total_count`
      has no template label — a kube-state-metrics-style read of Workflow CRs or the exporter)
      stays the residue.
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
- [ ] **FU-258** — **Cilium drops the `kubernetes` Service backend on an apiserver restart and does
      not re-sync — POINTER.** Reproduced twice 2026-09-20: pods get `connection refused` to
      `10.96.0.1:443` while the API is healthy and every node reads `Ready`; recovery is
      `rollout restart ds/cilium`. Evidence, the survivor anomaly, prior art and the settling
      experiment: [`docs/spikes/cilium-apiserver-restart-backend-loss.md`](spikes/cilium-apiserver-restart-backend-loss.md).
      **PARKED (operator, 2026-09-20)** behind the **1.20.2** upgrade — 1.19.1 is a version we
      should not run and reproducing costs an outage. Near-term guard DONE: `cp-upgrade` gates the
      backend either side of the reboot (rolls `ds/cilium` only on a genuinely missing one, reading
      shared as `devbox run maint cilium-check`); ⚠ every OTHER apiserver restart is still
      unguarded — run it by hand. **Next:** the spike waits on Renovate/1.20.2. Relates FU-246, FU-253.
- [ ] **FU-260** — **The Argo Workflows controller hot-loops and floods Loki when the apiserver
      goes away (2026-09-20).** v4.0.7's `configmap_watcher` never re-establishes a closed watch:
      it logs `invalid config map object received in config watcher` forever — 1.43M lines / 220 MB
      in 2s (~110 MB/s at the pod, 1141m CPU), 96% of all Loki ingest. No self-recovery;
      `kubectl -n argo rollout restart deploy/argo-workflows-workflow-controller` fixed it.
      Workflows kept reconciling, so the damage is log volume + a burnt core. **Trigger CONFIRMED:
      an apiserver restart** — this session's cp-01 applies (09:33/09:38/09:49/12:06/12:42; the live
      container's `startedAt` is 12:42:48Z). Same trigger as FU-258, different victim. **Next:**
      check upstream for a fix and bump the chart; decide whether a FAST strap belongs beside
      `LokiNamespaceLogVolumeHigh` (~50 min to fire: `for: 30m` on a 30m rate window). Relates FU-258.

## Hardware & nodes

- [ ] **FU-261** — **The BIOS PXE chainload was silently broken, and the role that serves it has
      been failing for months.** `/srv/tftp/undionly.kpxe` was MISSING on the Matchbox LXC (only the
      two UEFI binaries there), so a legacy PXE client got a filename it could not fetch and fell back
      to disk — three reboots of `wk-metal-02` read as "PXE just doesn't take" (2026-09-20). Why nobody
      saw it: `ansible/matchbox-ipxe-tftp.yml` ends with *Enable tftpd-hpa*, which `matchbox-proxydhcp`
      MASKS (dnsmasq owns :69), so every run fails at the last task and the copy before it went
      unverified. Re-running restored the file (74 KB, TFTP-served). **Next:** guard/drop the
      tftpd-hpa tasks (the role header already says dnsmasq owns TFTP) + probe that all three boot
      files are served — onboarding depends on it, nothing tests it. Relates FU-244.


- [ ] **FU-032** — Watch: **wk-metal-02's flaky wired link** (the thinkcentre half of this item
      is moot since 2026-09-12 — that box left the cluster). **2026-08-07 (homelab#117):
      wk-metal-02 had a 4.5h NIC flap storm** (`carrier_changes` 2→3778, no reboot, flat plug
      power) — the thinkcentre bad-cable class, NOT battery/power. **Next (operator, physical):**
      reseat/replace wk-metal-02's cable / switch port; evidence + counters on homelab#117.
- [ ] **FU-155** — **PSI-stall shared-fate kills RECUR on hardened nodes: POINTER.** Mechanism,
      evidence (the broken cadence premise, the 2026-08-17 victim-surface shrink, the 08-24
      service-tier recurrence + pre-upgrade `oomactions` capture, cilium-agent's residual
      exposure) and the ⚖ recommendation: [`docs/spikes/talos-psi-thresholds.md`](spikes/talos-psi-thresholds.md)
      §7 Evidence updates (#157/PR#160; symptom thread homelab#857 — recurred again 08-25
      during the hp-01 maintenance window). Scope REOPENED 2026-08-24: Option A's v1.13.8 pin
      now reads ALL metal nodes (nocloud VMs stay excluded). **Next:** operator rules
      tune-vs-accept (the pin experiment first; cilium-agent's residual pod-level exposure —
      container req=limits since 07-28, pod still Burstable — folds into the same ruling). **2026-09-16:
      the Option A pin gained a second, harder driver — FU-246** (the `page_table_check` reboots). Relates FU-139/FU-112, ADR-044.
- [ ] **FU-246** — **Talos ≥ v1.13.10 on the workers — the `page_table_check` reboot bug: POINTER.**
      Cause + evidence: [`docs/incidents/2026-09-16-page-table-check-reboots.md`](incidents/2026-09-16-page-table-check-reboots.md)
      (siderolabs/talos#13496; v1.13.4+ builds the kernel unenforced). **Done 2026-09-16:** nx-01 +
      wk-metal-02 `talosctl upgrade`d; PR#1740 (version by role, CP v1.13.2 / workers v1.13.10) merged;
      **all four VM workers on v1.13.10 by 18:50Z** — wk-03 by design, wk-01/02/04 by the FU-248
      incident (recovered as the upgrade, no data lost). Verified on every node: `CONFIG_PAGE_TABLE_CHECK_ENFORCED`
      unset, kata intact where declared. **2026-09-21:** cp-01/cp-02 + wk-metal-04 (FU-265) on v1.13.10;
      m70s + hp-01 wait on #1839 (drain before install). **Next:** the 7 metal config updates (in place) + the remaining
      metal workers via `talosctl upgrade` at convenience; Matchbox PXE assets to v1.13.10 before the next
      metal reinstall; then a week's soak of `NodeRebootingRepeatedly` → archive. Subsumes FU-155 Option A; FU-033 gates 1.14.
- [ ] **FU-254** — **Nothing detects that our substrate is behind, or out of support.** Talos 1.13
      left community support at the 1.14.0 release (2026-09-03) and the fleet learned it from a
      conversation, not a mechanism. Renovate cannot fill this: class 6 is deliberately "must not"
      auto-deploy and Renovate opens no homelab PRs at all — `dependency-upgrades.md` §Monitoring
      already records the sibling hole ("Renovate liveness ❌"). **Next:** a check comparing
      `var.talos_version_{controlplane,worker}` / `var.kubernetes_version` / `var.cilium_version`
      against the upstream support matrix, firing on "a newer minor exists" and on "ours is EOL" —
      a natural belt job for the management box once §MB2's metric transport is decided (FU-252).
      Relates FU-033, FU-097, ROADMAP G-D.
- [ ] **FU-250** — **The apex consumer claim's Workspace is permanently red: RUM is undeliverable
      and it wedges every reconcile report.** `pr-oracle-fleet-minutark` fails with
      `POST …/rum/site_info → 403 "Authentication error"` from Cloudflare (the cf-api-proxy
      allowlist passes it; the ingress-write token has no RUM write group — there is none to
      grant, the #1311 residual). Terraform is not transactional, so the claim's other resources
      DO apply — but `Synced=False` is then permanent, which is how a state lock stale since
      2026-09-09 sat unnoticed for a week underneath it (cleared 2026-09-17, FU-206's sitting).
      A red that is always red detects nothing. **Next:** decide the consumer profile's RUM leg —
      drop `cloudflare_web_analytics_site`/`_rule` from the composition (it has never once
      applied), or gate it on a claim field that defaults off; either way the consumer Workspace
      must be able to go green. Link: [`docs/cloudflare.md`](cloudflare.md) §PublicRoute
      completion table (RUM row, #1311).

- [ ] **FU-249** — **Responder PAUSED 2026-09-16 (operator: "still doing only noise") — re-enable ≈2026-09-23.**
      The `responder` Sensor's `alert-dep` carries a never-matching data filter
      (`agents/coordinator/responder-argo.yaml`); WorkflowTemplate, Role and seen-cache untouched.
      Alerts still fire in Alertmanager/Grafana — only the issue-filing stops. **Next:** after the
      FU-230/FU-231 soak of PR#1733's four legs, delete the filter (one revert) and watch
      `responder_triage_sessions_today` for a day. Relates FU-230, FU-231, ADR-122.
- [ ] **FU-247** — **Alert on a captured kernel oops.** The `page_table_check` oops sat in Loki
      (`{namespace="loki",container="kmsg-reader"} |~ "kernel BUG at|Oops:"`, node-labelled) from
      2026-09-10 09:38 and nothing read it for six days. Loki has no ruler today (`loki-config.yaml`);
      **Next:** ruler + one `KernelOopsCaptured` rule per node, or an Alloy-side counter metric the
      existing Prometheus rules can fire on. Also the console half: nx-01's BMC SOL is `ttyS1` and the
      v1.13.10 metal image ships `console=tty0` only — a metal panic capture needs `console=ttyS1,115200`
      in the image-factory `extraKernelArgs` (install-time). Incident above; relates FU-155 (kmsg tenancy).
- [ ] **FU-234** — **The `fast` (Optane) tier has no backing disk since 2026-09-12.** Both Intel
      Optane M10 16G cards left with `thinkcentre` when it retired from cluster duty, so a
      `longhorn-fast` PVC stays Pending — safe only because the tier had ZERO consumers
      (FU-159's scratch-only ruling). The StorageClass stays declared: deleting it would orphan
      the AgentStack XRD's `fast` quota key. **Next (operator, physical):** fit both cards in
      wk-metal-04's free chipset root ports (`00:1c.0`/`00:1c.1`), add the `longhorn_disks` rows
      to its `machines/machines.yaml` entry + apply, then
      `bash scripts/longhorn-register-optane.sh wk-metal-04`. Intent = ride/ARC scratch, off the
      shared image-store partition. ⚠ The x1 AIC form factor is off the market — do not discard.
      Detail: [`docs/storage-ledger.md`](storage-ledger.md) §thinkcentre leaves the std tier.
- [ ] **FU-235** — **Declared node state vs live: the metal nodes drift, and tofu cannot see it.** (1) `kata:
      true` on four laptops, live only -01/-02 carry `homelab.io/kata` (2026-09-12) — kata pool 2, not 4.
      (2) `kubernetes_node_taint.ephemeral` cannot own `.spec.taints` on a node cilium-operator untainted
      (nx-01; `force` tried + reverted — atomic list; own `field_manager` since d4b350f3). (3) **install-time
      drift** (2026-09-16, nx-01): config applied in place, tofu plans clean, yet the node runs the plain
      schematic and EPHEMERAL on the SATA disk — the install half never can. (4) **ABSENT is the extreme
      case**: wk-metal-02 declared, no Node object for ~12 h, nothing fired (2026-09-21, FU-243).
      **Diff LANDED 2026-09-21** (#1828/#1831): box `check_nodes` + `TalosFleetVersionSplit`.
      **Axes + transport LANDED 2026-09-21** (#1859/#1861): `mgmt_node_drift{node,axis}` over
      reachable/version/schematic/registered/labels/taints/ephemeral_disk via the box's textfile;
      `MgmtNodeMissing`/`LiveStateDrift`/`InstallDrift`/`MgmtBelt*` — all 91 series 0 at landing.
      Pre-merge impact line LANDED (#1858). (2) stands (home = `machine.nodeTaints`), detected not
      fixed. **Reconciler layers 3–5 LANDED** (#1864): `reconcile:` in machines.yaml, box loop
      `mgmt-reconcile`, wk-03 the only `auto` (idle, in sync). **Next:** its first live sync = the
      attended 1.14 canary (FU-033); then the `install_disk` axis.
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
      wrong system).** One gauge `credential_expiry_timestamp_seconds` + one <30d alert; live-poll
      Cloudflare `/user/tokens` (needs a tiny User:API-Tokens:Read mint), declared expiries for
      file-shaped creds; alert is `triage: none` → HA (responder can't touch admin creds — the
      remedy is host-side). Design: [`docs/secrets.md`](secrets.md) §Credential expiry is telemetry.
      **Urgency is real**: 4 CF tokens expire 2026-12-14…2027-01-09 (earliest = the broad
      "Read all resources" token — RETIRE it when `homelab-observability-read` lands, don't
      renew). **Next:** mint the inventory-read token + the exporter leg (can ride the
      cloudflare-exporter build). Relates FU-150 (silent-expiry class), FU-039.
- [ ] **FU-036** — AWS cleanup: delete the orphaned Route53 hosted zone `ZCGRPARGVE3CW` (+ the
      leftover ACM/Sectigo certs its `_*` validation records imply). Needs admin SSO (the jail key
      is read-only). Recipe: `docs/cloudflare.md`. Optionally do it as the first `tofu/aws/` root
      (which would also adopt the audit user, `scripts/aws-bootstrap-audit-user.sh`).
