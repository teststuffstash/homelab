# Follow-ups (the FU tracker)

Running list of loose ends and deferred work — the stuff intentionally not finished yet. Bigger
parked *features* live in `ROADMAP.md` → "Backlog / parked features"; this file is the operational
tracker.

**Conventions (the contract):**

- Every item has a stable id **`FU-NNN`** (3 digits, sequential, **never reused**).
  Next free id: **FU-184** (FU-183 was minted out of order while this line still said 182; 183 is archived). Burned ids (issued, then retracted without ever being work) are declared
  right here in the form `FU-NNN burned — <why>`, permanently — the declaration IS the record, and
  the lint reads this line so a reference to a burned id doesn't register as dangling:
  **FU-122 burned** — filed then retracted 2026-07-31 as already-shipped (ADR-093).
  **FU-141 burned** — filed 2026-08-05 for un-reaped ephemeral OpenRouterKey CRs, retracted the
  same day: already **openrouter-operator#10**, and a fixer-enabled repo's own issue is where that
  belongs (routing table) — the prior-art grep covered this tracker but not the repo's issues.
  **FU-175 burned** — skipped in numbering, never issued: FU-176/FU-177 were filed without
  touching the counter (found by the PR#596 review reconciling it, 2026-08-19).
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

_Last updated: 2026-08-11 (fu-sweep over the Observability & evidence subsection, after the
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

- [ ] **FU-173** — **Grafana panel plugins install unpinned** — `grafana.plugins:
      [frser-sqlite-datasource]` in `argocd/platform/values/kube-prometheus-stack.yaml` fetches
      the LATEST release on every pod start, so a plugin release can change prod behavior with no
      commit anywhere. Ruled out as the cause of the 2026-08 sleep-overview breakage (no frser
      release since 4.0.6, 2026-05-11) but it's a live silent-regression vector, and sleep's
      integration gate pins 4.0.6 — prod can drift from what CI tested. **Next:** pin the version
      (`frser-sqlite-datasource 4.0.6` in the plugins list) and let Renovate own the bump like any
      chart. Surfaced by sleep-tracking#121 (dashboard render goal). Relates FU-136.
- [ ] **FU-137** — **Garage durability: POINTER.** The risk fired 2026-08-24 — meta LMDB wiped
      in the pve thin-pool incident, Aug-4 backup restored same day
      ([incident](incidents/2026-08-24-pve-thin-pool-garage-meta-wipe.md), homelab#884).
      **ADR-114** (2026-08-24) answers it: rf=3 across physical zones, engines-replicate/
      storage-stores-singles, backup = logical-deletion CronJob — design, grounding links,
      history: [`docs/garage.md`](garage.md) §Durability + §Target architecture.
      **Next (oracle-prod-deadline-bound, ~2026-08-31):** the build-out — garage rf=3 migration
      (local XFS, wk-metal-01/04 + wk-02 interim), CNPG replica-1 + required zone anti-affinity,
      backup CronJob. Offsite stays parked behind oracle/idp prod. Relates FU-013, FU-012, ADR-031.
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
      **homelab** repo itself into Forgejo (the `sleep-lab` org mirrors exist since 2026-06-21) —
      ⚠ **and those mirrors are BROKEN since the 2026-08-04 Forgejo DB migration**: pod logs show
      `SyncMirrors` failing for the sleep-lab repos (observed 2026-08-08 by the idp jail session
      while repairing the same migration's orphaned-repo residue — its fix recipe: remove the
      orphan dir on the git volume via kubectl exec, recreate through the API with the wallet
      password; the API token lacks org scopes). Next: apply that recipe to the sleep-lab
      mirrors, verify a sync cycle, THEN the cutover steps. Then flip `var.argocd_repo_url` +
      child-app `repoURL`s and deliver the Forgejo read cred via ESO. Procedure:
      `argocd/README.md` → "Forgejo cutover".
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
- [ ] **FU-039** — **Platform self-service (XRD claims) — next legs: POINTER.** The
      public-ingress leg's design, completion-state table (built + ARMED 2026-08-08, zero
      consumers) and open legs (test claim, ha retrofit = consumer #2, zone-phase rulesets,
      product zones): [`docs/cloudflare.md`](cloudflare.md) §PublicRoute. Still thin homelab
      PRs per stack: LAN subdomain opt-in (ADR-092), git repos, AppProject/ns. **Next:** the
      operator-witnessed test claim; separately the **teststuff.net edge-metrics poller**
      (free zone invisible to the lablabs exporter #132 — DIY GraphQL, github-exporter
      pattern). **The poller leg ABSORBS the deleted `CloudflareEdge5xx` belt (homelab#363,
      2026-08-17):** since #350 removed the alert (its input series is unproducible on free-plan
      zones), NO edge 5xx/error-rate belt exists at all — the poller's first deliverable is the
      replacement alert on its own series, not just dashboards. Program: `ROADMAP.md` →
      "Platform self-service via Crossplane". Relates ADR-076, ADR-085, ADR-092, ADR-101, FU-068.
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
      sleep-iac#57 (fixer block — snore is IN THE LOOP). Step (1)'s apply turned out ALREADY DONE:
      the operator's 2026-08-12 host-side plan read "No changes" with snore-recorder committed in
      deploy_repos — it rode an earlier apply (~2026-08-04, the circles-secret fix) unrecorded.
      **Remaining:** (1) observe one real snore build → pin PR → Pi converge E2E (organic);
      (2) the first half (operator-chart + pod-image shapes). Relates FU-097, ADR-084.
- [ ] **FU-125** — **Renovate silently REGRESSED to zero dependency PRs — while reporting success.**
      Real bumps flowed 2026-07-05/06 (FU-014's rollout evidence); measured 2026-08-01 (run #115)
      all 10 autodiscovered repos abort — 4 `integration-unauthorized` (incl. sleep-tracking, where
      writes worked on 07-05), 6 `repository-changed`. 115 green runs, zero PRs, no Dependency
      Dashboard, `renovate/pin-dependencies` (Actions SHA-pinning) orphaned since 07-27. Same
      silent-success class as FU-108/FU-113. Evidence + inventory:
      [`docs/dependency-upgrades.md`](dependency-upgrades.md) §"Ground truth".
      **Next:** ABSORBED into Goal homelab#502 (inert, 2026-08-18 — Renovate live for the
      platform stack, sans management box; the App permission diff, liveness gauge, prPriority +
      `NIX_VERSION` hygiene and the pin-dependencies branch are its acceptance items).
      `dependencyDashboard: false` by ruling 2026-08-18 (click-ops; dashboards closed; liveness =
      the exporter gauge ONLY). This item closes when #502 validates.
      Relates FU-014 (archived), FU-046, FU-097, FU-016.
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

- [ ] **FU-185** — **Shellcheck gate on the agent glue.** The 2026-08-24 shell audit: ~13
      recorded shell-language defects (unbound vars, bashisms, masked exits, fail-open `||`),
      disproportionately the SILENT class — and ShellCheck's SC2318 names the exact
      `local`-expansion bug that killed every model-scout tick for 6 days (#854; PR#862's
      first diagnosis was refuted by the live log). ADR-113 rules the split: bash stays glue,
      decision logic is Python, no wholesale rewrite. **Next:** add `shellcheck` to devbox.json
      + a required `ci` step (`shellcheck -S warning agents/*.sh scripts/*.sh` — .github edit,
      operator lane) and burn down the ~8 standing warnings (3 scout / 4 scan / 1 launcher) in
      the same PR. Relates ADR-113, ADR-103, #854.

## Agents

Sub-grouped 2026-08-07 — the block had reached 34 of the tracker's 57 open items and read as one
lump, so nothing could be scanned by concern. The groups are the loop's own stages, not invented
taxonomy: an item belongs where its NEXT ACTION lands. Keep them; adding a sixth group is a signal
the block needs pruning, not more headings.

### Dispatch & issue lifecycle — the scan's clauses, holds, doorbells, and how an item moves

- [ ] **FU-178** — **Two readers, one mirror: the doorbells read `agents/stacks.json` while the
      scan reads the live cluster claim** — a claim change (chain redirect, knob flip) reaches
      the scan in minutes and the doorbell side only when someone remembers to sync the file
      (found live 2026-08-02: a redispatch rode the file's stale chain two hours after the claim
      moved). Rescued 2026-08-19 (the untracked-work sweep — its only home was a meta-state durable
      warning). **Next:** doorbell-side callers (`coordinator-session.sh`, `agent-session.sh`,
      `coordinate-ring.sh`) read the cluster with the file as the probe-failed belt — the same
      merge `stacks_json()` already does; or extract that seam for the launchers. Relates
      FU-049 (generating the mirror), ADR-085.

- [ ] **FU-168** — **The dispatch design revisit chartered at #278's closeout — the design half
      is ADR-106's (the A3 sitting); this item now tracks the build + soak.** (a) concurrency
      shipped 2026-08-12 (the A2 famine PR — doorbell collapse + `--detach` mutex scoping +
      FU-144 fan-out; the 017790c wake metrics + `AgentDispatchCronWoken` are the acceptance
      instrument — cron-woken dispatches ≈ 0 once soaked); (b) the `Touches:` fence demotion +
      mechanical governance lint = Bucket A4 (ADR-106 (4)). Evidence:
      [`docs/spikes/goal-lane-v1.1-fu165-pilot.md`](spikes/goal-lane-v1.1-fu165-pilot.md)
      findings 4–5. **Next:** watch the wake metrics after the A2 merge+sync (the alert is the
      regression tooth); close when A4's fence half ships and the famine numbers hold.
      Relates ADR-106, ADR-094, ADR-097, FU-167, FU-090.

- [ ] **FU-169** — **Differential coverage as a REVIEW INPUT (operator design, 2026-08-13).**
      The reviewer can't see whether a PR improves or reduces test coverage; the blanket
      per-repo % gate (sleep's 85%) can't say WHICH new lines are uncovered. Target (the
      SonarQube shape): CI knows master's coverage, computes the branch's, and the review runs
      on a coverage-annotated diff — "these 2 new lines have no coverage" — so every missed
      line needs a stated justification (the fixer knows to justify; the reviewer judges the
      reasoning) instead of a threshold nobody can argue with. Per-language tooling
      (pytest-cov exists on sleep); stack-repos-first, homelab's bash/YAML CI mostly exempt.
      Next: pilot on ONE stack repo — diff-coverage step in CI + the annotation surfaced to
      the reviewer (check-run annotations or reviewer-context injection). Relates FU-095
      (review-quality program), ADR-103 (executable gates > prose).
- [ ] **FU-170** — **Go-rail balance fallback is INVISIBLE to the cluster (operator, 2026-08-14).**
      The Go WEEKLY window hit 100% mid-round; opencode's "use balance after limits" toggle
      (€10) keeps the rail serving, silently billing real money per request. The cluster can't
      tell: the meter still accrues window usage, no alert exists, and the reviewer Go-failover
      latch keeps dispatching into paid traffic. Confirmed the same sitting: the running jail
      shim predates #442 (no gometer/spool artifacts), so jail burn is unmetered until the next
      claude-go launch (the meta-state caveat, live). Deferred BY DECISION this round (operator:
      finish it blind — the rail works, spend is bounded by the balance).
      **PREMISE CHANGED 2026-08-17 (operator): "use balance after limits" DISABLED** after the
      intentional overage week (~$7.44 of balance burnt on k3 reviews; $2.56 remains). The
      silent-billing failure mode is closed console-side — a window at 100% now hard-429s the
      rail instead of spilling to balance, which the proxy's self-metered latch + failover
      already handle. Residual: the meter-window threshold/alert half (know we're NEAR the
      limit before dispatching into it); the console-scrape option loses urgency. Design home
      unchanged: the charter's cost rethink
      ([`agents/chainless-redesign.md`](agents/chainless-redesign.md) §cost rethink,
      #431/#432) extended rail-side.
      **SCOPED 2026-08-17 (operator, dashboard-parity review):** the residual = three proxy-side
      pieces — (a) **Go concurrency semaphore** ✅ DONE 2026-08-17 (PR#484 + `OPENCODE_MAX_RUNNING=5`
      explicit in the deployment; composed into `/opencode-limit` limited, gauges + board panel), (b) **jail-ingest
      freshness gauge** (age of last `stack=jail` go_usage row — the 2026-08-17 stale-shim
      under-metering, detection half), (c) **Go 429 counter + near-threshold alerts** (zero
      opencode-window alert rules exist today), (d) **observed-429/402 LATCH** ✅ DONE
      2026-08-19 (#600→#603, organically proven on #607's monthly-limit 429; persistence
      #618→#621 — a proxy roll no longer drops a hold; delivers (c)'s counter half), (e) **the
      launcher REROUTE** ✅ DONE 2026-08-19 (PR#610 — a latched Go-primary dispatches the
      `claude/haiku` fallback same-round; semaphore still defers). Dashboard parity panels ride each piece.
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

- [ ] **FU-181** — **Go-rail post-reset readout (after the 2026-09-13 monthly reset —
      operator, 2026-08-19).** The rail is monthly-latched until then (observed-429 latch;
      Retry-After ≈ the reset epoch), so homelab#540 (gometer parity: console 100%/99% vs meter
      63%/25% — draw under-count; window ANCHORING now matches, evidence in #540's 2026-08-19
      parity comment) and the #420 container closed as unactionable-until-reset. On the first
      clean window after Sep-13: (1) re-run the meter-vs-console parity check on a clean 5h
      window (#540's check); (2) capture the 5h-window refusal shape on its first organic fire
      (429 vs 402 + its Retry-After — `router_go_observed_429_total{code}` and the latch log
      line self-record it); (3) confirm the persisted latch (#618/#621) survives a proxy roll
      while genuinely held. Relates FU-170 (residual gauges/alerts), homelab#540, homelab#420.
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
- [ ] **FU-171** — **A long Go-served review outlives the ~1h git token (observed 2026-08-14).**
      The #447 review ran 47 min (kimi-k3, **$6.33** — balance regime, FU-170); the dispatch-time
      installation token 401'd ~07:50Z BEFORE the verdict posted — a full CHANGES_REQUESTED lost
      (recoverable: S3 reviewer-r1 transcript + pod log); `/var/run/reviewer-git/` never refreshes
      mid-session. Interim mitigation LIVE same day: reviewer Go-failover model kimi-k3 →
      deepseek-v4-flash (direct-to-master, operator) — cheaper/faster rounds fit the token window.
      Next: mid-review token refresh (re-mount/re-mint on 401); re-verify on the next >30-min
      review. Relates FU-170, #435 (review-state snapshots proved their worth here).
- [ ] **FU-172** — **#447 r1 review residues (operator merged wittingly, 2026-08-14).** The
      verdict died in posting (FU-171); the operator merged #447 direct (08:11Z). Findings are
      preserved in S3 (`reviewer-r1-20260814T075318Z`). Remaining: (1) only-free guardrail
      admits ANY `opencode/` id on the paid key — sentinel warns only (ACCEPTED RISK under the
      "assume free for now" direction; fail-closed decision later); (2) the zen metering
      self-test is vacuous (≈0.0 passes with no row recorded); (3) pre-existing hole: the
      only-free check admits `opencode-go/<id>:free` before the rail denial; (4) `_opencode_scrub`
      drops OpenAI-shaped function tools on the /api surface (since #421; relates #448).
      Next: (2)+(3) small PR; (1) decide with FU-170's signal choice; (4) rides the #448 probe.
- [ ] **FU-167** — **Replay-harness cleanup: POINTER.** The serialization tax (ratchet coupling
      × ADR-097 = one global clause-lane lock; PR#275's register conflict) plus the measured
      duplication (0 worlds shared by reference, 23 forked world paths, 74 single-row fixtures
      against the platform's own decision-table doctrine). Plan + evidence:
      [`agents/replay/README.md`](../agents/replay/README.md) §The cleanup contract (7 moves:
      world registry, table mode, generated register, pins metadata, family dirs, hermeticity,
      suite fold-in). **Stint #661 executed the bulk (2026-08-19 night):** table batches 2–4
      (go-rail-latch 11→1, fu088-ladder+goal-budget-refusal 5+5→2, retro-harvest+summary-comment
      5+4→2 — PRs #673/#677/#681, every stream byte-exact) + move 7 (5 standalone harnesses →
      `mode: suite`, PR#671). **The #354 post-refactor adversarial acceptance PASSED first try**
      (PR#684: unexplained assertion removal, green+armed → CHANGES_REQUESTED naming the exact
      lost coverage + the worlds-are-extraordinary rule; record on #666). **Next (fix-density,
      no deadline):** move 1's maintenance half (`record` wrapper + `--rerecord`), move 4's
      pins↔FSM bidirectional lint, straggler small families as touched; sprout homelab#678
      (fold the #668 fixtures into the go-rail-latch table). Relates ADR-097, ADR-103, FU-165,
      FU-168, #354, homelab#661.

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

### Merge path, CI & deploys — reviewer, auto-merge, first-party bumps, the gates

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

- [ ] **FU-180** — **Subscription budgets + fair-scheduling window shares (chainless
      cost-rethink directions 3–4).** Goal budgets on the platform stack stay CAP-PHANTOM until
      subscription budgets exist (#278 closed at $76/$60 phantom vs ~$0 real); the design —
      work-conserving per-stack window shares, budgets metering TOTAL cost across roles/rails —
      is [`chainless-redesign.md`](agents/chainless-redesign.md) §The cost rethink. Rescued
      2026-08-19: its build home was "a later wave of #420", which closed at the stint pilot.
      **Next:** the accounting half rides FU-131/#278's rail-aware summation; the scheduler
      half is a design sitting before any Goal whose `Budget:` must be real. Relates FU-088.

- [ ] **FU-161** — **Scout v3: variant filter + benchmark cross-check + typed cell-keyed canary
      verdicts.** Design: [`model-routing.md`](agents/model-routing.md) §M7 legs 1–5. Legs 1–2
      SHIPPED 2026-08-11 (#282); `SCOUT_MCP_KEY` wired (#299). **Envelope SETTLED 2026-08-12:**
      hand-fire `model-scout-2psl6` ran KEYED (secret in env, digest #380, no JSON-RPC errors) —
      all-`unbenched` is honest newcomer state, the call shape is right. The digest's canary
      column still shows v2 bare `failed` on both free candidates — exactly what legs 3–4 fix.
      **⚖ FILING GATE RULED (operator, 2026-08-17, closing digests #380+#455 unread): "the
      scout graduations are pointless — zero information."** An all-`unbenched`, canary-less
      digest asks for a graduation call on no evidence. Honest-but-empty must not FILE: the
      canary rung (leg 3) runs BEFORE the digest, and a digest whose every row is unbenched AND
      uncanaried posts nowhere but the log — no issue, no 🌱 line. **Legs 3–4 + the filing gate SHIPPED by the machine lane** (#469 → PR#499, merged
      2026-08-18; #506 ruled common-cause whole-set) — found at the 2026-08-23 G-A launch
      reconciliation, the tracker line was stale. ⚠ Written-not-proven: no organic scout fire
      since the merge, and every 08-10..08-17 canary died `nonzero-exit-1` at $0 (runner
      fault, verdicts void — the models carry no evidence either way). **Next:** the residue
      — first-fire proof, Go cells (post Sep-13), rung-2/FU-095(c), pool depth, void the
      tainted rotation rows — owned by G-A child homelab#778 (re-scoped, Goal #775). Related: #235's belt (machine lane owns it).

- [ ] **FU-095** — **Task-class model routing + multi-harness evidence: POINTER.** Design +
      pilots: [`docs/agents/model-routing.md`](agents/model-routing.md) (§M8 capability feed BUILT
      2026-08-03; §M10 the unrouted coordinator lane); decision record ADR-096 (P1–P3+P5 live).
      ⛔ **The P4 soak has been measuring a router with an EMPTY strike table** — strikes were never
      recorded (found + fixed 2026-08-07, `32b0fb3`), and enforcement stays OFF by operator ruling
      because the evidence contradicts "N strikes and you're out" (3 deaths vs 3 clean on lg).
      Mechanism + the open blacklist/retry/fan-out question: §M1a. **Next:** gather strike data with
      enforcement off, decide the policy, THEN judge the P4 flip.
      **Open:** legs (b)+(c) unstarted; wiring the coordinator lane to `/route` (§M10).
      **G-A (Goal homelab#775, 2026-08-23) owns the §M10 wiring (children #780/#781/#782) and
      leg (c) (rides child #778); leg (b) is IN-scope since ADR-112 (2026-08-23) superseded ADR-107
      decision 3 with the harness matrix — the scout's 3-harness cells (#778 scope + #791/#792) ARE the (b) evidence surface.**
      Relates ADR-077, ADR-081, ADR-096, FU-044, FU-046, FU-057, FU-062, FU-105.
- [ ] **FU-127** — **One model-id parser LANDED; the structured claim field is the rest.**
      `agents/model_id.py` is the single implementation of `{rail, harness, model}` with the
      overloaded-prefix rules in one commented place (incl. the cloaked `openrouter/<codename>`
      case, where the prefix is part of the id). Migrated: agent-session.sh (both sites),
      research-fanout.sh, `estimate_budget.normalize_model`. The proxy keeps its own copy — another
      deployment unit, cannot import — so `devbox run model-id-test` executes that function out of
      the proxy file by AST and fails CI if the two ever disagree. **Next:** the structured
      `{rail,harness,model}` form in claims + `stacks.json` (string stays canonical; the parser is
      the compatibility layer), which is also where a future rail (local vLLM) lands. G-A
      (Goal homelab#775, 2026-08-23): the routed-RESPONSE carrier is child #776; the
      claim-field half rides the goal's checkpoint-minted claim reshape.
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

- [ ] **FU-164** — **doc-heat: transcript-derived read heat over repo markdown — POINTER.**
      Question, heat doctrine (heat × class × age; blind spots; approximate lines), v0 (jail
      parser + static report, `devbox run doc-heat`) and the serving plan:
      [`docs/spikes/doc-heat.md`](spikes/doc-heat.md) (opened 2026-08-11). **Next:** run a
      docs-cleanup pass WITH the report (the spike's settle test); then the v1 cluster leg
      (`s3://agent-transcripts`, path normalization, jail/cluster separate + combined views —
      operator requirement), which also delivers context-repos.md's measurement sweep.
      Relates FU-117, FU-163, FU-058, FU-140.

- [ ] **FU-058** — **Retro P3: POINTER.** ⚠ First unattended PLATFORM fire (2026-08-24 05:00Z)
      FAILED — cell-a to the Anthropic 529 storm (transient), cell-b budget-403, and BOTH cells
      rode the routed model (hy3) instead of their configured cells (#861, the #782/#810 class).
      Re-fire by hand after #861 merges — that fire is the deferred acceptance read.
      Design, run history, the 2026-08-17 SPLIT ruling
      (platform retro first, stack retros second) and the 2026-08-19 platform-series build
      (the #587 stint: rename + ride-ns guard + fleet read token + KPI drop + content floor +
      RetroReportOverdue restart-gap hardening — PRs #619/#620/#623):
      [`docs/agents/observability-and-retro.md`](agents/observability-and-retro.md) §B2.
      **Next:** the Mon 2026-08-24 05:00 UTC cron is the platform series' first unattended
      fire = the build wave's organic acceptance (full report per cell, distinct files for
      byte-identical cells, cross-review refuses nothing silently, no false
      RetroReportOverdue); then the ledger emitter gaps (brief-v2(b) + r4's three blind
      spots), MCP transcript slices, and stack retros authored against the platform
      coverage (non-overlap). Absorbs FU-057's residue. Relates FU-095, ADR-103 (rule 3).

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
      (2026-08-05), **G01 ENFORCEMENT FLIP 2026-08-18** (PR#548 + operator grant/apply: sentinel
      posts the required `iac-sentinel` status under the reviewer App on all four repos incl.
      homelab — the homelab baseline `policy/iac/exceptions/homelab.yaml` + owned gitleaks
      config made the platform repo clean; push guard live on oracle-iac only, GitHub 422s push
      rules on public repos — §L0b has the full state; tier-1 CODEOWNERS scaffold dropped).
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

- [ ] **FU-093** — **Storage-tier ledger + metering: POINTER.** The rule, the double-book
      history, the lint (2026-08-02), the 2026-08-03 reconciliation (121%→89%) and the 2026-08-07
      retier (third bulk zone, wk-02 → std, the half-applied fence, the never-armed quota, and the
      LVM thin pool underneath wk-02 that no sum could see): [`docs/storage-ledger.md`](storage-ledger.md).
      **Longhorn metering DONE** 2026-08-04 (`02cf8bb`) — both sums, `argocd/resources/longhorn-alerts/`.
      **ADR-089's quota DONE** 2026-08-07 — it had never been set on a single claim, so no
      ResourceQuota existed cluster-wide; now armed on all four stacks.
      **Next:** Garage admin-API metrics (`:3903`) + ServiceMonitor + >80% alert — the last
      unmetered tier. Blocks the FU-106 "mechanical" predicate.
      **2026-08-24: the third sum went unmetered into its third 100%** and took wk-01 + Garage's
      metadata with it ([incident](incidents/2026-08-24-pve-thin-pool-garage-meta-wipe.md)) —
      the pve thin-pool Data% metric + alert is now the FIRST priority here, and freed blocks
      need a periodic guest fstrim (discard=on alone returns nothing; Talos never trims).
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
- [ ] **FU-155** — **PSI-stall shared-fate kills RECUR on hardened nodes: POINTER.** Burst
      mechanism, evidence (incl. the broken ~10-day cadence premise — wk-metal-03 flapped ≥4
      cycles in ~2.5h on 2026-08-08, only visible by hand-auditing comments across 3 issues)
      and the ⚖ recommendation (pin the ephemeral tier to Talos v1.13.8 first, alone,
      re-measure): [`docs/spikes/talos-psi-thresholds.md`](spikes/talos-psi-thresholds.md)
      (#157/PR#160). **Next:** operator rules tune-vs-accept; run the spike's §6
      `talosctl get oomactions` capture BEFORE any upgrade. Victim-surface shrunk 2026-08-17:
      the two biggest UNLIMITED pods got limits (#485 Prometheus 8Gi marker-limit, #487
      workflow-controller 1Gi) — the OOMController's preferred-victim set no longer contains
      them. ⚠ Still IN the preferred-victim set: `cilium-agent` runs BestEffort
      (`resources: {}`; homelab#63's evidence — closed into this item 2026-08-18, ≥4 restarts
      on wk-metal-03 alone). Whether to give it requests is part of this item's tune-vs-accept
      ruling — the spike's Talos-pin experiment comes first. **2026-08-24: recurs on the
      SERVICE tier** (#857 — thinkcentre, a 5-kill branch-A burst in ~2s at 10:52Z; the §6
      `oomactions` capture is RUN pre-upgrade, evidence on #857: all scores nonzero =
      ranked-Burstable path, not the §1.4 zero-score bug). Scope question REOPENED: Option A's
      v1.13.8 pin now reads as ALL metal nodes (thinkcentre/hp-01 upgrade safely; nocloud VMs
      stay excluded), still the operator's ruling. Relates FU-139/FU-112, ADR-044.
- [ ] **FU-033** — Before any Talos 1.14 upgrade: apply the `VolumeConfig secure:false` /
      `noexec` patch or `/var` breaks Longhorn v1 (warning in `tofu/longhorn.tf`).
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
