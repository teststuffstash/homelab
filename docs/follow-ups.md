# Follow-ups (the FU tracker)

Running list of loose ends and deferred work — the stuff intentionally not finished yet. Bigger
parked *features* live in `ROADMAP.md` → "Backlog / parked features"; this file is the operational
tracker.

**Conventions (the contract):**

- Every item has a stable id **`FU-NNN`** (3 digits, sequential, **never reused**).
  Next free id: **FU-157**. Burned ids (issued, then retracted without ever being work) are declared
  right here in the form `FU-NNN burned — <why>`, permanently — the declaration IS the record, and
  the lint reads this line so a reference to a burned id doesn't register as dangling:
  **FU-122 burned** — filed then retracted 2026-07-31 as already-shipped (ADR-093).
  **FU-141 burned** — filed 2026-08-05 for un-reaped ephemeral OpenRouterKey CRs, retracted the
  same day: already **openrouter-operator#10**, and a fixer-enabled repo's own issue is where that
  belongs (routing table) — the prior-art grep covered this tracker but not the repo's issues.
- **An archive entry may stamp the date after the id or at the end of the entry** — both
  `- **FU-NNN** *(archived YYYY-MM-DD)* — …` and `- **FU-NNN** — … *(archived YYYY-MM-DD)*` are
  read by the freshness check. Prefer the first; it sorts and scans better.
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
  delete it and scrub remaining references in living code/docs — TICK-LOG/ADR/incident references
  are historical and exempt. **Scrubbing a pointer item's id = repointing, not deleting**: the
  code/doc comment loses the `FU-NNN` but gains a link to the doc that survived, so the trail
  doesn't go cold. `devbox run follow-ups-lint` checks all of this.
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

_Last updated: 2026-08-07 (fu-sweep over the Dispatch + Merge-path subsections: **FU-111
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

- [ ] **FU-137** — **Garage has no offsite backup** — `replication_factor = 1` on one node, all
      redundancy borrowed from Longhorn's 2 replicas, and nothing copies the objects off the
      cluster. (FU-013 backs things *into* Garage; this is the other direction.) **Interim taken
      2026-08-04:** `devbox run garage-backup` → `backups/garage/` on the jail host, count-verified,
      `ert-snapshots` excluded as re-ingestable. **Next:** the operator's AWS/Civo bucket — parked
      behind oracle-fleet/idp reaching prod, so the interim carries the risk until then; a cron
      would need FU-012-style creds and a runner. ⚠ now load-bearing for tofu state as well.
      Posture + numbers: [`docs/garage.md`](garage.md) §Durability. Relates FU-013, FU-012, ADR-031.
- [ ] **FU-076** — **Re-check the metal reinstall mystery on the next metal (re)install**: a
      maintenance-mode reinstall of wk-metal-03 applied config verifiably carrying the
      metal_kata installer URL yet produced the plain-metal schematic (fixed via `talosctl
      upgrade`; likely also the origin of the kata `/dev/kmsg` regression, see
      `docs/spikes/kata-ci-gate.md`). Verify install.image is honored from maintenance mode.
- [ ] **FU-072** — **Root-cause why kata pods can't reach `10.96.x` service VIPs** (runc pods on
      the same node can). Symptom matrix, what's ruled out, and the next probes:
      [`docs/spikes/kata-service-vip.md`](spikes/kata-service-vip.md). Workaround in place (kata
      CI-gate pods use `dnsPolicy: None` + the LAN resolver) — fine for k3d/registry work, blocks
      in-cluster consumers like Garage transcript upload. Relates FU-116.
- [ ] **FU-007** — **ArgoCD → Forgejo cutover** (offline-resilience goal). Prereq: pull-mirror the
      **homelab** repo itself into Forgejo (the `sleep-lab` org mirrors exist since 2026-06-21).
      Then flip `var.argocd_repo_url` + child-app `repoURL`s and deliver the Forgejo read cred via
      ESO. Procedure: `argocd/README.md` → "Forgejo cutover".
- [ ] **FU-010** — Infisical↔CNPG uses `sslmode=disable` (node-pg rejects CNPG's self-signed
      cert). Fine pod-to-pod; revisit if Cilium transparent encryption lands.
