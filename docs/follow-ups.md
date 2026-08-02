# Follow-ups (the FU tracker)

Running list of loose ends and deferred work — the stuff intentionally not finished yet. Bigger
parked *features* live in `ROADMAP.md` → "Backlog / parked features"; this file is the operational
tracker.

**Conventions (the contract):**

- Every item has a stable id **`FU-NNN`** (3 digits, sequential, **never reused**).
  Next free id: **FU-127**. Burned ids (issued, then retracted without ever being work) are declared
  right here in the form `FU-NNN burned — <why>`, permanently — the declaration IS the record, and
  the lint reads this line so a reference to a burned id doesn't register as dangling:
  **FU-122 burned** — filed then retracted 2026-07-31 as already-shipped (ADR-093).
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
- **Don't file what's faster to do:** if it takes ≲5 minutes, the context is already in hand, and
  it's safe to do now — just do it. An entry costs more than the fix; file only genuine deferrals.
- **Resolving an item:** move it to [`follow-ups-archive.md`](follow-ups-archive.md) in the same
  commit as the fix, trimmed to the grep residue (what shipped / when / acceptance evidence /
  gotcha — a few lines) with an *(archived YYYY-MM-DD)* stamp. References elsewhere stay legal
  while the id is archived; when the entry expires out of the archive (≈a month, once stable),
  delete it and scrub remaining references in living code/docs — TICK-LOG/ADR/incident references
  are historical and exempt. **Scrubbing a pointer item's id = repointing, not deleting**: the
  code/doc comment loses the `FU-NNN` but gains a link to the doc that survived, so the trail
  doesn't go cold. `devbox run follow-ups-lint` checks all of this.
  **Check for this actively:** FU-080 sat open at 91 lines with zero remaining work because its
  last leg was archived under a different id. A long item is a good place to look for a done one.
- **Adding an item:** next free id, into the fitting theme section (ids don't encode theme), bump
  the counter above.
- **Single-writer contract (2026-07-10):** this file is operator/meta-edited ONLY — agents never
  append here. The sequential ids + the counter line make it a guaranteed merge conflict under
  parallel writers, and it doesn't scale past platform loose-ends anyway. Agent-discovered
  shortfalls go to the governing repo's `specs/` as id-free `⚑ gap` flags (ADR-086, oracle-fleet
  ADR-OF-003); coordinator session findings go to the TICK-LOG.

_Last updated: 2026-08-02 (pointer-discipline pass: 1033 → 433 lines, no information lost — detail
moved to `docs/incidents/`, `docs/storage-ledger.md`, `docs/agents/*`, `ROADMAP.md`; lint now in `ci`)._

## Secrets (the "secret cleanup" track)

- [ ] **FU-005** — Decide whether an Infisical break-glass second admin is worth codifying (one
      super admin today, signups disabled).

## GitOps & platform

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
- [ ] **FU-012** — Remote/encrypted tofu state backend (every root is local, gitignored state).
- [ ] **FU-013** — Home Assistant `/config` (and other stateful data) backup → Garage S3 with the
      bucket-id in git — the missing "boot-from-git" DR leg (Longhorn replicates in-cluster, it
      doesn't DR). `tofu/homeassistant.tf`.
- [ ] **FU-039** — **Next leg of platform self-service: make per-stack subdomain opt-in an XRD
      claim.** Today it's a thin homelab PR once per stack (the HTTPS-names leg itself shipped —
      ADR-092). Then the two remaining legs — **git repos** and **ArgoCD AppProject/namespace** —
      both still operator PRs against `tofu/github` + `argocd/platform`; decide per resource:
      Crossplane provider vs a thin homelab PR seam. Program context:
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
- [ ] **FU-070** — **`stack-template` org repo — collapse new-stack's step E (main-repo content).**
      The one onboarding step still done by copying oracle-fleet's shapes by hand: CLAUDE.md
      skeleton (read order / gate / invariants / related-repos-as-GitHub-URLs), `.agents/` recipe
      skeletons, devbox `ci`+`scan-secrets`, merge-path caller workflows. Make it a template repo
      (`is_template = true` in repos.tf), instantiate via `gh repo create --template` before
      `new-agent-repo.sh` (which then emits the adopt-import). stack-lint's REPO-03/04/05 already
      verify the result. Relates FU-052.
