# Spike: one update process for the dependency lanes and the router

**Origin:** operator, 2026-10-10. Both stint S9 (Renovate through the lanes, homelab#1985) and the
router build (FU-297) have reached the point where updates should converge into one process.
**Status:** design with no decision taken. §Decisions lists the forks, and nothing here is
ruled. This doc is the direction for the next session.

**Grounded in:** [`../../CONTEXT.md`](../../CONTEXT.md) and [`../../ARCHITECTURE.md`](../../ARCHITECTURE.md)
for the lens. [`../dependency-upgrades.md`](../dependency-upgrades.md) supplies the classes, the
coverage table, §4 Rollout (the dependency-cone rule and the ⚓ upgrade lease), §Gap register and
§Next steps. [`../renovate.md`](../renovate.md) supplies the lanes, and
[`../dependency-classes.yaml`](../dependency-classes.yaml) the class 9 row. ADR-131, 141, 144, 145,
149, 150 and 151 are in [`../adr.md`](../adr.md). [`../management-box.md`](../management-box.md)
supplies §MB2–MB5, §The test surface and §The capability ledger.
[`../router-move.md`](../router-move.md) and [`../opnsense-test-vm.md`](../opnsense-test-vm.md)
cover the router. [`no-human-in-the-loop.md`](no-human-in-the-loop.md) contributes path 1 and the
§What stays human list. The other grounding is FU-297, 298, 302, 305, 306 and 307 in
[`../follow-ups.md`](../follow-ups.md), FU-097, 300 and 308 in the archive, and ROADMAP §HA model
and §Deploy paths. Terms are defined in [`../glossary.md`](../glossary.md).

**Prior art:** no doc owns the convergence. A grep for "update process", "one process", "rolling
firmware" and router×lease across `docs/` and `ROADMAP.md` found nothing that frames it. The
per-class lifecycle belongs to `dependency-upgrades.md`, which is measured as oversized, and the
end state belongs to `no-human-in-the-loop.md`. **No owning doc records the 2026-09-29 OPNsense
firmware ruling** ("follow the official update path, no Renovate"). It lives only in seat memory,
and `opnsense-test-vm.md` §The official update path holds the observations but not the ruling.

## 1. Today's flows, side by side

The class numbers follow the coverage table. ✅ means built and proven, 👤 means a human, ⚠ means
missing.

| Update class | Proposer | Test surface (pre-merge / pre-apply) | Merge gate | Deploy edge | Detector | Revert | Canary |
|---|---|---|---|---|---|---|---|
| **Renovate lanes**: charts/images (1/2), providers (5), lock (7), Actions (8), runner inputs (10) | ✅ Renovate, or the `devbox-update` job for class 7 | ✅ CI on the head. Class 5 also gets the sentinel's plan, which must be empty | ✅ the reflex, the migration lens, or the sentinel's green, depending on the lane (ADR-141) | ✅ ArgoCD sync for 1/2, the box apply loop for 5, self-deploying for 7/8 | ✅ Argo alerts, `MgmtApplyErroredOnNewProvider`, `GithubWorkflowRunFailed` | ✅ revert chains (`workflow-pin-revert`, `tofu-provider-revert`, `tofu-image-revert`, `chart-revert`). Class 1/2 non-reversible bumps are 👤 | ⚠ none except Actions (CI on the head) |
| **kps chart** (the cone that holds its own detector) | ✅ Renovate | ✅ CI plus the re-render (G12) | ✅ the lens | ✅ ArgoCD, with a PreSync lease | ✅ PostSync confirms the lease | ✅ the box lease loop (MB5). Drilled 2026-10-10 (#2441: tick → synced ~8 min; fixes #2429/#2437) | ⚠ |
| **Substrate** (6): Talos, Kubernetes, Cilium | 👤 a hand bump. The currency belt raises it | ✅ the sentinel plan plus the install-impact line | 👤 codeowner | ✅ `mgmt-reconcile` (WIP 1, CPs last) | ✅ node drift, the workload-health hold, `MgmtRolloutDifferential` | 👤 forward by default; a revert is a human commit | ✅ a canary node per type |
| **OPNsense firmware** | ⚠ none. The router's own `firmware/check` is the authority, by ruling | 👤 a seat trial on test VM 9110 | none: not in git | 👤 seat API calls (check → update → upgrade) | ⚠ no `firmware/status` belt (it was discussed but never built) | ⚠ none written down. The nodes are now VMs, so a `qm snapshot` is available | 👤 the BACKUP node first (rolling drill R1) |
| **Router config** (`ansible/opnsense-*`, `opnsense/*.py`). Class 9's real pin is the `oxlorg.opnsense` collection | ✅ humans write the config. Renovate proposed the collection pin (#2033) | 👤 the test VM harness, run by the seat; it posts no status (the jail PAT gets a 403) | 👤 codeowner | ⚠ none. `router-node.sh converge` per node is a seat act | ⚠ partial. The belt's `ansible --check` cannot see raw-post drift; the weekly drill score (red since 10-04) and the pair belts cover part of it | 👤 `git revert` plus a re-converge. FU-308's dead-man covers only CARP maintenance | ⚠ in the table. The live answer is the BACKUP node |
| **Matchbox** (assets, `matchbox_version`) | 👤 hand. `machines-lint` holds the Talos lockstep | none | 👤 codeowner | ⚠ a human playbook re-run | none | 👤 | the cone is near zero: nothing reads Matchbox until the next netboot |
| **Proxmox hosts** (packages, reboots) | 👤 | none | — | 👤 `pve-upgrade.yml` (in-major, never reboots) plus `host-maint` | `PveThinPool*`, host-down | 👤 | the other hypervisor |

**What the table shows.** The Renovate side has a proposer and a revert for almost every class.
What it lacks is a canary. The router side has canary machinery (the BACKUP node, the test VM and
the drill), but no deploy edge, no proposer and no automated revert. Each side has built the half
the other one is missing.

## 2. The one process they converge to

Every update in the lab is one pass through the same skeleton:

| # | Stage | What it is | The shared piece that already exists |
|---|---|---|---|
| 1 | **Propose** | a git-visible intent: a PR, or for firmware a belt-raised record | Renovate, `devbox-update` and deploy-pin for pinned versions. The currency belt (MB2 `check_substrate`) for versions git declares but cannot pin |
| 2 | **Prove** | the class's own test surface, before the merge or before the apply | CI, the sentinel's plan (ADR-131), the test VM harness, and the weekly drill as a broad post-merge realism check |
| 3 | **Gate** | the lane picked by blast class (ADR-141) | the reflex, the lens, the sentinel's green, codeowner. Unchanged |
| 4 | **Apply** | one actor per surface, one failure domain at a time, never while a [declared window](../glossary.md) holds | ArgoCD for cluster objects. **The [management box](../management-box.md) for everything else**, through the apply loop, the reconciler, and (new) the router and Matchbox reconcile |
| 5 | **Confirm** | the subject's real check deletes the in-flight record | **the ⚓ [upgrade lease](../glossary.md)** (ADR-150), generalized. ArgoCD PostSync for charts, the reconciler's `renew`/confirm for nodes (the verb exists, nothing calls it yet), `router-node.sh check` for router nodes |
| 6 | **Revert** | an unconfirmed lease past its deadline reverts | the box's lease loop. It opens a PR where the revert path does not cross the change, and acts locally where it does (below) |

**The shared pieces.** The **lease** becomes the single record of "an update is in flight", for
every class the box applies. The **box** becomes the single applier outside ArgoCD, and the
[capability ledger](../management-box.md#the-capability-ledger--what-the-box-has-been-tested-doing-on-its-own-fu-097)
stays the "may it do this unattended" table. The **coverage table** grows rows for the non-Renovate
classes (router firmware, router config, Matchbox, Proxmox), so one table answers for all of them.
The **test VM** is the router's pre-merge test surface, in the same role CI and the sentinel play
for the other classes. The **BACKUP node** is the router's canary, in the same role the per-type
canary node plays in the Talos rollout.

**Why now.** The router's human anchor in the capability ledger was conditional: "human-applied
until the redundancy exists" (management-box §The test surface, step 3). The 2026-09-29 firmware
ruling's "majors attended" had the same condition: "until the router is a VM pair". The pair has
been complete since 2026-10-09 (router-move §Status). Both conditions are now met. Neither one has
been re-read yet.

**The router's rolling update is already designed and drilled.** No-human path 1 and router-move
drill R1 both describe it: converge or update the BACKUP, then `check`, then put the MASTER into
`carp-maintenance enter` with the dead-man armed so the BACKUP serves (that is the canary under
real load). Then a soak, then converge or update the former MASTER, `check`, and `leave`. The
convergence wraps this in a lease and lets the box run it in place of the seat.

### Where the router legitimately differs

- **The revert must be local.** The box reaches `.70`/`.71` over L2. Everything else it needs
  rides the router: GitHub over the WAN (both to pull master and to open a revert PR) and
  Prometheus through a Cilium BGP VIP that `.1` routes (FU-302). A change that cuts the WAN also
  cuts the revert-by-PR path. So router reverts happen on the target, through the
  commit-confirm shape dependency-upgrades §4 first wrote for OPNsense: the node restores its own
  previous config revision, or the box rolls the VM snapshot back. The PR that records the revert
  follows once the WAN returns. This is the same rule that governs the box itself ("the apply may
  be remote, the rollback must be LOCAL").
- **Firmware cannot be pinned.** The mirror serves only the head of each series. What git can
  declare is the **series**: the test VM bootstrap's `SERIES` and the drill's `NANO_VERSION` are
  already that pin. Inside a series the policy is "latest", and the live build is a metric rather
  than a pin, which is the same pattern as devbox `@latest` plus the lock. Renovate stays out.
- **The canary is half of production, not a spare node.** Every MASTER-side step goes through
  `carp-maintenance` with the dead-man armed (the 2026-10-08 incident is why). An update costs two
  short failovers (R1: 0.6 s and 3.1 s).
- **Security-boundary changes stay human.** Per no-human §What stays human, that covers WAN
  firewall rules, port forwards, WireGuard, ACME and DNS credentials. The router reconcile reads a
  path policy that sends those to a human apply, the same way the sentinel's `deny_paths` does.
- **The test VM cannot prove everything.** It cannot exercise real BGP sessions, ACME issuance or
  real backends (see the harness header). The drill's probes and the BACKUP canary cover what the
  test VM cannot.

## 3. Gaps, and the order to close them

None of these gets a new FU id. "Needs an FU" marks a candidate; a grep for each topic found no
open item. Inside S9, the owning issue or FU is extended rather than given a new FU ("stint work, no
new FUs").

**Wave 0: preconditions (detectors and reds first, per the detection-before-fix rule).**

1. **The rebuild drill has been red since 10-04** (converge rc=2; probably the #2166 inventory
   flip). The drill is the router's realism gate, and none of the later steps should run on a red
   drill. Owner: **FU-297** (its own Next).
2. **No belt fires when the MASTER has no WAN.** This blocks any unattended MASTER-side step.
   Owner: **FU-307**.
3. ~~**The lease credential click**~~ — done 2026-10-07; the revert half drilled 2026-10-10 (#2441,
   after #2429/#2437 fixed the box's pin read and git identity). Remaining lease latency: a lease-script
   fix waits for the box's hourly pull. Owner: **ADR-150 / S9 #1985**.
4. **The box loops wedge silently on a toolchain bump.** The shared applier must not fail quietly.
   Owner: **FU-305**.
5. **The box's view of the cluster bypasses nothing.** Its reads ride the router it would be
   changing. Owner: **FU-302** — built 2026-10-10: [the box verdict](../management-box.md#the-box-verdict--the-boxs-own-read-of-the-cluster-fu-302-2026-10-10)
   reads Talos, the kube API and cilium over L2; only its VIP and `/-/ready` reads ride the router.

**Wave 1: write down what exists.**

6. Record the firmware ruling (series in git, official path, no Renovate) in
   `opnsense-test-vm.md` §The official update path. Rides **FU-297**.
7. **Class 9 is wrong in the generated table.** It extracts `ansible/requirements.yml`, which is
   empty, while the real pin is `ansible/collections/requirements.yml` (`oxlorg.opnsense` 26.1.11,
   proposed by Renovate in #2033). Its detector cell ignores the belt's `ansible --check` and the
   drill score. Its canary cell still says "one router". Split it into router config, router
   firmware and Matchbox, and add a Proxmox row. Owner: **#1992** (the table), via S9.
8. Add capability-ledger rows for the router, the router firmware and Matchbox, marked human by
   ruling, so the flips have somewhere to land. Owner: management-box §The capability ledger (FU-097's
   successor, which is the doc itself).

**Wave 2: test surfaces post a verdict.**

9. **The box runs the test VM harness on router-path PR heads** and posts an `opnsense-test-vm`
   status as `homelab-sentinel`. The sentinel already judges heads that touch box-held surfaces, and
   FU-295's base-pass shape covers PRs that do not touch router paths. Rides **FU-297** (needs an FU
   if it outgrows that).
10. **A firmware currency belt**: the box reads `firmware/status` on each node and on the test VM,
    and raises a behind-series or EOL alert. The pattern is `check_substrate` (FU-254). Needs an FU.

**Wave 3: the box applies ansible, starting with the lowest-blast target.**

11. **Matchbox, box-applied.** Its cone is near zero, which makes it the first ansible applier and
    the class 9 canary cell's own suggestion. Run it in shadow (a `--check` diff) first, then on.
    Needs an FU: "the box applies ansible". The same FU carries step 12.
12. **Router config reconcile.** Order: shadow (the per-node `--check`, as today), then BACKUP-only
    (converge, `check`, lease confirm), then full rolling (MASTER through `carp-maintenance` with
    the dead-man and a node-local config-restore timer). It must respect declared windows (FU-300)
    and the security-boundary path policy.

**Wave 4: firmware rides the same rolling path.**

13. The sequence: the test VM (roll back to baseline, update, run the harness, move the baseline),
    then the BACKUP (snapshot, update, `check`), then the MASTER (maintenance, update, `check`,
    leave), all under one lease and renewed per node. Majors go per decision D3. Rides the step 11
    FU.

**Not in this program.** Proxmox hosts stay attended (`host-maint`) until FU-306 proves the
verb-on-box wiring on the runners, and until compute HA (ROADMAP §HA layer 3) exists. Substrate
through Renovate stays on #1988's row; the reconciler adopting the lease's `renew` lands with it.
FU-298 (the collection's ACME register 404) remains a drill workaround and does not block anything
here.

## 4. Decisions needed (operator)

| # | Fork | Options | Recommendation |
|---|---|---|---|
| D1 | Where the converged process lives once ruled | (a) one ADR plus a short section in `dependency-upgrades.md`; (b) a new owning doc; (c) leave it in this spike | **(a)**. The ADR records the decision only (the lease is the universal in-flight record, and the box is the single applier outside ArgoCD). Lane detail goes to `dependency-upgrades.md` and the box mechanics to `management-box.md` (the ADR-as-pointer rule). This spike is deleted once that lands |
| D2 | Firmware version in git | (a) the series is declared, latest-in-series is applied; (b) a per-build pin; (c) nothing in git | **(a)**. It already exists as `SERIES`/`NANO_VERSION`, and it is the only form that can be installed |
| D3 | Router firmware majors, now that the pair exists | (a) still attended; (b) box-run after one attended drill; (c) box-run now | **(b)**. Run the next major as an attended drill along the full rolling path, the way the ADR-149 drill went, then arm it |
| D4 | Scope of router config autonomy | (a) every router path; (b) everything except the security boundary; (c) BACKUP-only forever | **(b)**. WAN firewall, port forwards, WireGuard and ACME/DNS creds stay human, enforced by a path policy |
| D5 | The router's revert actor | (a) a node-local config-revision restore armed before the apply, with the box lease as the outer timer; (b) the box re-converges the previous revision directly; (c) the box rolls back the VM snapshot | **(a) for config, (c) for firmware**. Both survive a cut WAN, and (b) depends on the box's path being intact |
| D6 | Serialization across classes | (a) global WIP 1 for box-run infrastructure leases (router, substrate, hosts); (b) per failure domain | **(a) for now**: one operator and one ISP. Revisit when evidence shows contention |
| D7 | Router canary soak | (a) the BACKUP serves through `carp-maintenance` for N minutes with probes green; (b) BACKUP `check` only, no load | **(a)**. It is the R1 drill shape. Soak means evidence (flows carried and DHCP served), never wall time (FU-273's rule) |
| D8 | Should the test VM verdict be required on router-path PRs? | (a) required, with a base-pass for other PRs; (b) advisory | **(a)**, once it is box-posted (step 9) |
| D9 | Proxmox hosts | (a) stay attended; (b) box-run `host-maint` | **(a)** until FU-306 and compute HA exist |