- [ ] **FU-011** — Pin the Crossplane `provider-terraform` package to a digest (currently the
      `:v1.1.1` tag).
- [ ] **FU-012** — **Remote/encrypted tofu state backend** (every root is local, gitignored state).
      Hard prerequisite for anything that plans/applies off the operator's machine — the FU-097
      drift belt and the out-of-cluster applier. **3 of 5 roots MIGRATED 2026-08-04** — `cloudflare`
      (14), `provisioning` (2), `infisical` (13), each encrypted and verified with the local file
      deleted against a pre-move baseline; wallet entries seeded in `keepass-init.sh`.
      **Garage v2.3.0 does not enforce `If-None-Match` (measured 20/20), so all three run
      `use_lockfile = false`** — fine at one writer, a hard block on any automated applier.
      **Next:** the FU-097 read-only drift belt can now run for these three; ⚠ `main` stays local
      until it has an out-of-cone state copy, `github` is host-only. Ruling, cone table, runbook:
      [`docs/tofu-state.md`](tofu-state.md). Relates FU-097, FU-136.
- [ ] **FU-013** — Home Assistant `/config` (and other stateful data) backup → Garage S3 with the
      bucket-id in git — the missing "boot-from-git" DR leg (Longhorn replicates in-cluster, it
      doesn't DR). `tofu/homeassistant.tf`.
- [ ] **FU-039** — **Next legs of platform self-service (XRD claims).** LAN subdomain opt-in is
      still a thin homelab PR per stack (HTTPS-names shipped — ADR-092); git repos + ArgoCD
      AppProject/namespace remain operator PRs; **NEW leg (operator direction 2026-08-08): public
      ingress** — Cloudflare routes/cache/no-challenge-API knobs as a stack claim, admin rights +
      defaults + deprecation lifecycle + edge observability platform-side; design:
      [`docs/cloudflare.md`](cloudflare.md) §Public ingress. Program context:
      `ROADMAP.md` → Programs in flight → "Platform self-service via Crossplane". Relates ADR-076,
      ADR-085, ADR-092, FU-068.
- [ ] **FU-055** — Flip the `oracle-fleet` repo `private` → `public` when that stack reaches its
      planned open-sourcing milestone ("P3" in its design doc, kept out-of-repo). The flip is a
      `tofu/github/repos.tf` visibility change + `allow_forking = true` (GitHub forces forking on
      public repos), applied outside the jail. `oracle-iac` stays private permanently.

## CI & dependency automation

- [ ] **FU-051** — **Prove a dep bump flows E2E for the operator-chart and pod-image shapes**
      (the app+chart shape is proven — sleep-tracking digest bump 2026-07-05 → sleep-iac deploy PR
      auto-merged). **snore-recorder leg BUILT 2026-08-02** (most of it had landed earlier via
      sleep-iac#13-16 — hook, cron, ESO, known_hosts): the residue shipped as snore-recorder#15
      (CalVer + deploy-pin.sh, `ci` script, `.agents/` recipes, dup ansible deleted) +
      sleep-iac#57 (fixer block — snore is IN THE LOOP). **Remaining:** (1) operator:
      `devbox run github-tofu apply` (deploy_repos += snore-recorder — committed, wallet is
      host-side) then observe one real build → pin PR → Pi converge E2E; (2) the first half
      (operator-chart + pod-image shapes). Relates FU-097, ADR-084.
- [ ] **FU-125** — **Renovate silently REGRESSED to zero dependency PRs — while reporting success.**
      Real bumps flowed 2026-07-05/06 (FU-014's rollout evidence); measured 2026-08-01 (run #115)
      all 10 autodiscovered repos abort — 4 `integration-unauthorized` (incl. sleep-tracking, where
      writes worked on 07-05), 6 `repository-changed`. 115 green runs, zero PRs, no Dependency
      Dashboard, `renovate/pin-dependencies` (Actions SHA-pinning) orphaned since 07-27. Same
      silent-success class as FU-108/FU-113. Evidence + inventory:
      [`docs/dependency-upgrades.md`](dependency-upgrades.md) §"Ground truth".
      **Next:** diff the App's permissions/installations against 07-06 (out-of-jail), then a
      liveness signal so the next stall is loud; drop the invalid `vulnerabilityAlerts.prPriority`
      + the dead `NIX_VERSION` manager. Relates FU-014 (archived), FU-046, FU-097, FU-016.
- [ ] **FU-097** — **Write the per-surface ruling table for the surfaces ArgoCD/tofu don't
      reconcile** (OPNsense, Proxmox host, Home Assistant, Matchbox, `tofu/` roots): automate, or
      human-applied + a named drift belt. That table is the first deliverable; then implement the
      automated ones one surface at a time. Surfaces + candidate shapes:
      `ROADMAP.md` → Programs in flight → "Deploy paths"; per-root tofu split + the runner
      dependency-cone rule: [`docs/dependency-upgrades.md`](dependency-upgrades.md); the no-human
      end-state (what stays human-gated and why):
      [`docs/spikes/no-human-in-the-loop.md`](spikes/no-human-in-the-loop.md).
      Relates FU-051, FU-012, ADR-093 (Argo as the candidate runner for the ansible Jobs).
- [ ] **FU-052** — **Onboard the remaining three app repos** — snore-recorder, agent-runtime,
      agent-coordinator (sleep-tracking + openrouter-operator are done). What a repo needs, and
      what's already collapsed into the AgentStack claim: `ROADMAP.md` → Programs in flight →
      "Onboard every app repo". Still per-repo and manual: `.agents/` recipes, the `stacks.json`
      entry, and the GitHub side — FU-070's `stack-template` repo is the collapse for that.
      Unattended running still needs the per-stack reflex (FU-050). Relates FU-070, FU-048.
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

## Agents

Sub-grouped 2026-08-07 — the block had reached 34 of the tracker's 57 open items and read as one
lump, so nothing could be scanned by concern. The groups are the loop's own stages, not invented
taxonomy: an item belongs where its NEXT ACTION lands. Keep them; adding a sixth group is a signal
the block needs pruning, not more headings.

### Dispatch & issue lifecycle — the scan's clauses, holds, doorbells, and how an item moves

- [ ] **FU-144** — **Graduation killed three doorbell edges: POINTER.** Every `{repo}`-payload
      emitter rings only the GLOBAL Sensor, and the global scan skips graduated stacks. Gap,
      measured cost, workaround (`scripts/reflex-now.sh <ns>`), fix shape and the two-readers
      trap: [`workflow.md`](agents/workflow.md) §Triggers.
      **Next:** teach the remaining emitters the `{stack, loop_ns}` payload (or fan the global
      trigger out over graduated namespaces); then decide if global has a reader left.
      Relates FU-143, FU-145, ADR-094.
- [ ] **FU-146** — **The per-item dispatch hold on all three clauses — 2 of 3 PROVEN LIVE.**
      Written for WIP=1; ADR-097's raise to 3 retired it silently (~59 of 71 coordinator sessions
      did nothing, circles PR#39). Shipped: main scan `fc606e2`, doorbell fast path `277a73f`,
      `ci-red` `f0169f1` (which had to add `body` to its probe); each predicate executed against
      real data. Loki 2026-08-07 (ns circles-agents): `changes-requested held` on #18 ×8 +
      `ci-red held` on #19 ×3 — real rounds, dispatch suppressed. The doorbell fast-path clause
      ran same day but fell through pre-hold — no eligible traffic yet. **Next:** one live
      doorbell-path hold; audit any later clause for the same omission (new clauses copy the
      project-wide `wip_busy` check, not the per-item one).
- [ ] **FU-145** — **`AgentCoordinateScanWedged` measures the wrong thing: POINTER.** It keys on
      scan-pod LIFETIME, but the pod blocks on its item session, which blocks on the ride — so it
      fires on any ride >15m, on every stack (twice in one hour on 2026-08-06, both healthy, both
      self-resolving). Evidence, the two remedies ruled OUT, and why the `fc7e9fb` calibration
      cannot be reused: [`observability-and-retro.md`](agents/observability-and-retro.md) §Part A″.
      **Next:** key the alert on the deterministic scan phase.
      Relates homelab#103 (containment `fc7e9fb`), FU-090, FU-144.
- [ ] **FU-147** — **Code landed `15ef9cb`, unproven on live traffic — and it found FU-115b
      broken.** A
      `changes-requested` round that pushes nothing was invisible (circles PR#39 r3: died on a
      `-32602` truncation, classified `clean`, banked nothing — cause is agent-runtime#36).
      Reusing FU-115b's predicate exposed two bugs in it: it read `.commits[]?.commit.committedDate`
      where `gh` puts it TOP-LEVEL, so `$head` was always "" and it returned "no-op" for **every**
      PR; and comparison was wrong anyway — a good round posts stats AFTER its push. **Counting**
      is the fix (`>= 2` stats after the newest non-merge commit). Never fired: 0 `agent/arbitrate`
      fleet-wide. One shared `NOOP_ROUND_JQ` now. **Next:** verify on a real no-op round — both
      clauses were IDLE at deploy, so it is tested against real history, not live traffic.
- [ ] **FU-090** — **Sprout index / issue authoring: POINTER.** All legs, the breaker-#1 gate,
      the shipped sub-issue lineage (2026-08-02), the `Touches:` contract (ADR-097) and the
      retro-checkpoint terminal: [`docs/agents/issue-authoring.md`](agents/issue-authoring.md).
      **Next:** the exporter sprout-RATE gauge + the depth-aware harvest gate reading it.
      **Operator-deferred:** leg (c) goal-budget decomposition, `issueAuthoring.selfQueue`.
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

### Merge path, CI & deploys — reviewer, auto-merge, first-party bumps, the gates

- [ ] **FU-154** — **Closing a PR and opening a new one RESETS the anti-livelock bound.**
      `RED_ROUNDS_MAX=3` counts `Agent run stats` comments **per PR**; circles#19 consumed five
      rounds across PR#50 (2) + fresh #51 (1) after earlier rounds elsewhere. Same class as
      FU-148 — PR identity is the unit of state and re-creating the PR silently resets it — but a
      different actor (worker re-PR, not coordinator close/reopen) and a different reset (rounds,
      not auto-merge arming). Flagged by the circles jail 2026-08-07 (TICK-LOG note, then unfiled).
      **Next:** count rounds against the ISSUE (the stable id — e.g. sum stats comments across all
      PRs whose body/branch references it), not the PR; decide alongside FU-148's re-run lever
      since both want issue-keyed state.
- [ ] **FU-148** — **The coordinator cannot re-run a flaked CI job, so it close/reopens the PR
      instead.** Live 2026-08-06, circles PR#44: GitHub Actions failed in job setup
      (`Failed to resolve action download info: Service Unavailable`) during a real GH incident. The
      session diagnosed it correctly and dispatched NO worker — good — but `gh run rerun --failed`
      was refused (`actions:write` absent from the coordinator App), so it closed/reopened the PR to
      fire a fresh `pull_request` run. **That disarms auto-merge**; the session noticed and re-armed,
      but nothing guarantees the next one will, and a silently disarmed PR is invisible to the merge
      path (FU-079 class). **Next:** decide whether the coordinator App gets `actions: write`
      (`tofu/github/`) — a privilege call, not a mechanical one — or whether re-running CI should be
      a launcher-owned verb. Relates ADR-094 (launcher-owned dispatch), FU-079.
- [ ] **FU-151** — **First-party `-iac` deploy bumps skip LLM review by TIMING, not design.**
      `review-reflex.sh:262` skips `automerge`-labelled PRs (the §2 mechanical lane in
      [`dependency-upgrades.md`](dependency-upgrades.md)); the app repos open `deploy:`/
      `specs-pr:` PRs UNLABELLED. They survive only because `-iac` is `require_approval=false`,
      so auto-merge beats the 15-min tick (sleep-iac#62, circles-iac#31: `reviews=0`) — a slow
      CI run reverses it. Where the window IS long the same gap cost **5 reviewer sessions on 4
      one-line pins** (homelab#102/#104/#105). Deferred: the lanes that actually burned sessions
      are fixed (openrouter-operator#23, agent-coordinator#10), labels already exist on all three
      `-iac` repos. oracle-fleet ported 2026-08-07 (operator, oracle-fleet#173). **Next:** port
      `gh pr edit --add-label automerge --add-label dependencies` (OUTSIDE create-if-absent)
      into sleep-tracking, circles, snore-recorder.
- [ ] **FU-152** — **One version file for the agent-coordinator image, so the bump touches ONE path.**
      The deploy-pin `git grep`s and sweeps **8** manifests under `agents/coordinator/`, so it grows
      silently as manifests are added and CODEOWNERS must carve out each one. homelab#113 shows both
      failure modes at once: structurally red (it bumps `reflexes-argo.yaml`, carved out only for
      arc-runner pins, so `pin-only-lint` rejects the tag) AND unmergeable (7 swept files are owned).
      **Operator design, better than extending the lint:** hold the tag in ONE file the manifests
      take it from — mechanically a kustomize `images:` transformer, converting `agents/coordinator`
      from a plain directory app (no precedent here yet). One file bumped, one carve-out, no regex.
      ⚠ `argocd/resources/agentstack/composition.yaml` holds the literal too, different app.
      **Next:** convert the app + move the pin, then drop the extra carve-outs.
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
- [ ] **FU-150** — **Nothing alerts on "CI cannot dispatch": POINTER.** 5h of `queued`-forever
      runs with every belt green — full analysis:
      [`docs/incidents/2026-08-07-arc-listener-wedge.md`](incidents/2026-08-07-arc-listener-wedge.md).
      Vendor half SHIPPED 2026-08-07 (`72c3a42`: githubstatus.com poll → `GithubVendorOutage`).
      **Next (the OURS-side half):** an alert on the throughput signal — prefer zero
      `AutoscalingListener` while an AutoscalingRunnerSet exists (cluster-local, no new poller);
      alternatives: listener crashloop, queued-age.
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
      from devbox (`kubernetes-helmPlugins.helm-unittest`, nix installs it as a dir, `$HELM_PLUGINS`
      finds it) instead of a 23 MB unverified GitHub-release pull per run — circles#15 (the
      `new-stack --from` donor) + sleep-tracking#115, both verified locally against the profile's
      plugin. agent-runtime#30 switches the ride's nix `extra-substituters` → `substituters`, so a
      LAN miss no longer reaches cache.nixos.org (28 lookups in one harvest; a hang once egress
      enforces). homelab side landed: `stack-lint` CACHE-01 probes what the LAUNCHER probes
      (anonymous ghcr pull of `<repo>/devbox-cache:latest`) + `new-stack` step E2. **Next:** confirm
      on a post-merge ride that no WAN fetch remains, then archive. (The one known residue is
      `tofu validate`'s provider download, deliberately outside `ci` — `dependency-upgrades.md`.)
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

- [ ] **FU-095** — **Task-class model routing + multi-harness evidence: POINTER.** Design +
      pilots: [`docs/agents/model-routing.md`](agents/model-routing.md) (§M8 capability feed BUILT
      2026-08-03; §M10 the unrouted coordinator lane); decision record ADR-096 (P1–P3+P5 live).
      ⛔ **The P4 soak has been measuring a router with an EMPTY strike table** — strikes were never
      recorded (found + fixed 2026-08-07, `32b0fb3`), and enforcement stays OFF by operator ruling
      because the evidence contradicts "N strikes and you're out" (3 deaths vs 3 clean on lg).
      Mechanism + the open blacklist/retry/fan-out question: §M1a. **Next:** gather strike data with
      enforcement off, decide the policy, THEN judge the P4 flip.
      **Open:** legs (b)+(c) unstarted; wiring the coordinator lane to `/route` (§M10).
      Relates ADR-077, ADR-081, ADR-096, FU-044, FU-046, FU-057, FU-062, FU-105.
- [ ] **FU-127** — **One model-id parser LANDED; the structured claim field is the rest.**
      `agents/model_id.py` is the single implementation of `{rail, harness, model}` with the
      overloaded-prefix rules in one commented place (incl. the cloaked `openrouter/<codename>`
      case, where the prefix is part of the id). Migrated: agent-session.sh (both sites),
      research-fanout.sh, `estimate_budget.normalize_model`. The proxy keeps its own copy — another
      deployment unit, cannot import — so `devbox run model-id-test` executes that function out of
      the proxy file by AST and fails CI if the two ever disagree. **Next:** the structured
      `{rail,harness,model}` form in claims + `stacks.json` (string stays canonical; the parser is
      the compatibility layer), which is also where a future rail (local vLLM) lands.
      Relates FU-095, ADR-096.
- [ ] **FU-131** — **Cost-ledger undercount: harvest FIXED, the T+1 sweep is what remains.** The
      `/generation` backoff was (2s, 5s) and gave up at ~7s, losing 49% of a fan-out arm's spend
      ($2.196 of $4.328 stored, the stored 29 matching OpenRouter's export to the cent). Now
      2/5/15/45s, and both outcomes are counters — `openrouter_generation_harvest_total{outcome=
      "stored"|"missed"}` on the proxy's `/metrics` — so the blind spot is a series instead of a
      hand-diffed export. **Next:** the T+1 sweep over `GET /activity?api_key_hash=` for whatever
      still misses (per-session keys make attribution exact; needs a management key), and the
      round-2 no-`/report` hole. Relates ADR-096, FU-095.
- [ ] **FU-149** — **The responder's daily budget is binding, but 12 now means a different thing.**
      ADR-099 changed the ceiling's UNIT: FU-113(c) counted distinct *incidents* (and leaked); the
      latch counts *spawned sessions* and is exact, so a day with 12 genuinely distinct alerts now
      stops triage where the old cap let it run. **First datum 2026-08-06: 30 sessions, 26 of them
      ONE incident** (the Actions outage) — that sizes the old hole, not the new steady state, and
      it exhausted the budget the day it shipped. **Deferred because the value is an evidence
      question** (as ADR-097's parallelism was). **Next:** after ~2 weeks of ORDINARY days, read
      `responder_triage_sessions_today` on the "Responder triage budget" dashboard — p95 well under
      12, leave it; `ResponderTriageBudgetExhausted` on non-storm days, raise `RESPONDER_DAILY_MAX`.
- [ ] **FU-126** — **Multi-model spec-writer fan-out (operator direction 2026-08-02): same goal
      issue → N researcher rides on N models → N un-armed `research/*` PRs → operator compares
      and cherry-picks.** **Platform legs BUILT same day:** `agents/research-fanout.sh` (per-model
      task keys `research-<n>-<slug>` — adhoc to the launcher, no strike/atomic-gate collisions;
      per-ride ephemeral budget keys; `AGENT_WIP_LIMIT=N`) + model-slug branch rule in both
      research recipes (oracle-fleet#166, sleep-tracking#110) + oracle research.yaml itself
      (grow-mode port). **Remaining:** first consumer run (idp-system specs — needs the idp stack
      bootstrap; goal-issue must package the private teststuff spec doctrine into the repo's
      specs/conventions.md; upstream FQDNs per goal via the claim's extraFQDNs dial). Reference
      output = the nemotron jail run in `/workspace/idp`. Relates FU-095, FU-090(c).

### Observability & evidence — alerts, transcripts, retro, the prober

- [ ] **FU-133** — **The alert lane files one issue per fingerprint and correlates nothing: POINTER.**
      Corpus audit 2026-08-04: **~19 of 27 issues were 5 root causes**. Resolve half shipped
      (be7b62e), `subject:` key + IAC-G10 after it, subject DEDUP 2026-08-06 (`6affc63`).
      **DISPATCH half BUILT 2026-08-07**; first live ≥2 set-pass: independence RIGHT, queueing
      WRONG (stale body, alert already resolved — coordinator refused the unit). Autopsy:
      [`iac-lane.md`](agents/iac-lane.md) §"one root cause, N alert issues" (BUILT block).
      **Remaining:** (a) FILING-side correlation (`group_by = ["alertname"]`); (c) queue-time
      CURRENCY gate — `sq_decide` skips resolved/stale-bodied issues (detail in the autopsy).
      Class postmortem: [`ghcr-mirror-recurring-fill.md`](incidents/2026-07-27-ghcr-mirror-recurring-fill.md).
- [ ] **FU-140** — **The per-stack loop transcripts have no crash-net — only the exit trap.**
      `transcripts-sync` (nightly, agent-coordinator) covers ONE PVC: `agent-coordinator/
      coordinator-transcripts`. The four `<stack>-agents` loop PVCs rely entirely on
      coordinator-session.sh's exit trap, so a tick that dies before it (OOM kill, node reboot,
      DeadlineExceeded) loses its transcript, which IS the log for an exec-run session. Found while
      checking FU-132's premise; harmless that time (267/267 files were already in Garage) by luck.
      **Next:** render a per-loop-ns crash-net from the Composition. ⚠ the loop-ns S3 secret is
      WRITE-ONLY (no reader key), so it cannot list-then-upload like the coordinator's does — either
      upload unconditionally (S3 PUT is idempotent per path) or keep a marker file on the PVC.
      Relates FU-132 (archived), FU-058, ADR-089.
- [ ] **FU-058** — **Retro P3: POINTER.** Design, runs 1+2, run-3 shape and the 2026-08-03
      unsuspend: [`docs/agents/observability-and-retro.md`](agents/observability-and-retro.md)
      §B2. **Next:** watch Monday's first unattended fire (= run 3, the swapped-cell
      cross-review); then the ledger emitter gaps, MCP transcript slices, acting on report
      candidates (list in §B2). Absorbs FU-057's residue (`key_hash` activity-API backfill).
      Relates FU-095.

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
- [ ] **FU-102** — **Prober role (the agentic canary): POINTER.** Brief + machinery checklist:
      [`docs/agents/roles.md`](agents/roles.md) §"Role machinery checklists" → prober. Origin:
      meta-11 — a manual agentic probe was the ONLY detector of a 13h Ready-but-dead outage.
      **Scheduled leg BUILT 2026-08-07, disabled everywhere:** claim knob `spec.prober` (no
      object default — the stamping lesson) renders `probe-<stack>` in the loop ns, subscription
      claude/haiku, report-only by construction (no git/gh creds); brief = `<mainRepo>/
      .agents/probe.md`, LOCATION-only contract (content waits for a 2nd stack's probe).
      **Next:** write oracle's probe.md from the proven UC-1 brief + flip `prober.enabled` on
      the oracle claim; then the sync-succeeded edge + 🌱 issue filing. Composes with FU-044.

### Roles & platform capabilities — new lanes, sandboxes, context delivery

- [ ] **FU-106** — **Build out the -iac lane: POINTER.** Role, doctrine, lane taxonomy, the
      IAC-G01..G10 gap register with per-gap status, assurance layers and the sentinel:
      [`docs/agents/iac-lane.md`](agents/iac-lane.md) (+ `iac-lane-fsm.yaml`, lint-checked).
      Closed: G02/G03/G07 (2026-08-02), G05 rung-0 + G04 sentinel v1 shadow (2026-08-03), G08
      (2026-08-05). **Next:** the G01 ENFORCEMENT flip after the sentinel shadow soak (operator:
      reviewer-App statuses:write + tofu push ruleset + required check — plan in §L0b), then G06
      advisory lens, then extend the G04 sentinel to **homelab** — one step owning two residues:
      tier 1 (`argocd/resources/**`) back to unowned, and the 87-of-154 kinds `manifest-lint`
      can't schema-check (operator 2026-08-06: the sentinel's, no separate id — doc §The platform
      lane). Relates FU-087/FU-093, ADR-084, ADR-076.
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
- [ ] **FU-117** — **Dedup the context-delivery spread into one role × context × source map.**
      DELIBERATE let-it-pile-up item (operator style: grow organically, then analyse + refactor —
      not BDUF). **Do NOT refactor yet** — keep noting sightings in
      [`docs/agents/roles.md`](agents/roles.md) §"Context delivery", which holds the root finding
      (goose never loads CLAUDE.md), the three context classes, the costs already paid, and the
      boundary a worker must respect. Interim duplication into `render_env_card()` is accepted on
      purpose 2026-07-28; this item tracks removing it. **Scope widened 2026-08-07 (operator): the
      JAIL is a third context — `teststuffstash/claude-jail` needs an env-card mechanism of its own
      so its `CLAUDE.md` is clean of instructions**, and homelab's stops mixing jail procedure with
      repo-universal facts. Relates FU-114, ADR-094.

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

- [ ] **FU-093** — **Storage-tier ledger + metering: POINTER.** The rule, the double-book
      history, the lint (2026-08-02), the 2026-08-03 reconciliation (121%→89%) and the 2026-08-07
      retier (third bulk zone, wk-02 → std, the half-applied fence, the never-armed quota, and the
      LVM thin pool underneath wk-02 that no sum could see): [`docs/storage-ledger.md`](storage-ledger.md).
      **Longhorn metering DONE** 2026-08-04 (`02cf8bb`) — both sums, `argocd/resources/longhorn-alerts/`.
      **ADR-089's quota DONE** 2026-08-07 — it had never been set on a single claim, so no
      ResourceQuota existed cluster-wide; now armed on all four stacks.
      **Next:** Garage admin-API metrics (`:3903`) + ServiceMonitor + >80% alert — the last
      unmetered tier. Blocks the FU-106 "mechanical" predicate.
      Relates ADR-089, FU-116 (archived).

- [ ] **FU-049** — **Platform services published as XRDs supersede `SERVICES.md` as the source of truth.**
      Provisionable capabilities (S3/Postgres/…) become typed Crossplane XRDs; discovery is a cluster query
      (`kubectl get xrd`) and the human catalog is *generated* from them rather than hand-curated. Open:
      build-time discovery for an app repo with no cluster creds may still want a generated static catalog.
      **Inherited from FU-107 (2026-07-27), same generation class:** agentstack.md's "what a claim
      renders" table generated from the XRD/Composition, and the stacks-state table from
      `kubectl get agentstacks` (plus `agents/stacks.json` itself — the original mirror problem).
      Design: [`docs/agents/platform-and-stacks.md`](agents/platform-and-stacks.md) §2, ADR-085. Relates
      [[service-discovery]], ADR-076 (app-owned resources via Crossplane).

## Hardware & nodes

- [ ] **FU-032** — Watch: thinkcentre's one 1Gbps link blip since the cable fix (2026-06-11) and
      wk-metal-02's flaky wired link. **2026-08-07 (homelab#117): wk-metal-02 had a 4.5h NIC
      flap storm** (`carrier_changes` 2→3778, no reboot, flat plug power) — the thinkcentre
      bad-cable class, NOT battery/power. **Next (operator, physical):** reseat/replace
      wk-metal-02's cable / switch port; evidence + counters on homelab#117.
- [ ] **FU-155** — **PSI-stall shared-fate kills RECUR on hardened nodes.** The FU-112(b)/FU-139
      kubelet reservations changed who acts first but "reservations don't tune PSI" (FU-139
      archive): wk-metal-03 (hardened 07-28) was hit again ~10 days later, wk-02 rebooted/reset
      2026-08-07 — each burst = one Talos OOMController PSI fire killing 4-5 pods in one second,
      surfacing as N PodSigkilled alerts + responder sessions (homelab#63/#65/#68/#101, all
      closed as this class). **Next:** research what Talos 1.13 actually exposes for
      OOMController/PSI thresholds, then operator decision: tune, or accept the ~10-day cadence
      and teach the responder the shared-fate signature. Relates FU-139/FU-112/FU-082 (archived),
      ADR-044.

- [ ] **FU-033** — Before any Talos 1.14 upgrade: apply the `VolumeConfig secure:false` /
      `noexec` patch or `/var` breaks Longhorn v1 (warning in `tofu/longhorn.tf`).
- [ ] **FU-034** — Buy a network Zigbee coordinator (SLZB-06 class) — unblocks local radios
      (ADR-041, Open).

## One-time ops

- [ ] **FU-156** — **`homelab-tofu-apply` Cloudflare token EXPIRES 2027-01-01** (`expires_on`
      default in `tofu/cloudflare-token/variables.tf`; confirmed live in the dashboard
      2026-08-08) — on that day jail `tofu/cloudflare` applies fail with nothing alerting.
      **Next (before ~2026-12):** `devbox run cloudflare-token-tofu apply` with a fresh
      `expires_on` → re-store per the printed checklist (wallet `cloudflare-write-key`, jail
      cache, OPNsense env for the acme twin if rotated too). Decide then whether write tokens
      keep expiries at all — the observability-read token deliberately has none (FU-150 lesson).
- [ ] **FU-036** — AWS cleanup: delete the orphaned Route53 hosted zone `ZCGRPARGVE3CW` (+ the
      leftover ACM/Sectigo certs its `_*` validation records imply). Needs admin SSO (the jail key
      is read-only). Recipe: `docs/cloudflare.md`. Optionally do it as the first `tofu/aws/` root
      (which would also adopt the audit user, `scripts/aws-bootstrap-audit-user.sh`).