- [ ] **FU-016** — SLSA Phase-1: cosign signing + SBOM + scan on the hosted runners (both tiers).
      Plan: `docs/slsa.md`.
- [ ] **FU-017** — Merge the two runner GitHub Apps (`homelab-arc-…` + `homelab-runner-registrar`)
      — both need only org self-hosted-runners R/W. `docs/github-setup.md` §2.

## Agents


- [ ] **FU-108** — **Replace the exporter's Search-API call — the queue-liveness gauge is blind
      to private repos.** `collect_agent_issues()` uses `/search/issues`, and the REST Search API
      **silently omits private-repo results** under the fine-grained PAT: no error, `errors_total`
      untouched, poll reports "fully successful". 30d history confirms `github_agent_issue_labels`
      has NEVER emitted a series for oracle-fleet or sleep-tracking, so `AgentQueueStalled` has
      only ever watched the public repos. **Fix:** drop search; count `agent/*` labels from a
      per-repo source the PAT already reads — cheapest is `labels(first:…)` on the existing GraphQL
      walk (0 extra calls), else per-repo REST (~10 calls/poll). **Verify:** private-repo counts
      appear within one poll. Same class as FU-063 (archived). Relates FU-091.
- [ ] **FU-111** — **Migrate `Depends-on:` body lines to native GitHub issue dependencies
      (`blockedBy`).** The body-line idiom is regex-over-prose and its reader already broke once
      (the tab-IFS collapse — the FU-087 gate silently dead for track-less issues); `blockedBy` is
      structured state GitHub maintains, is UI-visible, and rides the SAME `gh issue list --json`
      call the scan already makes (zero extra API cost, field list measured).
      **Verify FIRST — the FU-108 probe-that-looks lesson:** (a) the field POPULATES under the App
      installation token (read a known dependency; don't trust an empty-but-200); (b) cross-repo
      edges work (sleep-iac#25 → sleep-tracking#48 is the live case); (c) the issue-authoring lane
      can CREATE edges, so the API call replaces the body line with no dual-format drift.
      Principle: **the scheduler consumes semantics, not decorations** — blocking = native deps,
      grouping = milestones/sub-issues (FU-090). Relates FU-086, FU-087/FU-110 (archived).
- [ ] **FU-112** — **Platform-pod OOM posture: nothing platform-critical should be BestEffort.**
      Both legs of the 2026-07-27/28 cascade are fixed (launcher requests=limits; Talos kata-node
      kubelet reservation, 4a9e9a9) — full postmortem:
      [`docs/incidents/2026-07-27-kata-ride-oom-cascade.md`](incidents/2026-07-27-kata-ride-oom-cascade.md).
      **Residual only:** the `engine-image` DaemonSet still has no `priorityClass` (BestEffort),
      against the operator's "agents must not be able to kill cilium" ruling. Trivially restartable
      and non-cascading, hence deferred. Relates FU-082 (archived), FU-081, FU-072, FU-116.
- [ ] **FU-113** — **Any non-triaging respond must write a ledger marker; the responder must not
      trust the alert edge to refire.** Postmortem (both the latch-defer drop and the three
      look-alike silent outcomes):
      [`docs/incidents/2026-07-27-responder-silent-defer.md`](incidents/2026-07-27-responder-silent-defer.md).
      Build: (a) marker on every outcome — `deferred` / `cap-deferred` / `seen-noop`; (b) self-requeue
      (Argo retry/backoff or resubmit-on-defer) instead of trusting the edge; (c) key the daily cap
      off INCIDENT (route+root), not raw fingerprint count. FU-109's tiering composes with (c).
      Relates FU-088 (archived), FU-109, FU-103 (archived).


- [ ] **FU-115** — **Immediate no-op detection on the red merge path** — same head across a
      completed round should escalate to `agent/arbitrate` NOW, not after the full `RED_ROUNDS_MAX`
      cap; needs a dispatch-time `@head` marker. The attempt-cap is the v1 bound.
      The red loop's edge + escalation shipped 2026-07-28 (exporter `maybe_dispatch_cired`,
      content-based capped `ci-red` scan clause, MP-T12 rewrite + MP-T13 Red→arbitrate) —
      transitions in [`docs/agents/merge-path-fsm.yaml`](agents/merge-path-fsm.yaml), play in the
      coordinator README. Relates MP-T07/T11/T12/T13.


- [ ] **FU-117** — **Dedup the context-delivery spread into one role × context × source map.**
      DELIBERATE let-it-pile-up item (operator style: grow organically, then analyse + refactor —
      not BDUF). **Do NOT refactor yet** — keep noting sightings in
      [`docs/agents/roles.md`](agents/roles.md) §"Context delivery", which holds the root finding
      (goose never loads CLAUDE.md), the three context classes, the costs already paid, and the
      boundary a worker must respect. Interim duplication into `render_env_card()` is accepted on
      purpose 2026-07-28; this item tracks removing it. Relates FU-114, ADR-094.

- [ ] **FU-120** — **`agent-finalize` PATH-loss root cause unconfirmed (belt shipped, now masking
      it).** The launcher pins `PATH=/opt/agent/.devbox/nix/profile/default/bin` on the finalize call
      (2026-07-31), so bookkeeping can't be lost to this class again; the #71-r2 crash itself is
      unreproducible (no transcript → pod log gone). Postmortem + the wrong original diagnosis:
      [`docs/incidents/2026-07-29-agent-finalize-bookkeeping.md`](incidents/2026-07-29-agent-finalize-bookkeeping.md).
      **Action:** none unless a NON-finalize symptom of the same PATH/mount loss appears — then dig.
      Relates ADR-096 (§Addendum 3), FU-062, FU-116, FU-123.

- [ ] **FU-121** — **`liveness≠progress` redispatch races a closing issue → a spurious round on a
      just-solved item.** On #71's close (2026-07-29 07:12Z) a `coordinate-sleep` scan saw #71
      `agent/in-progress` with r8's pod already gone (the liveness≠progress redispatch clause) and fired
      **r9** BEFORE the merge/close propagated — a wasted round re-running CI on the already-merged kind
      migration; the operator killed it by hand. The redispatch decision doesn't re-check the
      issue-closed / PR-merged state atomically at dispatch time. FIX: gate the liveness-redispatch on a
      fresh closed/merged probe (or a short debounce after the pod vanishes) so a terminal pod near a close
      can't manufacture in-progress work. Relates ADR-094 (coordinate dispatch / C4-C5 re-dispatch),
      FU-085 (doorbell), the meta-16 bounded-drain lesson.


- [ ] **FU-124** — **Give the PR updater a reliable in-cluster trigger — GitHub's `*/15` cron is the
      last PR's sole backstop and GitHub drops it.** Verified live: sleep-tracking#100 hung
      `BEHIND/APPROVED` ~1h; a manual dispatch merged it immediately (logic fine, trigger failed).
      Postmortem: [`docs/incidents/2026-07-31-last-pr-behind-hang.md`](incidents/2026-07-31-last-pr-behind-hang.md).
      **Build:** the coordinate scan already reads `mergeStateStatus` — have it
      `gh workflow run update-pr-branch.yml` on an armed PR stuck BEHIND with no updater progress.
      **Belt:** meta-watch check for an armed PR BEHIND >~15min (it watches CI-fail + merge, not
      updater liveness). Relates FU-041, ADR-093, merge-path-fsm MP-T02.

- [ ] **FU-102** — **Prober role: the agentic canary** (meta-11: a manually-run agentic probe was
      the ONLY detector of a 13h Ready-but-dead prod outage; it also finds product gaps — the
      lyhend-only resolution catch, 🌱#160). Brief exists (oracle probe-e2e/UC-1); missing =
      activation machinery: predicate = post-deploy + schedule; edge = deploy doorbell; backstop
      = cron; key = (endpoint, artifact digest); boundary = prod-read + report-only, $1 ephemeral
      keys (meta-11-proven cell); breaker = inert 🌱 issues (loop-safety #1) + rate cap.
      Detection belts stack: FU-099 blackbox (seconds, dumb) → prober (minutes, contract-deep)
      → FU-103 responder. Composes with FU-044 as its deep post-deploy gate. `roles.md`.


- [ ] **FU-106** — **Build out the -iac lane: close the IAC-G01..G06 gap register.** The role,
      the doctrine, the rollout matrix and the build order live in
      [`docs/agents/iac-lane.md`](agents/iac-lane.md) (+ `iac-lane-fsm.yaml`, lint-checked like the
      app FSM); the detector + `infra-enrich` dispatch class shipped 2026-07-27 with a first live
      dispatch merged.
      **Open:** ⚠ **IAC-G01, the review-gate hole** — an `-iac` worker can rewrite its own CI gate
      and instant-merge unreviewed (sleep-iac#28 self-merged 38s after open, touching
      `.github/workflows/`); it closes via the G04 policy sentinel, not review. Then the rest of the
      register in the doc's suggested order. **Operator directive 2026-08-02: steady-state -iac work
      is the STACK's lane, not the jail's** (jail/meta = first-time bootstrap only — "it will burn
      me out otherwise when I add more stacks") → the oracle-iac twin is now WANTED, not optional:
      fixer block on oracle's claim + the platform ns precreation, sleep-iac's FU-106 shape
      (oracle-iac#97 currently has NO lane).
      Window is bounded meanwhile (sleep-iac#25 is the only queued -iac item, Depends-on-held).
      Relates FU-086/FU-087/FU-093, ADR-084, ADR-076.
- [ ] **FU-086** — **Item-scoped dispatch: the four remaining knobs.** Core shipped + E2E-verified
      2026-07-17 (scan emits `(clause, repo, item)` units, `--spawn` dispatches the single
      highest-priority one, WIP=1 kept); arbitrate + `ci-red-stale` shipped 2026-07-27, closing
      MP-G01/G04 — the merge-path FSM gap register is empty. Decision + mechanism: **ADR-094**;
      the scan's scheduling predicates and the unit taxonomy live there and in
      [`docs/agents/workflow.md`](agents/workflow.md).
      **Still open:** (1) the FU-085 compound — the Sensor submits item units directly and the cron
      sweep emits only MISSED units; (2) relax the coordinator cron `*/10 → */30` (edge proven
      through meta-9/10; the github-exporter's CI metrics carry the out-of-band half);
      (3) lift WIP>1 for lane-parallel dispatch (the FU-088 capacity gates are in);
      (4) demote the janitor tick to its own cron — keep it ~daily and report-only, for
      board-level judgment (direction-change sweeps, orphans, cross-PR smells).
      Relates FU-050, FU-085, ADR-094, oracle-fleet `specs/TRACKS.md`.
- [ ] **FU-094** — **Tiered spec gate — PROPOSAL ONLY (operator 2026-07-24: "will consider
      once I have more data and cleaned up the specs").** Write-up:
      `docs/agents/spec-gate-tiering.md`. Kernel: meta-9 measured 16 codeowner spec gates/72h
      with 0 rejections — the gate's value migrated to issue-time ⚖ pre-decision; ~half the
      gates were mechanical diffs (marker flips, event-list syncs, provenance notes). Do NOT
      implement before the operator re-opens this.
- [ ] **FU-093** — **One ledger must own each storage tier's committed sum, and something must
      meter it.** ADR-089 gives every claim a cap but nobody the total — the bulk tier was
      double-booked, and four sightings in six days confirm a breach is invisible until a workload
      fails. Ledger, the double-book, all four sightings and the build list:
      [`docs/storage-ledger.md`](storage-ledger.md).
      **Next:** the per-tier ledger (doc table or a lint summing `max_size` vs tier budget), then
      Garage admin-API metrics + ServiceMonitor and Longhorn per-disk `storageScheduled`, each with
      a >80% alert. Blocks the FU-106 "mechanical" predicate. Relates ADR-089, FU-116.

- [ ] **FU-090** — **Build the sprout index: structure harvest lineage as GitHub sub-issues.**
      Design (all three legs, the breaker-#1 gate, the sprout-index rungs and the retro-checkpoint
      terminal): [`docs/agents/issue-authoring.md`](agents/issue-authoring.md).
      **Shipped:** leg (a) harvest + the `merged-closeout` scan clause (2026-07-27); the 🌱
      visibility slice (07-18); the prompt-only down-payment — reviewer complete-the-fix case +
      HARVEST BAR (07-31). **Next rung:** the structured sub-issue lineage — the index the
      depth-aware harvest gate and the sprout-RATE gauge both key off. **Deferred by the operator:**
      leg (c) goal-budget decomposition, and the `issueAuthoring.selfQueue` graduation knob.
      Relates FU-086/FU-087, FU-044, FU-111, ADR-094, TICK-LOG §Loop safety.
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
- [ ] **FU-019** — Migrate the worker plain `Pod` → agent-sandbox `Sandbox` CR (ADR-078).
      `agents/agent-session.sh`.
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
- [ ] **FU-058** — **Retro P3: unsuspend the scheduled retro session.** Design, the multi-model
      pilot, runs 1+2 results and the run-3 shape:
      [`docs/agents/observability-and-retro.md`](agents/observability-and-retro.md) §B2. Cron
      exists (`agents/coordinator/retro-argo.yaml`, **born SUSPENDED** — Mon 05:00 declared,
      hand-fired via `argo submit --from` until proven).
      **Remaining:** (1) run 3 (the swapped-cell cross-review) hand-supervised; (2) fix the ledger
      emitter gaps brief-v2(b) named — they, not tool access, are why reports say "could not
      verify"; (3) MCP transcript slices; (4) act on the reports' queued-issue candidates;
      (5) unsuspend after clean runs. Absorbs FU-057's residue: ledger-reflex consuming `key_hash`
      for the OpenRouter activity-API per-request backfill. Relates FU-095.

- [ ] **FU-059** — **W1 DECIDED + built (2026-07-10, ADR-086): coordinator commits ⚑ spec gap-flags
      to open agent PR branches during merge-forward arbitration (record-in-git; issues = work
      pointers only). Remaining scope = W2+ (direct fixes/seeds), still needs design.** Original:
      **Coordinator write tiers (W1/W2) — needs its own ADR first.** Today the coordinator's
      stack-repo clones (`/work/<repo>`, landed with the FU-045 first brick) are **read-only reference**: its
      only writes are labels/comments/merge-state via `gh`. A future tier could let the coordinator write
      *directly* to a stack repo (open a PR from the clone, push a trivial fix, seed a spec) instead of always
      dispatching a worker — but that blurs the coordinator(orchestrator) vs worker(builder) split and touches
      budget/credential/review-gate assumptions, so it must be designed in an ADR before any code. Relates
      FU-045/FU-048 (the `AgentStack` claim would carry the tier as policy) and the merge-path reflexes.

- [ ] **FU-044** — **Roll-FORWARD on a broken deploy — the remaining LLM half.** The deterministic
      rollback shipped 2026-07-27 (argocd-notifications → `/deploy-degraded` → `deploy-revert`
      Sensor/Workflow, no LLM); what's left is dispatching a worker against the APP repo to fix the
      breakage, in-cluster off ArgoCD app-health events (never in the Actions deploy run). Design +
      why ArgoCD health is only a shallow gate (the meta-11 schema-skew outage stayed GREEN):
      [`docs/agents/iac-lane.md`](agents/iac-lane.md) §"ArgoCD health is NOT the post-deploy gate".
      Deep acceptance stays the FU-102 prober. Operator prereq in flight: harden app CI so prod
      breakages are rare — rollback is the safety net, not the primary control. Relates FU-041,
      FU-102, FU-090 (lineage-scoped revert).
- [ ] **FU-049** — **Platform services published as XRDs supersede `SERVICES.md` as the source of truth.**
      Provisionable capabilities (S3/Postgres/…) become typed Crossplane XRDs; discovery is a cluster query
      (`kubectl get xrd`) and the human catalog is *generated* from them rather than hand-curated. Open:
      build-time discovery for an app repo with no cluster creds may still want a generated static catalog.
      **Inherited from FU-107 (2026-07-27), same generation class:** agentstack.md's "what a claim
      renders" table generated from the XRD/Composition, and the stacks-state table from
      `kubectl get agentstacks` (plus `agents/stacks.json` itself — the original mirror problem).
      Design: [`docs/agents/platform-and-stacks.md`](agents/platform-and-stacks.md) §2, ADR-085. Relates
      [[service-discovery]], ADR-076 (app-owned resources via Crossplane).

- [ ] **FU-046** — **Prove the reviewable-dep-bump path E2E on a real major bump.** The split is
      decided and built — `automerge` = mechanical CI-only approval, `deps-review`/major = the LLM
      review path ([`docs/agents/merge-path.md`](agents/merge-path.md) §Decisions + §"Coordinator ×
      Renovate PRs"); reflex skips `automerge`, `rebaseWhen: conflicted` set (updater owns freshness).
      **Unproven and awaiting a real reviewable bump:** an armed `deps-review` PR flowing through
      the **review reflex** (not the coordinator) → CHANGES_REQUESTED → a worker adapting on the
      **`renovate/*` branch** → loop → merge. Verify specifically that **Renovate leaves a
      manually-edited branch alone** and the worker pushes to `renovate/*`, not a new `agent/*`.
      Keep open until one flies. **P3 (later):** a longer cooldown on majors so a human CAN opt into
      an interactive session for the riskiest. Relates FU-041, FU-044, FU-014.
- [ ] **FU-068** — **Decide homelab's own claim home so `labels.tf` can die.** The Issues-tier
      split shipped 2026-07-16 and eight repos across all three stacks are claim-owned; homelab is
      the only holdout, and `label_repos=[homelab]` keeps `labels.tf` alive for it alone. Mechanism,
      migration state and the live gotchas:
      [`docs/agents/agentstack.md`](agents/agentstack.md) §"The GitHub side" + §Operational notes.
      ⚠ The generated `github_issue_labels` is AUTHORITATIVE — it deletes unmanaged labels, so two
      managers fight; a state `rm` must be scoped to `^github_issue_label\.` ONLY (a broad grep also
      matches rulesets). Relates FU-048, ADR-085.

- [ ] **FU-095** — **Sleep stack pilots: task-class model routing + multi-harness evidence.**
      Design, operator corrections, legs (a)/(b)/(c), buy-vs-build:
      [`docs/agents/model-routing.md`](agents/model-routing.md) §"The sleep-stack pilots". Leg
      (a)'s substrate is **ADR-096** (detail there): P1–P2 shipped 2026-07-27/08-02; **P3+P5 +
      the addendum-4 cooldown/recovery leg shipped 2026-08-02** (`POST /route` live,
      launcher consult AGENT_ROUTER=shadow default, rotation-fed candidates). Remaining: the
      P4 authoritative flip after the shadow soak. **Open here:** legs (b)+(c) unstarted.
      ⚠ P1 coverage gap: `/report` posts from the LAUNCHER finalizer only — coordinator-path
      rides need the in-pod `agent-finalize` twin (agent-runtime; do with P3 for honest shadow
      coverage). Relates ADR-077, ADR-081, ADR-096, FU-044, FU-046, FU-057, FU-062, FU-105.

## Hardware & nodes

- [ ] **FU-032** — Watch: thinkcentre's one 1Gbps link blip since the cable fix (2026-06-11) and
      wk-metal-02's one unexplained reboot. On recurrence: chase cable/switch-port
      (thinkcentre) resp. battery/power (wk-metal-02, plug `laptop4`).
- [ ] **FU-033** — Before any Talos 1.14 upgrade: apply the `VolumeConfig secure:false` /
      `noexec` patch or `/var` breaks Longhorn v1 (warning in `tofu/longhorn.tf`).
- [ ] **FU-034** — Buy a network Zigbee coordinator (SLZB-06 class) — unblocks local radios
      (ADR-041, Open).

## One-time ops

- [ ] **FU-036** — AWS cleanup: delete the orphaned Route53 hosted zone `ZCGRPARGVE3CW` (+ the
      leftover ACM/Sectigo certs its `_*` validation records imply). Needs admin SSO (the jail key
      is read-only). Recipe: `docs/cloudflare.md`. Optionally do it as the first `tofu/aws/` root
      (which would also adopt the audit user, `scripts/aws-bootstrap-audit-user.sh`).
- [ ] **FU-038** — Tuya plugs: drop the cloud dependency for local-API polling, which also kills
      the `/10` power correction (`homeassistant/ha-config/packages/power.yaml`). DIRECTION
      (investigated 2026-07-28): standardize on HA-local WiFi plugs via `make-all/tuya-local` (or
      the `xZetsubou/hass-localtuya` fork) — one-time `device_id`+`local_key` extraction (free Tuya
      IoT project / `tinytuya wizard`), then pure LAN polling, no soldering, true-unit DPs.
      Reflashing to ESPHome-LibreTiny / OpenBeken (BK7231) stays an OPTIONAL per-device upgrade.
      Same path for the 2 new metal nodes — buy cheap WiFi metering plugs (SonOff via SonoffLAN or
      Matter, or Tuya via tuya-local; block cloud egress at OPNsense), NOT the FU-034 Zigbee
      coordinator.
---

See also `ROADMAP.md` → "Backlog / parked features" (self-hosted SLSA L3 build-out, bare-metal node
suspend/resume, the caching-tier image mirror ADR-070, the edge tier).
