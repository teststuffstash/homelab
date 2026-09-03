# Follow-ups (the FU tracker)

Running list of loose ends and deferred work — the stuff intentionally not finished yet. Bigger
parked *features* live in `ROADMAP.md` → "Backlog / parked features"; this file is the operational
tracker.

**Conventions (the contract):**

- Every item has a stable id **`FU-NNN`** (3 digits, sequential, **never reused**).
  Next free id: **FU-207** (the counter lagged a FOURTH time — FU-200/FU-201 minted 2026-09-01 while it read 200; before that FU-190..194 / FU-183/FU-185). Burned ids (issued, then retracted without ever being work) are declared
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

- [ ] **FU-206** — **PublicRoute: block operational paths at the edge by default (ADR-123).**
      Every claim serves its backend's `/metrics` + `/healthz` publicly today — the gateway answers
      them before auth, the tunnel forwards the whole hostname (seen at the oracle-iac#532
      pre-merge read, 2026-09-03). Deferred: ruled after the api-profile fix (PR#1357) had landed
      and #532 was merging. **Next:** the composition renders one more rule in the claim's
      `http_request_firewall_custom` ruleset for BOTH profiles (structured 403; default path list
      `/metrics`, `/healthz`; a per-path opt-in claim field — name clears the glossary), dry-run
      through cf-api-proxy first ([`docs/cloudflare.md`](cloudflare.md) gotcha 6); product zones
      only until zone-phase aggregation (teststuff.net = FU-039's leg). Link: cloudflare.md
      §PublicRoute completion table.

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

- [ ] **FU-203** — **The first-party registry has no retention** (2026-09-02, born with ADR-121 —
      the "keep 2 latest prod releases + latest built" policy is the reason v1 exists, but v1
      ships without it). Bucket `registry` capped 20Gi ≈ 3 corpus releases; the ert delta cron is
      suspended so manual releases + manual pruning hold, but the cap is load-bearing the week
      the weekly cadence un-suspends. Next: a tag-aware prune job (list tags → keep policy set →
      DELETE manifests + `registry garbage-collect` — deletes work here, it's not a proxy) as a
      CronJob in `argocd/resources/registry/`; wire `devbox run storage-ledger` to count the
      bucket. Link: ADR-121, FU-196.

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

- [ ] **FU-195** — **Alertmanager silences do not survive a pod restart** — the `…-alertmanager-db`
      volume (nflog + silences) is a bare emptyDir, no volumeClaimTemplate. Found 2026-08-30: the
      2026-08-25 17:31Z restart silently wiped both S7 silences (`a3628730` — moot, callers since
      disabled at source; `5400ed94` — the #698 minutes mute, which let `GithubActionsMinutesHigh`
      re-fire days early; re-created as `1ac4049c` to 09-01). Why deferred: storage needs a values
      change + rollout on the monitoring stack, not a quickfix. **Next:** add
      `alertmanagerSpec.storage` (small Longhorn PVC) in `kube-prometheus-stack.yaml` values, or
      rule that silences are ephemeral-by-design and belt-worthy mutes must be PrometheusRule
      changes instead.

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

- [ ] **FU-137** — **Garage durability: POINTER.** The risk fired 2026-08-24 — meta LMDB wiped
      in the pve thin-pool incident, Aug-4 backup restored same day
      ([incident](incidents/2026-08-24-pve-thin-pool-garage-meta-wipe.md), homelab#884).
      **ADR-114** (2026-08-24) answers it: rf=3 across physical zones, engines-replicate/
      storage-stores-singles, backup = logical-deletion CronJob — design, grounding links,
      history: [`docs/garage.md`](garage.md) §Durability + §Target architecture.
      **Next (oracle-prod-deadline-bound, ~2026-08-31):** the build-out — garage rf=3 migration
      (local XFS, wk-metal-01/04 + wk-02 interim), CNPG replica-1 + required zone anti-affinity,
      backup CronJob. Offsite stays parked behind oracle/idp prod. Relates FU-013, FU-012, ADR-031.
      ⚠ meta volume is **1 replica (wk-02)**; the "no `std` disk fits a 2nd" blocker LIFTED 08-25 — the rebuild left it at 6%.
- [ ] **FU-076** — **Re-check the metal reinstall mystery on the next metal (re)install**: a
      maintenance-mode reinstall of wk-metal-03 applied config verifiably carrying the
      metal_kata installer URL yet produced the plain-metal schematic (fixed via `talosctl
      upgrade`; likely also the origin of the kata `/dev/kmsg` regression, see
      `docs/spikes/kata-ci-gate.md`). Verify install.image is honored from maintenance mode.
- [ ] **FU-072** — **Root-cause why kata pods can't reach `10.96.x` service VIPs** (runc pods on
      the same node can). Symptom matrix, what's ruled out, and the next probes:
      [`docs/spikes/kata-service-vip.md`](spikes/kata-service-vip.md). Workaround in place (kata
      CI-gate pods use `dnsPolicy: None` + the LAN resolver) — fine for k3d/registry work, blocks
      in-cluster consumers like Garage transcript upload. **⚠ 2026-08-26: the workaround's
      dispatch-time endpoint-IP rewrite goes stale when the proxy rolls mid-ride and black-holes
      the ride's LLM rail** (issue-272-r1 slept to the 4h deadline; evidence in the spike doc) —
      root-causing this, or a headless-Service name, closes that too. **2026-09-03 re-probe: the
      symptom is GONE on all four kata nodes** (kata+runc pairs, TCP + UDP VIPs — spike doc
      §Re-probe); 355-r5 + 387-r3 were meanwhile black-holed by exactly this rewrite (proxy
      rolled 12:26 on PR#1351). **Next:** delete `resolve_ep` + the rewrites in
      `agents/agent-session.sh` and the `dnsPolicy: None` leg (PR lane). Relates FU-116, FU-187.
- [ ] **FU-007** — **ArgoCD → Forgejo cutover** (offline-resilience goal). Prereq: mirror **homelab**
      itself into Forgejo — ⚠ the `sleep-lab` pull-mirrors are **BROKEN since the 2026-08-04 DB
      migration** (`SyncMirrors` failing; fix = the idp session's orphaned-repo recipe: remove dir on
      the git volume, recreate via API + wallet password). **2026-09-02: second consumer** — the
      loop's deterministic workflow clones (~700/day × ~12MB, 9 manifests, `_cu` since homelab#1136)
      ride WAN to GitHub. Operator ruling: pull-mirroring = backup-grade, NOT live consumption
      (≈6h stale); the live path is a **push-mirror step in `sync.yaml`** on master push
      (in-cluster runner, seconds-fresh), pull interval = missed-push belt. ⚠ NO build yet — the
      primary-git-location flip has side effects the operator is weighing. Next: repair mirrors +
      verify a sync; cutover per `argocd/README.md` §Forgejo cutover; loop clone-URL flip on
      go-ahead. **2026-09-03:** the loop's clones were anonymous-FIRST (2 anon requests each,
      token-in-URL) — PR#1333 moved every site to preemptive `http.extraHeader` auth; a recurrence
      with zero anonymous requests is the trigger that makes the push-mirror the next deliverable.
- [ ] **FU-010** — Infisical↔CNPG uses `sslmode=disable` (node-pg rejects CNPG's self-signed
      cert). Fine pod-to-pod; revisit if Cilium transparent encryption lands.
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
      product zones, the edge-metrics GraphQL poller whose FIRST deliverable is the replacement
      edge-5xx belt — none exists since #350/#363): [`docs/cloudflare.md`](cloudflare.md)
      §PublicRoute + §Observability. Still thin homelab PRs per stack: LAN subdomain opt-in
      (ADR-092), git repos, AppProject/ns. **Next:** zone-phase ruleset aggregation (one claim per
      profile per zone today) and the ha retrofit as consumer #2 — the first consumers are live and
      checked (cloudflare.md completion table, homelab#1334).
      Program: `ROADMAP.md` → "Platform self-service via Crossplane".
      Relates ADR-076, ADR-085, ADR-092, ADR-101.
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
- [ ] **FU-125** — **Renovate silently REGRESSED to zero dependency PRs — while reporting
      success** (measured 2026-08-01: all 10 autodiscovered repos abort; same silent-success
      class as FU-108/FU-113). Evidence + inventory:
      [`docs/dependency-upgrades.md`](dependency-upgrades.md) §"Ground truth".
      **Next:** absorbed into the Renovate Goal — homelab#502, closed back into the ROADMAP
      work map (row G-D; its body is the launch draft). Acceptance items there: App permission
      diff, liveness gauge, prPriority + `NIX_VERSION` hygiene, the pin-dependencies branch.
      `dependencyDashboard: false` by ruling 2026-08-18 (liveness = the exporter gauge ONLY).
      This item closes when that Goal launches and validates. Relates FU-046, FU-097, FU-016.
- [ ] **FU-097** — **Write the per-surface ruling table for the surfaces ArgoCD/tofu don't
      reconcile** (OPNsense, Proxmox host, Home Assistant, Matchbox, `tofu/` roots): automate, or
      human-applied + a named drift belt. That table is the first deliverable; then implement the
      automated ones one surface at a time. Surfaces + candidate shapes:
      `ROADMAP.md` → Programs in flight → "Deploy paths"; per-root tofu split + the runner
      dependency-cone rule: [`docs/dependency-upgrades.md`](dependency-upgrades.md); the no-human
      end-state (what stays human-gated and why):
      [`docs/spikes/no-human-in-the-loop.md`](spikes/no-human-in-the-loop.md).
      Relates FU-051, FU-012, ADR-093 (Argo as the candidate runner for the ansible Jobs).
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
      attempt-count auto-escalation (banked, feed-4). Relates FU-174, FU-186, ADR-094/096/115.

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
      the next mover" is reported and no human is told. **Next:** hold-narrowing = #1203/PR#1206
      merged; residue = honest strike-held rows + hold-chain propagation + the CAP SPLIT
      (v1.3.1 delta 1, homelab#887) + the fingerprint faces (their own scan issue, filed
      2026-09-03). Relates FU-187, FU-143, FU-147.

- [ ] **FU-200** — **The brief's fleet-strike rule has no deterministic reader.** "Same
      `error_class=` in `AGENT_STRIKE:` comments on ≥2 distinct issues inside 24h ⇒ ONE
      `AGENT_ERROR` + one filed platform issue" (coordinator README, retro r4 F2) is a prose
      play executed only if one session happens to see both issues — item sessions see one.
      2026-09-01: FOUR goal-#326 r1 strikes with identical `error_class=unknown`
      (oracle-fleet#328/#329×2/#330; three = homelab#1186, one open) were never correlated —
      the operator + seat did it by hand via #330's triage. Prose-warned classes recur,
      executable gates hold (ADR-103). **Next:** a scan-side fleet-window count (the scan
      already greps `AGENT_STRIKE:` per issue for the chain-walk) emitting the breaker +
      filing per the brief's contract; same surface as the #1163 scan theme. Relates FU-199,
      agent-runtime#85 (the `unknown` classifier), model-routing §M1a (strike store).

### Merge path, CI & deploys — reviewer, auto-merge, first-party bumps, the gates

- [ ] **FU-197** — **manifest-lint fetches every kubeconform schema from raw.githubusercontent.com
      on each CI run — uncached, so a GitHub-raw hiccup reds the required check.** Bit PR#1099
      (2026-08-31): the runner got HTTP 400 on a schema fetch (a guaranteed-404 kustomization
      lookup; the jail saw 404 for the same URL) and kubeconform hard-failed the lint. The
      kustomization class is excluded now (`manifest-lint.sh`, same commit), but every REAL schema
      fetch (~101/run) still rides the public internet with no mirror — unlike images (ghcr/MCR
      mirrors) and nix (shared /nix). **Next:** vendor the used schema set into the repo (or bake a
      `-schema-location` cache into the warm ARC runner volume) so the lint is hermetic; grep
      showed no existing FU/ADR covers schema caching (FU-144 is the schema-BLIND-kinds half).
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
      instrument, shipped PR#963). **Next:** step 1 — the `provider_policy` class knob + the
      no-pin/Exacto flip, then the 0731 matrix run (step 2) whose verdict is the model_tiers
      re-admission PR. Relates ADR-115, ADR-096 §M4/M8, FU-095, homelab#966 (intake digest),
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
      reshape. Relates FU-095, ADR-096.
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

- [ ] **FU-198** — **No belt sees an Argo lock-plane wedge: the sync manager's in-memory
      state can corrupt under a fast-failure storm and Pending then piles up silently**
      (2026-08-31, operator-spotted: waiters told "5/5" against a provably empty semaphore
      for 65+ min after the #1136 exit-128 storm; controller restart drained it in minutes).
      Postmortem + belt audit + evidence + the storm→wedge trigger note:
      [`incidents/2026-08-31-argo-semaphore-leak.md`](incidents/2026-08-31-argo-semaphore-leak.md).
      **Next:** an alert on the wedge shape — Argo Pending high-and-not-draining while
      `anthropic_subscription_semaphore_running` ≈ 0 — into `argo-workflows-alerts` with
      promtool cover; check upstream sync-manager fixes (`v4.0.7` today) before any bump.
      Relates FU-187 (sibling belt-blindness).

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
      api_error → `/report` ⇒ strike (d) zero-output belt. **Pin LIVE** (reviewer
      authoritative→shadow, grep FU-188); out with (a)+(b). Absorbs PR#991's literal + the
      AVX2 pin as rows at build. Next: schema design pass, then issue tree.

- [ ] **FU-164** — **doc-heat: transcript-derived read heat over repo markdown — POINTER.**
      Question, heat doctrine (heat × class × age; blind spots; approximate lines), v0 (jail
      parser + static report, `devbox run doc-heat`) and the serving plan:
      [`docs/spikes/doc-heat.md`](spikes/doc-heat.md). **PROMOTED 2026-08-30** (operator —
      settle bar met by run 1): standing docs-cleanup input, wired into the skill's comb step.
      **Next: the first post-S5 heat read, due ~2026-09-06** (a week's fresh transcripts —
      pre-S5 heat describes text the comb rewrote); then the v1 cluster leg
      (`s3://agent-transcripts`, path normalization, jail/cluster separate + combined views —
      operator requirement), which also delivers context-repos.md's overdue measurement sweep.
      Relates FU-058.

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

### Roles & platform capabilities — new lanes, sandboxes, context delivery

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
      metering 2026-08-04, the ADR-089 quota arming 2026-08-07, the 08-24 third-100% incident)
      and status detail: [`docs/storage-ledger.md`](storage-ledger.md). Garage metrics leg
      SHIPPED by the machine lane (#934 → #965, 2026-08-25/26 — belts live, defect tail
      #977/#978 riding); pve fstrim SCHEDULED (PR#925 daily
      CronJob, first run 78.72%→62.99%). **Next:** the pve thin-pool Data% metric + alert (the
      pool ITSELF is still unmetered — the new belts prove the trim runs, not that it
      suffices); then a Longhorn `filesystem-trim` RecurringJob (node fstrim cannot reclaim
      inside replica sparse files); ci-runner-01's own fstrim.timer is assumed-not-verified.
      Relates ADR-089, ADR-114, homelab#934.

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
- [ ] **FU-155** — **PSI-stall shared-fate kills RECUR on hardened nodes: POINTER.** Mechanism,
      evidence (the broken cadence premise, the 2026-08-17 victim-surface shrink, the 08-24
      service-tier recurrence + pre-upgrade `oomactions` capture, cilium-agent's residual
      exposure) and the ⚖ recommendation: [`docs/spikes/talos-psi-thresholds.md`](spikes/talos-psi-thresholds.md)
      §7 Evidence updates (#157/PR#160; symptom thread homelab#857 — recurred again 08-25
      during the hp-01 maintenance window). Scope REOPENED 2026-08-24: Option A's v1.13.8 pin
      now reads ALL metal nodes (nocloud VMs stay excluded). **Next:** operator rules
      tune-vs-accept (the pin experiment first; cilium-agent's residual pod-level exposure —
      container req=limits since 07-28, pod still Burstable — folds into the same ruling). Relates FU-139/FU-112, ADR-044.
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
