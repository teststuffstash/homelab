# Dependency upgrades — the homelab platform's own path

**This doc owns homelab's own dependency lifecycle**: what a platform dependency bump looks like
from proposal through review, test/lint, rollout and monitoring — per dependency class, because
homelab has three different reconciliation regimes and a bump means something different in each.

**Not this doc.** The org-wide **Renovate policy** (threat model, cooldown, the automerge-vs-review
split, the coordinator×Renovate verbs) is [`renovate.md`](renovate.md) — it applies to every repo
the App autodiscovers and is not repeated here. The **app-stack** deploy shapes (app+chart,
operator chart, pod image) and the surfaces homelab does not reconcile at all are `ROADMAP.md` →
"Deploy paths" (ADR-152). What the management box has been tested doing on its own is
[`management-box.md`](management-box.md) §The capability ledger.

**Decisions this doc leans on** ([`adr.md`](adr.md)): ADR-084 (deploy shape), ADR-088/089 (the
invariants a bump must not break), ADR-131 (the box plans every PR), ADR-141 (blast class picks the
lane), ADR-143 (lock intake), ADR-149/150/151 (chart reverts, the upgrade lease, the CRD owner),
ADR-152 (the box applies what ArgoCD and tofu do not), ADR-162 (dead runs and stale armed bumps).
Supply-chain signing and SBOM are FU-016 ([`follow-ups.md`](follow-ups.md)).

## Stint S9 status (homelab#1985) — read 2026-11-12

**S9 is not over.** homelab#1985 is open. Closed originals: #1986 (not planned, 2026-09-25),
#1987, #1989, #1990 and #1992 (completed 2026-09-27), and #2014 (version sets, completed
2026-10-31). Two originals are open:

- **#1988 (lanes by blast class)** still needs two things, both operator-gated: the standing
  `.github/renovate-global.json` rule that arms later agent-coordinator base-image majors (the
  revert chain behind it is built; the file is operator-direct), and the Renovate proposer for
  class 6, which by ruling comes after FU-319's attended substrate bumps (Cilium done 2026-10-31;
  Kubernetes 1.37 is draft PR #3056; Talos 1.15 not started).
- **#1991 (one proven merge per class)** has every planned proof recorded (§Last proven end to
  end). It stays open for one event nobody can schedule: the first terraform provider major merged
  on the migration lens's approval. The other event it waited for — a real lock regression
  reverted with no hand on the chain — happened on 2026-11-10 (#3233 → #3245).

#1985 itself then closes through its closeout checklist (the issue body). What a person still does
by hand, class by class, is §What is still manual, and what it waits on.

---

## Ground truth: a green Renovate workflow is not liveness

Renovate opened no PR in homelab between 2026-07-06 and 2026-09-25 while its workflow stayed green
on every run. The cause was one App permission (`statuses`), now declared in
[`github-apps.yaml`](github-apps.yaml). The lesson is the rule: liveness is the
`github_renovate_last_pr_timestamp` gauge → `RenovateSilent`, never the workflow's own verdict.
Read 2026-11-12: Renovate merged 26 `renovate/*` PRs in homelab since 2026-11-02 and the gauge's
newest PR, org-wide, was about an hour old.

One residue from the 2026-08-01 log read is not re-verified: the `NIX_VERSION` custom manager
resolved nothing then, and no Renovate PR has moved that ARG since (the register's class-10
override; rides homelab#1985).

---

## The dependency inventory, and whether a path rule can trigger deployment

The question "can a path rule trigger deployment?" has a different answer per class, because
homelab runs **three reconciliation regimes**:

- **GitOps (ArgoCD)** — every platform Application has `syncPolicy.automated`
  (`grep -L automated argocd/platform/*.yaml` lists only non-Applications), watching
  `argocd/resources/*`, `argocd/platform/*`, `agents/coordinator`, `agents/fixer/*`. A merge here
  **deploys itself**.
- **OpenTofu** — the management box plans every PR and every master move
  ([`management-box.md`](management-box.md) §MB3) and applies only what its policy allowlists
  (`policy/mgmt/plan-input.yaml`): the raw-k8s residue, the `apply_helm` rows (class 4) and
  provider pins that plan empty (class 5). Everything else in a tofu root is a human apply.
- **Outside both** — ansible (OPNsense, Matchbox, the backup Garage LXC), Home Assistant config,
  the Proxmox hosts. A merge deploys nothing unless the box applies it (ADR-152): Matchbox is
  box-applied, the router's CARP BACKUP node is the box's to converge by policy but it is refusing
  (§What is still manual), the rest is by hand.

**Canary, by ruling (operator, 2026-10-10):** in this one-cluster homelab most classes below have
no second instance to canary against, so the per-class canary cell in `docs/dependency-classes.yaml`
is `status: human` rather than `gap` — the detector + merge-gate + revert trio substitutes for a
canary stage. Each such cell names that class's natural first target for the day a real second
instance exists (e.g. `tofu/provisioning` before main for providers, arc-runners-large before
arc-runners, Matchbox before OPNsense). A class is revisited only when that second instance
actually appears, not speculatively.

<!-- BEGIN GENERATED dependency-coverage — do not edit; edit docs/dependency-classes.yaml (rulings) or the pinned files (dependencies) and run `devbox run dependency-coverage` -->

**126 pinned dependencies in 19 classes; 11 rows carry a ⚠ column; 7 class(es) complete, 2 of them without a 👤 cell.** ✅ built and proven · 👤 a human by ruling (filled, not a gap — the owner stays by design) · ⚠ missing. A row is complete when no column is ⚠ and the proof is recent (≤90 d — `DependencyClassProofStale` fires when a complete class's proof ages out; `github_dependency_coverage_gap_rows` counts the ⚠ rows).

#### Per class — the seven columns

| # | Class | Pinned where · manager | Proposer | Merge gate | Deploy edge | Detector | Revert | Canary | Last proven E2E | Rows (⚠) | Owner may leave? |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | **Helm charts, GitOps** | `argocd/platform/*.yaml` `spec.source.chart` + `targetRevision` · `argocd (`managerFilePatterns` over `argocd/platform/*.yaml` since 2026-10-04 — the Application files; `values/` excluded)` | ✅ Renovate `argocd` manager over `argocd/platform/*.yaml` (renovate-global.json, 2026-10-04 — S9 #1985): patch/minor → `deps-review`, digest → `automerge`, majors → the un-armed catch-all; the ARC controller + runner charts are one grouped PR; `prHourlyLimit` paces the backlog (6 for the watched first wave, 3 after — operator 2026-10-04). | ✅ minor → `deps-review` (reflex + lens); majors → the un-armed `major` lane by default (renovate-global.json; ADR-141 for the arm rule), ARMED behind the migration lens for argo-workflows (ADR-149, 2026-10-05) and kube-prometheus-stack + prometheus-operator-crds (2026-10-07, after the ADR-150 revert half drilled) — `major` kept, the lens's APPROVED completes the merge | ✅ ArgoCD `syncPolicy.automated` — a merge IS the deploy (every Application auto-syncs — `grep -L automated argocd/platform/*.yaml` lists only AppProjects, namespaces and refgrants) | ✅ `ArgoCDAppDegraded` (15 m) / `ArgoCDAppSyncFailed` (10 m) since 2026-10-04 (argocd/resources/argocd-metrics/, `triage: dig` → responder) + the generic rollout belt; ArgoCD health stays shallow (the meta-11 schema-skew outage stayed green on a tcpSocket probe) — the deep contract probe is FU-102 | ✅ for the ARMED charts: the `chart-revert` receiver (ADR-149, argocd/resources/chart-revert/, #2271 — the actor outside Argo's cone, drilled 2026-10-05) + the ADR-150 upgrade lease's revert half (`revert-chart-lease-<sha8>`, drilled on kps #2276 → #2279, 2026-10-07); un-armed charts keep a human `git revert` (the 2026-08-04 IAC-G09 ruling: CRD/schema downgrades are not reversible by a revert — which is WHY those stay un-armed) | 👤 by the one-cluster canary ruling (operator 2026-10-10, docs/dependency-upgrades.md §The dependency inventory): the detector + revert pair substitutes for a canary here; natural first target once a second instance exists — arc-runners-large before arc-runners, if the grouped ARC bump ever splits | 2026-10-31 ([#3062](https://github.com/teststuffstash/homelab/pull/3062)) | 17 (0) | no — complete, but a 👤 cell keeps the human by ruling |
| 2 | **In-cluster images, GitOps** | `image:` in `argocd/resources/**/*.yaml` + `agents/coordinator/*.yaml` (third-party refs; first-party = class 3) · `kubernetes (`managerFilePatterns` over `argocd/resources/**/*.yaml` since 2026-10-04) / none for `agents/coordinator/*.yaml` (codeowner-gated `/agents/`, kept out of the pattern) or agents/images.env (class 3)` | ✅ Renovate `kubernetes` manager over `argocd/resources/**` (renovate-global.json, 2026-10-04): digest → `automerge`, patch/minor → `deps-review`, majors → the un-armed catch-all; first-party `ghcr.io/teststuffstash/**` refs disabled (class 3's deploy-pin PR owns them). `agents/coordinator/*.yaml` is outside the pattern (`/agents/` is codeowner-gated — a PR there would park on the human the lane removes; no third-party ref lives there today) | ✅ digest → `automerge` (reflex), version minor → `deps-review`, major → un-armed (renovate-global.json) | ✅ ArgoCD auto-sync of the manifest — path-scoped per resource dir | ✅ `ArgoCDAppDegraded` / `ArgoCDAppSyncFailed` since 2026-10-04 + the generic rollout belt + the per-service alert belts where they exist (11 of 16 rows have one); no post-deploy contract probe (FU-102) | 👤 a human `git revert`; the FU-044 chain's pin-only predicate covers FIRST-PARTY pins only (class 3) | 👤 by the one-cluster canary ruling (operator 2026-10-10, docs/dependency-upgrades.md §The dependency inventory): the detector + revert pair substitutes for a canary here; natural first target once a second instance exists — the one class-2 dependency that already runs several (the `registry` mirrors: mirror-docker-io before mirror-ghcr/mirror-mcr) | 2026-10-30 ([#3038](https://github.com/teststuffstash/homelab/pull/3038)) | 19 (1) | no — 1 ⚠ row(s) |
| 3 | **First-party images** | `agents/images.env` (agent-base, agent-coordinator) + every `image: ghcr.io/teststuffstash/…` ref the deploy-pin sweep must reach (`argocd/**`, `agents/coordinator/*.yaml`) · `n/a — the deploy-pin PR (ADR-084); Renovate never touches our own artifacts (a `2026.<m>.<d>-g<sha>` tag does not order)` | ✅ the image repo's `deploy-pin` job (agent-runtime → agent-base, agent-coordinator), `runner-image.yaml` (arc-runner) and `gateway-image.yaml` (agent-gateway — the kustomize `newTag` in argocd/resources/agent-gateway/, `deploy/agent-gateway`) open `deploy/*` / `runner-image-pin` PRs; weekly `schedule` rebuilds since 2026-09-27 | ✅ `automerge`+`dependencies` → renovate-approve reflex → CI-green auto-merge (`pin-only-lint` guards the diff shape) | ✅ ArgoCD auto-sync; the deploy-pin sweep bumps every mirrored literal by git-grep (images.env header) — a ref with a DIFFERENT tag than images.env is one the sweep missed (⚠ on the row) | ✅ `ArgoCDAppDegraded` since 2026-10-04; ArgoCD Degraded → `/deploy-degraded` was wired 2026-08-04 but its first hop was DEAD until #2217 (recipient `webhook:agent-loop`, 150 failed deliveries) — never fired by a real Degraded app for that reason; `ArgoCDNotificationDeliveryFailing` now watches the hop; a bare `:latest`-equivalent ref is still invisible | ✅ the cluster pin IS the revert (operator 2026-09-27): `deploy-revert-argo.yaml`'s pin-only predicate opens the revert PR; the FU-1990 sibling chain proved the shape end to end in the 2026-09-27 drill (agent-coordinator#20 → #21, ~3.5 min); the agent-coordinator pin's RUNTIME failure (no Degraded — a CronWorkflow has no health) → the `chart-revert` receiver's image target on `AgentLoopWorkflowsFailing`: `revert-coord-<sha8>` restores the PREVIOUS tag from outside that image's cone, `reverted-coordinator:` → pin-only-lint check (k), 30 d by source commit (2026-10-31, [design Part 7](designs/fu-1990-workflow-pin-revert.md); dry-run drilled, live drill pending) | 👤 by the one-cluster canary ruling (operator 2026-10-10, docs/dependency-upgrades.md §The dependency inventory): the detector + revert pair substitutes for a canary here; natural first target once a second instance exists — the transcript viewer (read-only, lowest blast of the four consumers) before the coordinator/reviewer/sentinel | 2026-10-31 ([#3059](https://github.com/teststuffstash/homelab/pull/3059)) | 5 (2) | no — 2 ⚠ row(s) |
| 4 | **Helm charts, tofu-managed** | `helm_release` blocks in `tofu/*.tf`, version from `tofu/variables.tf` defaults · `custom.regex — a `# renovate: datasource=helm depName=<chart> registryUrl=<repo>` annotation on the `var.*_version` default (renovate-global.json, 2026-10-10); the terraform manager reads `helm_release.version` literals only` | ✅ Renovate `custom.regex` over the `# renovate:` annotations on the chart defaults in `tofu/*.tf` (renovate-global.json, 2026-10-10 — S9 #1988): argo-cd, argocd-apps, longhorn; `cilium_version` stays un-annotated (class 6, human-proposed by ruling). The terraform manager reads `helm_release.version` literals only, which is why the annotation is needed | ✅ patch/minor → `deps-review`, armed (the merge-path reviewer + migration lens; the management sentinel's plan-on-PR, ADR-131, posts the changed addresses), majors: argo-cd + argocd-apps ARMED behind the lens since 2026-10-11 (operator, after #2488 — `major` kept, no `automerge` label, the lens's APPROVED completes the merge and the box bracket is the deploy edge, forward only); longhorn majors stay on the un-armed human lane by ruling (no downgrade — the preflight restore point is the only rollback). Since FU-301 (2026-10-10) a merge IS the deploy for the `apply_helm` rows (next cell) — the lens read is the last human-shaped read; it caught longhorn 1.12.1's default NetworkPolicies (#2463) before the box applied it | ✅ the management box applies the `apply_helm` rows itself (argocd-apps, argo-cd, longhorn — policy/mgmt/plan-input.yaml; operator ruling 2026-10-10 "for now"): forward only, evidence-bracketed — preflight refusals (declared-vs-live; longhorn: volume health + a fresh restore point), a declared window + ⚓ lease, the apply, longhorn engine moves by disk class, the evidence + box verdict (docs/management-box.md §Helm release applies). Proven unattended: argo-cd 9.7.1 (#2464, 2026-10-10, CONFIRMED). Cilium is class 6 — never a row | ✅ the bracket's own verdict (evidence verdict + the FU-302 box verdict, polled against its baseline) → STOP + `MgmtHelmApplyStopped` (and its lease arm, `forward_only`); `MgmtApplyResidueStanding` for a span the box refuses; plan-on-PR shows the diff before merge. Fired on real breakage 2026-10-10: longhorn 1.12.1's first engine move (a 1-replica volume) never left the old engine | 👤 by ruling, NEVER the box (operator 2026-10-02/10-10: forward only — a STOP leaves lease + window + marker for a human): `git revert` + a human apply for ArgoCD; Longhorn refuses downgrades, so its rollback is the restore point the preflight takes (docs/longhorn-backup.md); CRD/schema risk (IAC-G09) | 👤 by the one-cluster canary ruling (operator 2026-10-10, docs/dependency-upgrades.md §The dependency inventory): the detector + revert pair substitutes for a canary here; natural first target once a second instance exists — `argocd-apps` before `argo-cd`/`longhorn` (least valuable first) | 2026-10-30 ([#3039](https://github.com/teststuffstash/homelab/pull/3039)) | 3 (0) | no — complete, but a 👤 cell keeps the human by ruling |
| 5 | **Tofu providers** | `tofu/**/versions.tf` `required_providers` (the `~>` range) + `.terraform.lock.hcl` (the real pin) · `terraform` | ✅ Renovate `terraform` — lockfile + constraint PRs flow since the `statuses` grant (2026-09-25; #1976/#1981/#1983/#1984/#1996/#1997 merged 2026-09-27); the two roots the box does not plan are excluded from the manager (row overrides) | ✅ the management box is the gate, mechanically (ADR-131 amended 2026-09-27, #2026): stage 1 admits the `provider-pin` diff shape, stage 2 plans the head with the new provider and a pin must plan EMPTY — relative to master's own pending plan, or a default backfill (null→default attributes a release adds, #2191) — and keep every stored schema/identity version (the state-compatibility check, 2026-10-04) — `management-sentinel` green on `+0 ~0 -0` → `automerge` (reflex approves, auto-merge lands); red = the only provider PRs a human sees (`mgmt-human-plan`). Built on six human-ordered `+0` plans; merging on the sentinel's own green since 2026-09-28 (#2075 proxmox, #2096 talos; #2213 random on 2026-10-04 — Renovate merged, reflex-approved, no human). MAJORS armed 2026-10-04 (operator; ADR-141 amended): `major` kept, no `automerge` label, the migration lens's APPROVED completes the merge | ✅ an empty plan IS the deploy: the box's next plan/apply runs the new provider binary (registry-signed, hash-verified by tofu); nothing to apply by construction. Caveat for the hand-applied roots (policy/mgmt/plan-input.yaml `apply: false`): a `default-backfill`-admitted pin merges with a non-empty pending plan that waits for the next hand apply — inert (the provider moves no runtime pin), seen by the belt plan for `tofu/provisioning` + `tofu/github`, by nothing for `tofu/cloudflare` | ✅ the sentinel's plan-on-PR (red = `provider bump changes the plan`, by design) + `MgmtApplyResidueStanding` on main; post-merge, `MgmtApplyErroredOnNewProvider` names the provider when the first CHANGING apply under a new version errors (2026-10-04, docs/management-box.md §MB3); the external roots plan read-only on the box (FU-237/FU-238) | ✅ `git revert` of the lockfile + the same empty plan; lockfile-only BY GATE since 2026-10-04 — a pin that would raise a stored schema/identity version never merges on the sentinel, so the downgrade reads the state back (docs/management-box.md §MB3); the `tofu-provider-revert` chain (2026-10-04, agents/coordinator/deploy-revert-argo.yaml) reverts the introducing pin on `MgmtApplyErroredOnNewProvider` — DRILLED 2026-10-04 (synthetic alert → #2209 merged + applied, no human; §Last proven); provider MAJORS armed 2026-10-04 behind this chain (ADR-141 amended) | 👤 by the one-cluster canary ruling (operator 2026-10-10, docs/dependency-upgrades.md §The dependency inventory): the detector + revert pair substitutes for a canary here; natural first target once a second instance exists — `tofu/provisioning` before `tofu/` (main), the low-blast root a provider bump could land on first | 2026-10-29 ([#3014](https://github.com/teststuffstash/homelab/pull/3014)) | 14 (3) | no — 3 ⚠ row(s) |
| 6 | **Cluster substrate** | `tofu/variables.tf` defaults (`talos_version_*`, `kubernetes_version`, `cilium_version`) + `machines/machines.yaml` · `terraform (weak) — human-proposed until ROADMAP G-D (operator 2026-09-18)` | 👤 a human bump PR of the variable default — Renovate stays off class 6 until a few ATTENDED bumps through the box path have passed (operator 2026-09-21, ROADMAP G-D; the attended bumps are FU-319, the Renovate proposer after them is homelab#1988); the substrate belt says when we are behind or EOL (FU-254, docs/management-box.md §MB2) | 👤 PR + plan-on-PR + the install-impact line (§MB3) + the codeowner read; Kubernetes minors need a recreate-from-git drill first (design sitting 2026-09-25) | ✅ the box-run rollout: `mgmt-reconcile` rolls `reconcile: auto` nodes — 13/13 incl. 3 CPs on 2026-09-22 (#1879, ADR-132; VMs in place since ADR-014's 2026-09-18 amendment) | ✅ `MgmtNode*Drift` declared-vs-live per node (FU-235) + the substrate currency belt (FU-254) + the rollout's workload-health hold (FU-278) | 👤 forward by default (rollout ruling 2026-09-22): a revert is a human commit + the same rollout; the post-apply health gate parks, never reverts | ✅ per-type canary node via the per-node `talos_version` override (FU-033 lever) — the reconciler rolls canaries first, CPs last | 2026-09-22 (capability ledger — Talos install rollout, workers + CPs (`mgmt-reconcile`): #1879: 13/13 v1.14.1 09:43→13:17Z, canary per type, CPs last) | 4 (0) | no — complete, but a 👤 cell keeps the human by ruling (1 row-level) |
| 7 | **devbox/nix toolchain** | `devbox.json` (all `@latest`) → `devbox.lock` (the resolved version); + the version-set stamp `version-sets/devbox.{json,lock}` (claude-code, kind `@latest`, kubectl bounded to the fleet minor — #2014) · `nix/devbox DISABLED on purpose (an `@latest` pin is untrackable — docs/renovate.md §Gotchas)` | ✅ the weekly synchronized `devbox-update.yaml` — one job re-resolves EVERY repo's lock together, one PR per repo (the model other classes must match, #2014) | ✅ `automerge`+`dependencies` → reflex → CI-green; a major in the resolved set relabels the PR `major` and KEEPS it armed (2026-10-07, §2 Review — the migration lens's APPROVED completes the merge); only a `HUMAN_PACKAGES` major (opentofu, the state-format owner) disarms it for a human (scripts/devbox-update.sh `lock_lane`) | ✅ self-deploying for CI and the jail (`devbox run` reads the lock); the agent-base image rebuilds weekly (class 3 carries the pin); the in-cluster `iac-sentinel` runs the runner IMAGE's baked lock, not master's, so it moves one `runner-image` build+pin later — the accepted lag that keeps a bad lock from silencing the required check on its own revert (operator 2026-10-10, docs/management-box.md §Two pins) | ✅ pre-merge: CI on the PR; post-merge: `GithubWorkflowRunFailed` on the `runner-image` bake (the lock's first consumer) — it keyed both revert drills (2026-10-10, 2026-10-11). The version-SET members of the lock (claude-code, kubectl in agent-base) are compared against the coordinator image, the seat and the fleet minor by the version-set drift belt (2026-10-10, #2014: `argocd/resources/version-sets/` — `VersionSetMembersDisagree` / `VersionSetBehindPin` / `VersionSetKubectlSkew`), FIRED 2026-10-11 13:25Z on the real split (seat 2.1.296 / stack jails 2.1.281 / images 2.1.291) — the belt is proven; what stays open is the rest of the lock is per-repo and nothing compares it across repos (FU-240 for the box↔jail devbox skew) | ✅ `git revert` of the lock — nothing else references the store paths; mechanised 2026-10-07 as the `workflow-pin-revert` lock shape (`revert-lock-<sha8>`, `reverted-locks:` memory → pin-only-lint check (i)) — DRILLED 2026-10-10 (#2478 → #2480, one hand merge: governance-lint red the chain's own revert → its revert-lock arm #2482) and RERUN HANDS-OFF 2026-10-11 (#2503 → #2504, 12 min, zero hand acts — §Last proven) | 👤 by the one-cluster canary ruling (operator 2026-10-10, docs/dependency-upgrades.md §The dependency inventory): the detector + revert pair substitutes for a canary here — deliberately so (alignment over caution is the design, not a gap); natural first target if that ever splits — `oracle-iac`/`sleep-iac` (deploy-config repos, no live service of their own) before the app repos they deploy | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) | 43 (0) | no — complete, but a 👤 cell keeps the human by ruling |
| 8 | **GitHub Actions** | `uses:` in `.github/workflows/*.y*ml` (third-party; first-party `teststuffstash/**@master` floats by contract) · `github-actions` | ✅ Renovate `github-actions`, SHA-pinned (`helpers:pinGitHubActionDigests`), grouped per repo per wave — #2021 (pin) and #2008 merged 2026-09-27 | ✅ every update type incl. majors rides the grouped `automerge` lane (ADR-141 as amended 2026-09-27): reflex approval + CI on the bumped head (a `pull_request` workflow runs the PR's own file) | ✅ self-deploying — the next run uses the merged file | ✅ `GithubWorkflowRunFailed` on master (github-exporter) covers the push-only workflows CI cannot exercise | ✅ the FU-1990 chain: `workflow-pin-revert` reverts the pin PR as `automerge`+`dependencies`, `pin-only-lint` check (e) refuses the reverted pin for 30 d — DRILLED 2026-09-27 (agent-coordinator#20 → #21, no human touch) | ✅ the PR's own `pull_request` run on the bumped head is the pre-merge proof; push-only workflows are canaried by the revert chain instead | 2026-10-30 ([#3037](https://github.com/teststuffstash/homelab/pull/3037)) | 5 (0) | **yes** — complete |
| 9 | **Router config (ansible + the `oxlorg.opnsense` collection)** | `ansible/collections/requirements.yml` (the real pin — `oxlorg.opnsense`, aligned with the router's os-frr series) + `ansible/requirements.yml` (roles: in-repo today, the extraction seam); the config itself is `ansible/opnsense-*.yml` + `opnsense/*.py` · `ansible-galaxy` | ✅ humans write the config; Renovate `ansible-galaxy` proposes the collection pin — #2033 (`oxlorg.opnsense` 25.7.8 → 26.1.11, the `major` lane) merged 2026-09-29 after the test VM harness passed it (docs/opnsense-test-vm.md, `--pr 2033`) | ✅ the collection pin rides the standard lanes ARMED (patch/minor → the fail-closed catch-all's `deps-review`, majors → un-armed — #2033 went that way) and no codeowner reads it — `/ansible/` is unowned since the ADR-128 trial (CODEOWNERS tier 2 commented out). The mechanical gate is the router's own test surface: the box-posted `opnsense-test-vm` status (the test VM harness `scripts/opnsense-test-vm.sh` on VM 9110 when a router path moved — `ansible/collections/requirements.yml` is one — n/a success otherwise; docs/management-box.md §MB3 "The router surface") is a REQUIRED check on homelab since 2026-10-27 (#2957, ADR-152 step 1). `ci`, `iac-sentinel` and `management-sentinel` run nothing ansible-specific | ⚠ MANUAL converge → the box applier (ADR-152, in build): today a merge deploys nothing — `scripts/opnsense-router-node.sh converge <node>` per node is a seat act and nothing records which collection version last converged each node (the FU-097 gap, sharpest here: this is the router), so an armed collection bump is latent git-vs-live drift until someone converges (2026-10-26 drift audit). Operator ruling 2026-10-26: keep the lane armed, close the edge — the box as the ansible applier (ROADMAP §Deploy paths program: Matchbox (class 15) first, then shadow → BACKUP-only → rolling here). BACKUP-only LIVE 2026-10-27 (`apply_ansible.opnsense`, `mode: backup-only`: the live CARP BACKUP, a node-local restore armed first, the security-boundary `deny_paths`; first unattended BACKUP converge CONFIRMED on #2955 — docs/management-box.md §Router config converge — BACKUP-only). The box has REFUSED the BACKUP converge since 2026-10-31 (`ansible-live-drift` on the BACKUP's Kea config; read 2026-11-12, FU-297) — until a person converges it once, no router merge reaches either node; the MASTER is still a seat converge | ⚠ PARTIAL — the box belt's `ansible --check` (`mgmt-probe` `check_ansible` → `MgmtBeltCheckFailing` reason `drift`, judged per router node; docs/management-box.md §MB2) reads the recap's `changed=` but `oxlorg.opnsense.raw` `action: post` tasks return unchanged in check mode, so advanced-settings drift stays invisible; the weekly rebuild drill's realism score (`MgmtOpnsenseDrillScoreRegressed`; the drill is green since 2026-10-11 — FU-297) and the pair belts (`RouterPairMasterCount`, `RouterWanGateSilent`) cover part of the rest | 👤 `git revert` + a human re-converge per node; FU-308's dead-man covers only CARP maintenance. A box-run revert must be NODE-LOCAL (the commit-confirm shape, dependency-upgrades.md §4 / ADR-152 (2)): the box's PR path and its Prometheus read both ride the router it would be changing | 👤 the BACKUP node — a real second instance since the pair completed 2026-10-09 (docs/router-move.md §Status; the one-cluster canary ruling's revisit condition is met): converge the BACKUP, `check`, then the MASTER through `carp-maintenance enter` with the FU-308 dead-man armed so the BACKUP serves under real load (drill R1 2026-09-30: failover 0.62 s, failback 3.1 s, flows kept). A seat act today; box-run with a lease is ROADMAP §Deploy paths program step 3 | 2026-09-29 ([#2033](https://github.com/teststuffstash/homelab/pull/2033)) | 1 (1) | no — 2 ⚠ column(s), 1 ⚠ row(s) |
| 10 | **arc-runner image inputs** | `docker/arc-runner/Dockerfile` — `FROM ghcr.io/actions/actions-runner` + `ARG DEVBOX_VERSION` / `ARG NIX_VERSION` · `dockerfile (FROM) + custom.regex (the two ARGs — renovate-global.json customManagers)` | ✅ Renovate `dockerfile` + `custom.regex` — #2022 (actions-runner 2.337.0, `deps-review`) merged 2026-09-27 | ✅ FROM minor → `deps-review`, FROM patch → `automerge` (2026-10-10, the fail-closed pass); ARG patch/minor → `automerge` (custom.regex rule, 2026-09-27); majors → un-armed | ✅ `runner-image.yaml` builds on the merge and opens the `runner-image-pin` PR (class 3 lands it) | ✅ the image build in `ci` (push: false) fails the PR; `GithubWorkflowRunFailed` covers the master build | ✅ the cluster pin is the revert (the previous `arc-runner:` tag stays pullable); the FU-1990 chain covers the workflow half | 👤 by the one-cluster canary ruling (operator 2026-10-10, docs/dependency-upgrades.md §The dependency inventory): the detector + revert pair substitutes for a canary here; natural first target once a second instance exists — arc-runners-large before arc-runners, if the pin PR ever splits the two scale sets | 2026-10-26 ([#2945](https://github.com/teststuffstash/homelab/pull/2945)) | 3 (1) | no — 1 ⚠ row(s) |
| 11 | **Harness + tool versions baked into first-party images** | three Dockerfiles in three repos (agent-runtime, agent-coordinator, claude-jail) — NOT extractable from this repo; the in-repo half is class 7/10. Members + sync state: §Version SETS below · `devbox-update (agent-base's lock; the version-set stamp `version-sets/devbox.lock` for claude-code/kubectl/kind — #2014); custom.regex for s5cmd; none for gh` | ✅ ONE source since 2026-10-10 (#2014 shape (a)): the weekly devbox-update's homelab leg stamps claude-code + kind `@latest` and kubectl bounded to the fleet minor (tofu/variables.tf `kubernetes_version`) into `version-sets/devbox.lock`; every consumer reads it at build time — agent-coordinator#25 (npm `@anthropic-ai/claude-code@<stamp>`, kubectl from the stamp), agent-runtime#170 (agent-base builds the stamp's flake refs), claude-jail#10 (the seat: npm pinned to the stamp, 2026-10-18) — and a stamp change on master rings both cluster consumers' `build-image.yaml` (`version-sets-dispatch.yaml`, `repository_dispatch: version-sets`); the seat is host-built, so its edge is the operator's next rebuild (the belt watches the lag) | ✅ the weekly `build-image` rebuild + the class 3 deploy-pin lanes | ✅ a rebuild is a new build-date tag → deploy-pin rolls it (weekly `schedule` since 2026-09-27, and on every stamp change since 2026-10-11 via `version-sets-dispatch.yaml`); the seat's edge is a hand host rebuild (claude-jail#10 pins it to the stamp at build time) | ✅ BUILT 2026-10-10 (#2014, detection before fix), FIRED on the real split 2026-10-11 13:25Z (`VersionSetMembersDisagree`: seat 2.1.296 / stack jails 2.1.281 / images 2.1.291): `version-set-probe` (argocd/resources/version-sets/, 6-hourly) runs each pinned image's own `claude`/`kubectl`/`kind` and pushes what it ships; the seat's claude-code comes from its OTLP sessions; `VersionSetMembersDisagree` (claude-code split > 1 d), `VersionSetBehindPin` (a member off the stamp > 2 d, silent until the stamp exists), `VersionSetKubectlSkew` (> 1 minor from the live apiserver) + probe freshness. The seat's host rebuild is the one consumer edge still done by hand (the deploy-edge cell) | ✅ the cluster pin is the revert (operator 2026-09-27) | 👤 by the one-cluster canary ruling (operator 2026-10-10, docs/dependency-upgrades.md §The dependency inventory): the detector + revert pair substitutes for a canary here; natural first target once a second instance exists — claude-jail (the dev jail image, not a live cluster workload) before agent-runtime/agent-coordinator | — never | 0 (0) | no — never proven |
| 12 | **JS CI tooling (Deno)** | `scripts/mermaid-lint/deno.json` (+ `deno.lock`) — the docs' mermaid parser, CI-only, run with NO Deno permissions (ADR-143) · `deno` | ✅ Renovate `deno` (ADR-143, 2026-09-29 — the npm lane's #2012 jsdom 30.1.0 merged 2026-09-27 is the prior proof; jsdom left with the switch) | ✅ patch/minor → `automerge`; mermaid MAJORS → `automerge` too (operator ruling 2026-10-11 on #2100: 'CI is the only gate needed' — the `Mermaid parse lint` step of required `ci` parses every tracked diagram with the bumped parser on the PR head; graduates to the lens the first time a major produces evidence, ADR-141's Actions rule); other deno majors (linkedom) → un-armed `major`; `lock-intake-lint` in `ci` fails any intake that is OSV-flagged, <7 d old or install-script-bearing (transitive included — ADR-143) | ✅ self-deploying — `ci` fetches the lock's integrity-pinned tarballs + parses on every PR | ✅ required `ci` (`mermaid-lint` + `lock-intake-lint`) — a broken parser or a bad intake reds the PR before merge | ✅ `git revert` — no runtime consumer | ✅ the PR's own `ci` run exercises the exact dependency that ships | 2026-10-28 ([#2993](https://github.com/teststuffstash/homelab/pull/2993)) | 2 (0) | **yes** — complete |
| 13 | **Management box closure (mgmt/nixos flake)** | `mgmt/nixos/flake.lock` — nixpkgs (kernel, systemd, sshd AND the loops' tools: yq, kubectl, jq, curl, openssl, awscli2 — `boxTools` in `mgmt/nixos/hosts/mgmt/default.nix`, FU-305) + disko · `the weekly `devbox-update` job (`nix flake update`, homelab leg) — Renovate's `nix` manager stays disabled with `devbox` in one packageRule (renovate-global.json)` | ✅ the weekly `devbox-update` job's homelab leg runs `nix flake update` in `mgmt/nixos` into the SAME PR as the devbox lock (operator ruling 2026-10-10, FU-305 — scripts/devbox-update.sh `flake_moves`: a body section per input, a backwards `lastModified` joins the G17 downgrade list). Before it the pin never moved (nixpkgs 21a67dc, install day 2026-09-11); the gate loops' own tools ride this pin, so its age was their age. The lock has moved in the weekly PR since #2726 (2026-10-19; then #2919, #3154) | ✅ armed like class 7 (operator ruling 2026-10-10): `mgmt/nixos/flake.lock` is carved out of the `/mgmt/` CODEOWNERS row and pin-only-lint check (j) in `ci` stands in for the owner — the author must be the devbox-update App (or the revert App restoring master's previous file exactly, on `revert-lock-*`), only `locked` may move, and every locked rev must be REACHABLE from its declared branch upstream (GitHub compare `behind`/`identical` — owner/repo alone proves nothing, a fork's commits are served under the parent's URL). Any other author, or a change beside another `mgmt/` path, keeps the human read; `flake.nix` stays owned (ADR-129 amended 2026-09-14) | ✅ `mgmt-pull` (hourly) re-activates the closure when `mgmt/nixos/` changed: `nixos-rebuild test` → `mgmt-confirm`'s box-local gate → `boot` (promote) or reboot back (docs/management-box.md §The update loop) | ✅ the `mgmt-confirm` gate (sshd, keys, network, systemd, store — box-local by design) + the loops' own staleness belts (`MgmtApplyLoopStale`, `MgmtLeaseLoopStale`, `MgmtReconcileLoopStale`, `MgmtBeltStale`) + `mgmt-tools-test` in CI (a loop that reaches for a tool the closure lacks fails `mgmt_x` loud) | ✅ `git revert` of the flake.lock commit — the next pull re-activates the previous closure; a never-boots kernel needs hands (§Rollback layer 2) | 👤 one box, by the one-cluster canary ruling (operator 2026-10-10): `nixos-rebuild test` + the deadman gate substitute for a canary | — never | 2 (0) | no — never proven |
| 14 | **Router firmware (OPNsense)** | nothing pinnable — the mirror serves only each series' head; git declares the SERIES: `scripts/opnsense-test-vm-bootstrap.sh` `SERIES` (the SERIES, `26.7` — never a point: the bootstrap converges on whatever head the mirror serves, #2501 after two head moves broke every build) and `NANO_VERSION` = `tofu/opnsense-test.tf` `var.opnsense_test_nano_version` (the birth image, one nano per major). Inside a series the policy is latest; the live build is a reading, not a pin (docs/opnsense-test-vm.md §The official update path) · `none — no Renovate, by ruling (operator 2026-09-29: the official update path; `opnsense/core` tags precede packages and hotfix `_N` builds have no tag)` | 👤 none in git — the router's own `firmware/check` is the authority, by ruling (2026-09-29); a belt-raised record (the box reading `firmware/status` per node, the `check_substrate` pattern) was discussed, never built — ROADMAP §Deploy paths program step 1 (the currency belt) | 👤 nothing merges — a SERIES move (a major) is a `SERIES` + `NANO_VERSION` edit under the codeowner read; inside a series nothing in git moves (latest, by #2501); MAJORS attended (ruling 2026-09-29, 'until the router is a VM pair' — met 2026-10-09; ADR-152: box-run after one attended drill along the rolling path (ROADMAP §Deploy paths step 4)) | 👤 seat API calls per node — `core/firmware/check` → `update` (hotfix/minor, cumulative in a series) → `upgrade` (major: offline, three automatic reboots) — trialled on test VM 9110 from `baseline` first (docs/opnsense-test-vm.md §The official update path); prod followed the same path the same day on 2026-09-29 and 2026-09-30 | ⚠ no `firmware/status` belt (behind-series / EOL) — the pair belts and the weekly drill only see the aftermath; the accidental detector (`every build failed at the old SERIES`, how the 2026-09-30 and 2026-10-11 head moves were found) is GONE by design since #2501, so the gap is now pure — prod sat at 26.7.5 with 26.7.6 pending on 2026-10-11 and only a hand `firmware/check` said so; the drill now builds at the head, so its config diff vs prod is the one read that notices a skew | ⚠ none written down — the nodes are VMs (ADR-144), so a `qm snapshot` rollback exists and the loader keeps the previous kernel as `kernel (1 of 2)`; ADR-152 (2): the snapshot is the firmware revert, local to the target because the box's path rides the router | 👤 the BACKUP node first (snapshot, update, `check`), then the MASTER through `carp-maintenance enter` → update → `check` → `leave` with the FU-308 dead-man armed (drill R1 2026-09-30: three reboots, flows kept, failover 0.62 s / failback 3.1 s) — a seat act; the lease-wrapped box run is ROADMAP §Deploy paths program step 4 | — never | 2 (2) | no — 2 ⚠ column(s), 2 ⚠ row(s), never proven |
| 15 | **Matchbox (PXE provisioner)** | `ansible/group_vars/matchbox.yml` — `matchbox_version` (the server release, sha-pinned) + `talos_version` (the PXE boot assets; `scripts/machines-lint.sh` holds it in lockstep with `tofu/provisioning` and the fleet) · `none — a hand bump; no Renovate manager reads these group_vars literals` | 👤 a hand edit; `machines-lint` holds the Talos asset pin in lockstep with the fleet's declaration (a substrate bump drags it) | 👤 codeowner read; `machines-lint` in `ci` is the only mechanical check | ✅ the box applies it (`policy/mgmt/plan-input.yaml` `apply_ansible.matchbox`, `mode: on` since 2026-10-26; `mgmt/scripts/mgmt-ansible.sh` — docs/management-box.md §Ansible applies): every merged span touching the plays/roles/group_vars → `--check --diff` of master, the drift refusal, window + ⚓ lease → apply → confirm (a second `--check` changed=0 + Matchbox HTTP + units). First unattended apply CONFIRMED 2026-10-26 (#2950) | ✅ the box belt's `check_ansible` runs every Matchbox play in `--check` each tick since 2026-10-26 (the policy's play list) → `MgmtBeltCheckFailing` reason `drift` on `matchbox-lxc`; the roles were made check-clean for it (the release re-download, `get_url`'s HEAD diff, the tftpd-hpa mask) | 👤 `git revert` + the playbook re-run (the box applies the revert like any span once on); the box itself never reverts — a bad confirm STOPS it (`MgmtAnsibleApplyStopped`) | 👤 the cone is near zero (nothing depends on Matchbox until the next PXE boot — dependency-upgrades.md §4 Rollout), so Matchbox IS the ansible classes' canary: the first box-applied surface by ADR-152's program order, ahead of the router (class 9) | — never | 2 (0) | no — never proven |
| 16 | **Proxmox hosts (packages, reboots)** | nothing pinned in git — in-major `apt dist-upgrade` through `ansible/pve-upgrade.yml` (never reboots; a major is a separate sources edit — docs/runbook.md §Proxmox host maintenance); reboots through `scripts/host-maintenance.sh` (`devbox run host-maint -- preflight\|down\|up <nx-02\|pve>`) · `none` | 👤 a human runs `pve-upgrade.yml` — no git-visible intent, nothing proposes | 👤 nothing merges — the host verb is attended (docs/management-box.md §Hypervisor: the host verb) | 👤 `pve-upgrade.yml` (in-major, reports REBOOT-PENDING, never reboots) + `host-maint` composing the per-guest verbs — ATTENDED until FU-306 proves the verb-on-box wiring on the runners and compute High Availability (ROADMAP §"HA model", layer 3) exists (ADR-152: not in the program) | ✅ `PveThinPool*` / `PveVmIoError` / `PveHost*` / `PveMetricsStale` (the host's textfile exporter going quiet) in `argocd/resources/pve-metrics/` (FU-093), plus the per-guest belts the guests carry | 👤 no package-level revert path written down; the play snapshots `/etc/pve` before it runs (runbook §Proxmox host maintenance) | 👤 the other hypervisor — a real second instance since ADR-133 (nx-02 beside pve); one host per `host-maint` window, attended | — never | 0 (0) | no — never proven |
| 17 | **Renovate runtime tools** | `scripts/upstream-alerts-refresh.sh` — `HELM_VERSION`, the helm the G12 `postUpgradeTasks` refresh installs in the slim Renovate container (containerbase `install-tool`; a no-op for the seat) · `custom.regex — one customManager over the script's `HELM_VERSION=v<x.y.z>` line (depName helm/helm, github-releases; renovate-global.json)` | ✅ Renovate `custom.regex` over the script (2026-10-22). The pin was born 2026-10-10 (#2432) INSIDE `.github/renovate-global.json` as two halves (the postUpgradeTasks command + its regex-escaped `allowedCommands` twin) under the `/.github/` codeowner row, invisible to this register — #2804 (4.3.0 → 4.3.1) parked on the operator; moved so the lane is real and the pin is a row | ✅ patch/minor → `automerge` (the custom.regex rule, reflex-approved; `scripts/` carries no codeowner row except three maintenance scripts); majors → the un-armed catch-all | ✅ self-deploying — the next kube-prometheus-stack Renovate branch runs the script, which installs the merged pin | ✅ that branch's `prometheus-rules-lint` (required `ci`, G12) reds if the install or the render breaks — lagging to the next chart bump; nothing exercises the pin before merge, accepted at the 2026-10-10 minting (the same proof the codeowner gate had) | ✅ `git revert` of the one line; the pin has no consumer outside a Renovate branch | 👤 by the one-cluster canary ruling (operator 2026-10-10, docs/dependency-upgrades.md §The dependency inventory): the detector + revert pair substitutes for a canary here | 2026-10-22 ([#2804](https://github.com/teststuffstash/homelab/pull/2804)) | 1 (0) | no — complete, but a 👤 cell keeps the human by ruling |
| 18 | **Check-time policy inputs** | the two pins `scripts/component-check.sh` (`devbox run component-check`, report-only — docs/agents/iac-lane.md §L0b) evaluates manifests against, neither deployed anywhere: `KYVERNO_POLICIES_CHART_VERSION` (the `kyverno-policies` chart, rendered at check time as the Pod Security `restricted` set) and `scripts/vendor-kyverno-policies.sh`'s `KYVERNO_POLICIES_REF`/`KYVERNO_POLICIES_SHA` (the kyverno/policies `release-1.19` head the `policy/component/` library rules are vendored from) · `custom.regex — the class-4-shaped `# renovate: datasource=helm depName=kyverno-policies registryUrl=…` annotation over the chart line; a `git-refs` digest manager over the `KYVERNO_POLICIES_REF`+`KYVERNO_POLICIES_SHA` pair, with `scripts/vendor-kyverno-policies.sh` as the branch's `postUpgradeTasks` command (the second G12 consumer — docs/renovate.md §Gotchas) so the bump is born with the files re-fetched (renovate-global.json, operator-direct, 2026-10-25)` | ✅ Renovate `custom.regex` over the two scripts (renovate-global.json, 2026-10-25, homelab#2911): the chart by version, the library by branch-head digest; the library publishes no release tags, so the pin is the `release-1.19` head (operator ruling 2026-10-25 — main is mid-migration, docs in the vendor script's header). Proof pending as of 2026-11-12: no `renovate/` PR has moved either line yet | ✅ patch/minor + digest → `automerge` (reflex-approved; `scripts/` and `policy/component/` carry no codeowner row) — a bump changes only what the REPORT says, never what the cluster runs; majors → the un-armed catch-all (a chart major may rename policies or change `policyType` semantics) | ✅ self-deploying and cluster-free: the next `component-check` run (CI on the branch, the seat's `devbox run component-check`) renders the new chart version and evaluates the re-fetched files — nothing on the cluster consumes these pins (the admission seat is FU-191, undecided) | ✅ the Renovate branch's own `component-check` run is the detector: a chart that fails to render or a vendored file the CLI rejects is a tool error in the report, and `vendor-kyverno-policies.sh --check` inside every run reds a vendored copy that drifted from its pin (the postUpgradeTasks re-fetch failing to run would show here). Report-only until `--enforce` is wired, so the red is a line the reviewer reads, not a check | ✅ `git revert` of the bump commit — the pin lines and the re-fetched `policy/component/` files travel in the same commit by construction (postUpgradeTasks `fileFilters`), so the revert is complete and `--check` proves it | 👤 by the one-cluster canary ruling (operator 2026-10-10, docs/dependency-upgrades.md §The dependency inventory) — and moot here: the pins feed a report, there is no live instance to canary | — never | 2 (0) | no — never proven |
| 19 | **Backup Garage LXC (the Longhorn/CNPG backup target)** | `ansible/group_vars/garage_backup.yml` — `garage_version` + `garage_sha256` (a static musl binary for CT 220 `backup-garage` @ 192.168.2.73, docs/longhorn-backup.md; FU-299); kept in lockstep with the vendored in-cluster chart's `appVersion` (argocd/charts/garage) by the group_vars comment alone · `none — a hand bump; no Renovate manager reads these group_vars literals` | 👤 a hand edit, normally beside a re-vendor of the in-cluster chart (the lockstep comment in the group_vars file) — nothing proposes it and nothing checks the two agree | 👤 a human authors it (no proposer); the bot review is the only reader — `/ansible/` is unowned since the ADR-128 trial; no `ci` step exercises the playbook | ⚠ a human `ansible/garage-backup.yml` re-run (idempotent, docs/longhorn-backup.md) — a merge deploys nothing, and nothing records the version the LXC runs. Unproposed, so no armed drift (S9); the box as the ansible applier (ADR-152, ROADMAP §Deploy paths) would take it with Matchbox | ⚠ liveness only — `LonghornBackupTargetDown` (blackbox `/health`) and `LonghornBackupStale` (argocd/resources/longhorn-backup/) fire on a broken target, never on a git-vs-live version split | 👤 `git revert` + the playbook re-run; the backups themselves are the data at stake — a Garage downgrade across a metadata-format change is not a revert | 👤 the in-cluster Garage runs the same release first (lockstep comment) — the de-facto canary for the binary; the LXC itself has no second instance | — never | 1 (1) | no — 2 ⚠ column(s), 1 ⚠ row(s), never proven |

#### Per dependency — the register

Columns P/G/D/Det/R/C are the class's proposer / merge gate / deploy edge / detector / revert / canary; a cell carries text only where the dependency differs from its class. Last proven = the newest merged proposer PR whose diff named the dependency (class 6: the capability ledger).

| Class | Dependency | Version | Pinned in | P | G | D | Det | R | C | Last proven E2E |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `argo-events` | 2.4.27 | `argocd/platform/argo-events.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-04 ([#2223](https://github.com/teststuffstash/homelab/pull/2223)) |
| 1 | `argo-rollouts` | 2.43.8 | `argocd/platform/argo-rollouts.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 1 | `argo-workflows` | 2.0.16 | `argocd/platform/argo-workflows.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-30 ([#3035](https://github.com/teststuffstash/homelab/pull/3035)) |
| 1 | `cert-manager` | v1.21.3 | `argocd/platform/cert-manager.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-30 ([#3046](https://github.com/teststuffstash/homelab/pull/3046)) |
| 1 | `cloudnative-pg` | 0.29.1 | `argocd/platform/cnpg-operator.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-05 ([#2239](https://github.com/teststuffstash/homelab/pull/2239)) |
| 1 | `crossplane` | 2.4.3 | `argocd/platform/crossplane.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-24 ([#2819](https://github.com/teststuffstash/homelab/pull/2819)) |
| 1 | `external-secrets` | 2.14.0 | `argocd/platform/eso-operator.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-30 ([#3047](https://github.com/teststuffstash/homelab/pull/3047)) |
| 1 | `forgejo` | 17.3.2 | `argocd/platform/forgejo.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-26 ([#2944](https://github.com/teststuffstash/homelab/pull/2944)) |
| 1 | `gateway-api` | v1.6.3 | `argocd/platform/gateway-api-crds.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 1 | `gha-runner-scale-set` | 0.15.1 | `argocd/platform/arc-runners-large.yaml`, `argocd/platform/arc-runners.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 1 | `gha-runner-scale-set-controller` | 0.15.1 | `argocd/platform/arc-controller.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 1 | `infisical-standalone` | 1.12.0 | `argocd/platform/infisical.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-29 ([#3010](https://github.com/teststuffstash/homelab/pull/3010)) |
| 1 | `kargo` | 1.12.5 | `argocd/platform/kargo.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#3006](https://github.com/teststuffstash/homelab/pull/3006)) |
| 1 | `kube-prometheus-stack` | 92.18.0 | `argocd/platform/kube-prometheus-stack.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-31 ([#3062](https://github.com/teststuffstash/homelab/pull/3062)) |
| 1 | `metrics-server` | 3.14.0 | `argocd/platform/metrics-server.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-09 ([#2396](https://github.com/teststuffstash/homelab/pull/2396)) |
| 1 | `plugin-barman-cloud` | 0.8.1 | `argocd/platform/plugin-barman-cloud.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 1 | `prometheus-operator-crds` | 32.0.2 | `argocd/platform/prometheus-operator-crds.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-30 ([#3036](https://github.com/teststuffstash/homelab/pull/3036)) |
| 2 | `cloudflare/cloudflared` | 2026.10.7@sha256:4955524aeaa3 | `argocd/resources/publicroute/composition.yaml` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-30 ([#3038](https://github.com/teststuffstash/homelab/pull/3038)) |
| 2 | `docker.io/grafana/alloy` | v1.21.3 | `argocd/resources/loki/alloy.yaml` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-29 ([#3034](https://github.com/teststuffstash/homelab/pull/3034)) |
| 2 | `docker.io/grafana/loki` | 3.7.9 | `argocd/resources/loki/loki.yaml` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-21 ([#2781](https://github.com/teststuffstash/homelab/pull/2781)) |
| 2 | `docker.io/library/alpine` | 3.24 | `argocd/resources/node-fstrim/fstrim.yaml` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-04 ([#2230](https://github.com/teststuffstash/homelab/pull/2230)) |
| 2 | `docker.io/library/busybox` | 1.38.0@sha256:a46257e06c82 | `argocd/resources/loki/kmsg-reader.yaml`, `argocd/resources/runner-image-prepull/daemonset.yaml` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-04 ([#2233](https://github.com/teststuffstash/homelab/pull/2233)) |
| 2 | `docker.io/library/nginx` | 1.31-alpine | `argocd/resources/registry/registry-fs.yaml` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-05 ([#2247](https://github.com/teststuffstash/homelab/pull/2247)) |
| 2 | `docker.io/library/python` | 3.15-slim, 3.15-slim@sha256:fd2aef5e0d84 | `argocd/resources/cloudflare-exporter/credential-expiry-probe-deployment.yaml`, `argocd/resources/cloudflare-exporter/edge-probe-deployment.yaml`, `argocd/resources/cloudflare-exporter/spend-probe-deployment.yaml` +8 | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-28 ([#2992](https://github.com/teststuffstash/homelab/pull/2992)) |
| 2 | `docker.io/library/registry` | 3.1.2 | `argocd/resources/registry-cache/mirror-docker-io.yaml`, `argocd/resources/registry-cache/mirror-ghcr.yaml`, `argocd/resources/registry-cache/mirror-mcr.yaml` +2 | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-06 ([#2297](https://github.com/teststuffstash/homelab/pull/2297)) |
| 2 | `docker.io/nginxinc/nginx-unprivileged` | 1.31-alpine | `argocd/resources/cf-api-proxy/deployment.yaml`, `argocd/resources/devbox-search/deployment.yaml`, `argocd/resources/nix-cache/deployment.yaml` +2 | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-05 ([#2248](https://github.com/teststuffstash/homelab/pull/2248)) |
| 2 | `docker.io/otel/opentelemetry-collector-contrib` | 0.165.0 | `argocd/resources/otel-collector/deployment.yaml` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-27 ([#2965](https://github.com/teststuffstash/homelab/pull/2965)) |
| 2 | `docker.io/prom/pushgateway` | v1.11.5 | `argocd/resources/pushgateway/deployment.yaml` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-28 ([#2999](https://github.com/teststuffstash/homelab/pull/2999)) |
| 2 | `docker.io/prometheuscommunity/smartctl-exporter` | v0.15.0@sha256:a76e08dbf5db | `argocd/resources/smartctl-exporter/daemonset.yaml` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-13 ([#2530](https://github.com/teststuffstash/homelab/pull/2530)) |
| 2 | `ghcr.io/k3d-io/k3d` | 5-dind@sha256:ee3872700ed0 | `agents/images.env` | ⚠ no Renovate manager reads `agents/images.env` (`AGENT_DIND_IMAGE`) | ✅ | ✅ | ✅ | 👤 | 👤 | — never |
| 2 | `ghcr.io/lablabs/cloudflare_exporter` | 0.2.3@sha256:6bf84a81725c | `argocd/resources/cloudflare-exporter/deployment.yaml` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | — never |
| 2 | `quay.io/brancz/kube-rbac-proxy` | v0.23.1 | `argocd/resources/loki/loki-rbac-proxy.yaml` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-25 ([#2908](https://github.com/teststuffstash/homelab/pull/2908)) |
| 2 | `quay.io/prometheus/blackbox-exporter` | v0.29.1 | `argocd/resources/blackbox/blackbox.yaml` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-21 ([#2802](https://github.com/teststuffstash/homelab/pull/2802)) |
| 2 | `registry.teststuff.net/games` | main | `argocd/resources/games/games.yaml` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | — never |
| 2 | `registry.teststuff.net/kindergarten` | main | `argocd/resources/kindergarten/kindergarten.yaml` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | — never |
| 2 | `registry.teststuff.net/school` | main | `argocd/resources/school/school.yaml` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | — never |
| 3 | `agent-base` | `AGENT_BASE_IMAGE`=2026.11.11-gb111711ac6a7; 1 manifest ref(s) | `agents/images.env`, `argocd/resources/agentstack/composition.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-30 ([#3042](https://github.com/teststuffstash/homelab/pull/3042)) |
| 3 | `agent-coordinator` | `AGENT_COORDINATOR_IMAGE`=2026.11.11-g0ba770de8d02; 34 manifest ref(s) | `agents/coordinator/coordinate-argo.yaml`, `agents/coordinator/corpus-dispatch-argo.yaml`, `agents/coordinator/deep-dig-argo.yaml` +23 | ✅ | ✅ | ⚠ 4 ref(s) NOT at the images.env pin (1× 2026.10.10-gd303a3b5bd8d, 3× 2026.10.5-gca94f4a2dd99) — the deploy-pin sweep misses them | ✅ | ✅ | 👤 | 2026-10-31 ([#3059](https://github.com/teststuffstash/homelab/pull/3059)) |
| 3 | `agent-gateway` | 2026.11.11-g477495f15753 (×1) | `argocd/resources/agent-gateway/deployment.yaml`, `argocd/resources/agent-gateway/kustomization.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-30 ([#3041](https://github.com/teststuffstash/homelab/pull/3041)) |
| 3 | `cchv-server` | v1.18.0 (×1) | `agents/coordinator/transcripts-viewer.yaml` | ⚠ a hand pin — the viewer image is built from the upstream cchv tag by hand (agents/coordinator/transcripts-viewer.yaml header); no deploy-pin job, no Renovate manager for a first-party tag | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 3 | `homelab/arc-runner` | 2026.11.10-g9ca9f3195fa2 (×3) | `agents/coordinator/sentinel-argo.yaml`, `argocd/resources/runner-image-prepull/daemonset.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-30 ([#3043](https://github.com/teststuffstash/homelab/pull/3043)) |
| 4 | `argo-cd` | 10.12.1 | `tofu/argocd.tf`, `tofu/variables.tf` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-30 ([#3039](https://github.com/teststuffstash/homelab/pull/3039)) |
| 4 | `argocd-apps` | 2.0.7 | `tofu/argocd.tf`, `tofu/variables.tf` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-23 ([#2874](https://github.com/teststuffstash/homelab/pull/2874)) |
| 4 | `longhorn` | 1.13.0 | `tofu/longhorn.tf` | ✅ | ✅ | ✅ | ✅ | 👤 | 👤 | 2026-10-10 ([#2487](https://github.com/teststuffstash/homelab/pull/2487)) |
| 5 | `bpg/proxmox` | 0.120.0 (`~> 0.120`) | `tofu/versions.tf`, `tofu/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-29 ([#3014](https://github.com/teststuffstash/homelab/pull/3014)) |
| 5 | `bpg/proxmox` | 0.120.0 (`~> 0.120`) | `tofu/provisioning/versions.tf`, `tofu/provisioning/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-29 ([#3014](https://github.com/teststuffstash/homelab/pull/3014)) |
| 5 | `cloudflare/cloudflare` | 5.28.1 (`~> 5.0`) | `tofu/cloudflare/versions.tf`, `tofu/cloudflare/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2985](https://github.com/teststuffstash/homelab/pull/2985)) |
| 5 | `cloudflare/cloudflare` | 5.25.0 (`~> 5.0`) | `tofu/cloudflare-token/versions.tf`, `tofu/cloudflare-token/.terraform.lock.hcl` | ⚠ DISABLED for this root (renovate-global.json, #2026): `tofu/cloudflare-token` is the one-shot admin-token root the box never plans — moved by hand with a jail plan | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 5 | `hashicorp/helm` | 3.3.0 (`~> 3.0`) | `tofu/versions.tf`, `tofu/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-02 ([#2046](https://github.com/teststuffstash/homelab/pull/2046)) |
| 5 | `hashicorp/kubernetes` | 3.4.0 (`~> 3.0`) | `tofu/versions.tf`, `tofu/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-24 ([#2876](https://github.com/teststuffstash/homelab/pull/2876)) |
| 5 | `hashicorp/kubernetes` | 3.4.0 (`~> 3.0`) | `tofu/cloudflare/versions.tf`, `tofu/cloudflare/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-24 ([#2876](https://github.com/teststuffstash/homelab/pull/2876)) |
| 5 | `hashicorp/kubernetes` | 2.38.0 (`~> 2.31`) | `tofu/infisical/versions.tf`, `tofu/infisical/.terraform.lock.hcl` | ⚠ DISABLED for this root (renovate-global.json, #2026): the box does not plan `tofu/infisical` — moved by hand with a jail plan | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 5 | `hashicorp/random` | 3.9.1 (`~> 3.6`) | `tofu/versions.tf`, `tofu/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-04 ([#2213](https://github.com/teststuffstash/homelab/pull/2213)) |
| 5 | `hashicorp/tls` | 4.4.2 (`~> 4.0`) | `tofu/cloudflare/versions.tf`, `tofu/cloudflare/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#3000](https://github.com/teststuffstash/homelab/pull/3000)) |
| 5 | `Infisical/infisical` | 0.19.32 (`~> 0.19`) | `tofu/infisical/versions.tf`, `tofu/infisical/.terraform.lock.hcl` | ⚠ DISABLED for this root (renovate-global.json, #2026): the box does not plan `tofu/infisical` (policy foreign_roots), so a bump here has no gate — moved by hand with a jail plan; the root is slated to leave tofu | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-09-27 ([#1984](https://github.com/teststuffstash/homelab/pull/1984)) |
| 5 | `integrations/github` | 6.13.0 (`~> 6.0`) | `tofu/github/versions.tf`, `tofu/github/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-09-27 ([#1983](https://github.com/teststuffstash/homelab/pull/1983)) |
| 5 | `poseidon/matchbox` | 0.5.4 (`~> 0.5`) | `tofu/provisioning/versions.tf`, `tofu/provisioning/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 5 | `siderolabs/talos` | 0.12.0 (`~> 0.12`) | `tofu/versions.tf`, `tofu/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-09-28 ([#2096](https://github.com/teststuffstash/homelab/pull/2096)) |
| 6 | `Cilium` | 1.20.4 | `tofu/variables.tf` | 👤 | 👤 | 👤 NOT box-applied — a merge is not the deploy edge for Cilium: the seat runs the bump in a declared window through `helm-evidence` (docs/runbook.md §"Class-6 bump: Cilium", FU-319); last done 2026-10-31 (#3061 1.19.10, then #3054 1.20.4) | ✅ | 👤 | ✅ | 2026-09-22 (capability ledger — Talos install rollout, workers + CPs (`mgmt-reconcile`): #1879: 13/13 v1.14.1 09:43→13:17Z, canary per type, CPs last) |
| 6 | `Kubernetes` | v1.36.1 | `tofu/variables.tf` | 👤 | 👤 | ✅ | ✅ | 👤 | ✅ | 2026-09-22 (capability ledger — Talos install rollout, workers + CPs (`mgmt-reconcile`): #1879: 13/13 v1.14.1 09:43→13:17Z, canary per type, CPs last) |
| 6 | `Talos (control planes)` | v1.14.1 | `tofu/variables.tf` | 👤 | 👤 | ✅ | ✅ | 👤 | ✅ | 2026-09-22 (capability ledger — Talos install rollout, workers + CPs (`mgmt-reconcile`): #1879: 13/13 v1.14.1 09:43→13:17Z, canary per type, CPs last) |
| 6 | `Talos (workers)` | v1.14.1 | `tofu/variables.tf` | 👤 | 👤 | ✅ | ✅ | 👤 | ✅ | 2026-09-22 (capability ledger — Talos install rollout, workers + CPs (`mgmt-reconcile`): #1879: 13/13 v1.14.1 09:43→13:17Z, canary per type, CPs last) |
| 7 | `age` | 1.3.2 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `ansible` | 2.21.5 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 7 | `argo-workflows` | 4.0.5 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `argocd` | 3.5.6 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `awscli2` | 2.36.31 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `bind` | 9.20.30 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `cilium-cli` | 0.19.7 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `claude-code` | 2.1.316 | `version-sets/devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 7 | `cloudflared` | 2026.10.3 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `crossplane-cli` | 2.4.1 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 7 | `curl` | 8.22.0 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `deno` | 2.9.8 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `gh` | 2.103.3 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `gitleaks` | 8.30.1 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `hubble` | 1.20.2 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `infisical` | 0.44.2 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `jq` | 1.8.2 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `k9s` | 0.51.0 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `keepassxc` | 2.8.0 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `kind` | 0.33.0 | `version-sets/devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 7 | `kubeconform` | 0.8.0 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `kubectl` | 1.37.2 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `kubectl` | 1.36.3 | `version-sets/devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 7 | `kubernetes-helm` | 4.3.1 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `kyverno` | 1.19.2 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `netcat-gnu` | 0.7.1 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `nixpkgs-unstable` | nixpkgs@5c9de89ec55b | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 7 | `nixpkgs-unstable` | nixpkgs@5c9de89ec55b | `version-sets/devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 7 | `nmap` | 7.991 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `nodejs_22` | 22.23.4 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 7 | `openssl` | 3.5.9 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `opentofu` | 1.13.2 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `prometheus` | 3.15.1 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `python3` | 3.14.8 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `qrencode` | 4.1.1 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `renovate` | 44.181.0 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `shellcheck` | 0.11.0 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 7 | `sops` | 3.13.3 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `talosctl` | 1.14.5 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `tea` | 0.16.0 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `terraform-providers.cloudflare_cloudflare` | 5.23.0 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 7 | `wireguard-tools` | 1.0.20260223 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 7 | `yq-go` | 4.54.1 | `devbox.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-28 ([#2919](https://github.com/teststuffstash/homelab/pull/2919)) |
| 8 | `actions/checkout` | 3d3c42e5aac5ba805825da76410c181273ba90b1 (v7) | `.github/workflows/ci.yaml`, `.github/workflows/devbox-cache.reusable.yml`, `.github/workflows/devbox-update.yaml` +5 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-09-27 ([#2038](https://github.com/teststuffstash/homelab/pull/2038)) |
| 8 | `actions/create-github-app-token` | 64ab729a6294000f5aa4a4bc0b73d1f32bc45510 (v3) | `.github/workflows/devbox-update.yaml`, `.github/workflows/gateway-image.yaml`, `.github/workflows/renovate-approve.reusable.yml` +3 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-10-20 ([#2747](https://github.com/teststuffstash/homelab/pull/2747)) |
| 8 | `docker/login-action` | 81c6f93d4bc991e510b342a00b419b3bb4efc5c6 (v4) | `.github/workflows/devbox-cache.reusable.yml`, `.github/workflows/gateway-image.yaml`, `.github/workflows/runner-image.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-10-30 ([#3037](https://github.com/teststuffstash/homelab/pull/3037)) |
| 8 | `docker/setup-buildx-action` | f87e5991a6d7451dcb8d9637bfbc97413f497069 (v4) | `.github/workflows/gateway-image.yaml`, `.github/workflows/runner-image.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-09-27 ([#2038](https://github.com/teststuffstash/homelab/pull/2038)) |
| 8 | `renovatebot/github-action` | 1c0cf989c02653fba0efe7ca5772338860ca71dc (v46.3.12) | `.github/workflows/renovate.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-10-26 ([#2922](https://github.com/teststuffstash/homelab/pull/2922)) |
| 9 | `oxlorg.opnsense` | 26.1.11 | `ansible/collections/requirements.yml` | ✅ | ✅ | ⚠ | ⚠ | 👤 | 👤 | 2026-09-29 ([#2033](https://github.com/teststuffstash/homelab/pull/2033)) |
| 10 | `ghcr.io/actions/actions-runner` | 2.338.2 | `docker/arc-runner/Dockerfile` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-26 ([#2945](https://github.com/teststuffstash/homelab/pull/2945)) |
| 10 | `jetify-com/devbox` | 0.19.0 | `docker/arc-runner/Dockerfile` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-02 ([#2186](https://github.com/teststuffstash/homelab/pull/2186)) |
| 10 | `NixOS/nix` | 2.35.1 | `docker/arc-runner/Dockerfile` | ⚠ the custom manager resolves nothing — `Found no results from datasource that look like a version (dependency=NixOS/nix)` (Renovate log read 2026-08-01, docs/dependency-upgrades.md §Ground truth; not re-read since — the ARG has not moved by a Renovate PR as of 2026-11-12); fix or remove, rides homelab#1985 | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 12 | `linkedom` | 0.18.15 | `scripts/mermaid-lint/deno.json` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-10-28 ([#2993](https://github.com/teststuffstash/homelab/pull/2993)) |
| 12 | `mermaid` | 12.3.0 | `scripts/mermaid-lint/deno.json` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-10-20 ([#2755](https://github.com/teststuffstash/homelab/pull/2755)) |
| 13 | `nix-community/disko` | cedd626e11b6 | `mgmt/nixos/flake.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 13 | `NixOS/nixpkgs` | nixos-26.05@9bb52223f4f6 | `mgmt/nixos/flake.lock` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 14 | `OPNsense NANO_VERSION (birth image)` | 26.7 | `scripts/opnsense-test-vm-bootstrap.sh`, `tofu/opnsense-test.tf` | 👤 | 👤 | 👤 | ⚠ | ⚠ | 👤 | — never |
| 14 | `OPNsense SERIES (series head)` | 26.7 | `scripts/opnsense-test-vm-bootstrap.sh` | 👤 | 👤 | 👤 | ⚠ | ⚠ | 👤 | — never |
| 15 | `poseidon/matchbox` | v0.11.0 | `ansible/group_vars/matchbox.yml` | 👤 | 👤 | ✅ | ✅ | 👤 | 👤 | — never |
| 15 | `siderolabs/talos (PXE assets)` | v1.14.1 | `ansible/group_vars/matchbox.yml` | 👤 | 👤 | ✅ | ✅ | 👤 | 👤 | — never |
| 17 | `helm/helm` | 4.3.1 | `scripts/upstream-alerts-refresh.sh` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | 2026-10-22 ([#2804](https://github.com/teststuffstash/homelab/pull/2804)) |
| 18 | `kyverno-policies` | 3.9.2 | `scripts/component-check.sh` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 18 | `kyverno/policies` | release-1.19 @ 282e77f6d54e | `scripts/vendor-kyverno-policies.sh` | ✅ | ✅ | ✅ | ✅ | ✅ | 👤 | — never |
| 19 | `deuxfleurs/garage (backup LXC)` | v2.3.0 | `ansible/group_vars/garage_backup.yml` | 👤 | 👤 | ⚠ | ⚠ | 👤 | 👤 | — never |

<!-- END GENERATED dependency-coverage -->

**The owner rule (homelab#1992 — the capability-ledger rule, generalized from box surfaces to
dependency classes):** a CODEOWNER leaves a dependency class only when the class's row above is
**complete** — all seven columns filled (✅ or 👤, no ⚠) and the newest proof ≤90 days old — and no
column is 👤 (a human by ruling is filled, not a gap: the owner stays by design, as on the router
and the substrate). A class enters "complete" with its first proven end-to-end pass, never with a
belief about what the machinery could do. The table is **generated, never hand-written**
(`scripts/dependency-coverage.py`, the `machines/generate.py` pattern): the rulings live in
[`dependency-classes.yaml`](dependency-classes.yaml), the dependencies are extracted from the
repo's own files the way Renovate's managers read them, and the proof column is read from GitHub
(the newest merged proposer PR whose diff named the dependency) or, for class 6, from the
[capability ledger](management-box.md#the-capability-ledger--what-the-box-has-been-tested-doing-on-its-own-fu-097).
`devbox run dependency-coverage` regenerates (`-- --offline` from the committed proofs, `-- --check`
is the currency gate); the same facts ship to the github-exporter as `dependency-coverage.json`, so
the table alerts instead of rotting: `github_dependency_coverage_gap_rows` (rows with a ⚠ column),
`github_dependency_coverage_last_proven_timestamp` (→ `DependencyClassProofStale`) and
`github_renovate_last_pr_timestamp` (→ `RenovateSilent`).

**How current the block is.** Nothing regenerates it on a merge (gap G8), so it is as fresh as the
last hand run. The pins were re-read from the repo on 2026-11-12. The proof column was last
refreshed from GitHub on 2026-10-31: a class or dependency that reads an October proof may have a
newer one (class 4's argo-cd merged again on 2026-11-12, #3279), and "never" on classes 13 and 18
is as of that date. Class 11's members live in three other repos and are not extractable here —
§Version SETS carries the cross-repo half by hand.

## What is still manual, and what it waits on

One row per class or lane where a person still proposes, reviews, merges, applies, reverts or
watches. Read 2026-11-12 from the register above, §Last proven end to end, the gap register,
homelab#1988/#1991 and the
[capability ledger](management-box.md#the-capability-ledger--what-the-box-has-been-tested-doing-on-its-own-fu-097).
Mechanism lives in the linked places; this table only says who acts and why. "By ruling" means the
operator decided a person stays — nothing is being built to remove that step.

| Class / lane | What a person does today | Why (the missing piece) | Waits on | Fully automated would be |
|---|---|---|---|---|
| **6 — cluster substrate** (Talos, Kubernetes, Cilium) | Writes the bump PR, reads it as codeowner, runs it in an attended window; Cilium is applied by the seat through `helm-evidence` (a merge is not its deploy edge); a revert is a human commit | By ruling: Renovate stays off the class until a few attended bumps have gone through, and a Kubernetes minor needs a recreate-from-git drill first | FU-319 (Cilium done 2026-10-31; Kubernetes 1.37 = draft PR #3056; Talos 1.15 not started), then homelab#1988's substrate proposer row | Renovate proposes, the box rolls canary-first under a lease |
| **Base-image majors** of first-party images (agent-coordinator first) | Arms and merges each major after the migration lens approves (agent-coordinator#29, node 26, merged under the operator's login 2026-10-31) | No standing Renovate rule arms them; the previous-tag revert chain behind them is built but has only run dry | homelab#1988: the `.github/renovate-global.json` rule (operator-direct file) | The lens's approval completes the merge; a bad image is reverted to the previous tag by the chain |
| **1, 2 — un-armed majors** (every chart except argo-workflows, kube-prometheus-stack and its CRD chart; every in-cluster image) | Merges after the lens parks the PR as `major/awaiting-human`; reverts a class-2 image by hand (`git revert`) | A CRD or schema downgrade cannot be undone by a revert, so a chart is armed only once a drilled revert exists for it (ADR-141, ADR-149) | By ruling, chart by chart on evidence — no open item | Each chart armed behind its own drilled revert |
| **4 — longhorn majors**, and any class-4 revert | Merges a longhorn major; after a box STOP, reverts and applies by hand | By ruling: Longhorn refuses downgrades (the rollback is the preflight restore point) and the box only moves forward | By ruling — no open item | Not planned |
| **5 — providers the box cannot gate** | Bumps `tofu/infisical` and `tofu/cloudflare-token` providers by hand with a jail plan; reads any provider PR whose plan is not empty; applies `tofu/github` (host only), `tofu/cloudflare` and `tofu/provisioning` by hand | The box holds no state for the two roots; a non-empty plan is the one provider PR a person is meant to see; applies outside `main` need credentials the box does not hold | `tofu/github` applies are operator-only by ruling; box applies for the other roots and `tofu/infisical` leaving tofu are not tracked (no FU matches `tofu/infisical`; FU-012 covers only the box's own credentials) | Every root planned and applied by the box, or gone from tofu |
| **7 — the opentofu major** in the weekly lock | Merges it | By ruling: the first apply stamps the state and an older binary cannot read it back, so a lock revert is not a revert | By ruling — no open item | Not planned |
| **A red or stalled armed bump** (any mechanical lane) | Diagnoses it once the loop gives up — the weekly lock PR #3233 sat red a day on 2026-11-09/10 | The fix ride changed nothing; since ADR-162 the scan retries a dead run and hands a ride that changes nothing to a person | By design (ADR-162); the ride's first working proof rides homelab#1985 (gap G12b) | The worker adapts the PR in place, or closes it and files the gap |
| **9 — router config** (OPNsense plays, the `oxlorg.opnsense` collection) | Converges the CARP MASTER per node (`scripts/opnsense-router-node.sh converge`); reverts by `git revert` + a re-converge. **Also the BACKUP, for now:** the box converges it by policy but has refused since 2026-10-31 (live drift on the BACKUP's Kea config), so router merges reach neither node until a person converges it once | The rolling path through `carp-maintenance` is not built and the flip from "human-applied" is not ruled; `--check` cannot see advanced-settings drift; the box will not converge over live drift it did not make | ROADMAP §Deploy paths, program step 3 (ADR-152); the BACKUP refusal is FU-297 next (0) | The box converges BACKUP then MASTER under a lease with a node-local restore armed |
| **14 — router firmware** | Runs `firmware/check` by hand to learn an update exists, then update/upgrade per node (BACKUP first); a major is attended | No currency belt reads `firmware/status`; no revert is written down (a `qm snapshot` exists) | ROADMAP §Deploy paths, step 1's "Next" (the belt) and step 4 (the box run) | A belt raises "behind"; the box updates test VM → BACKUP → MASTER under one lease |
| **15 — Matchbox** | Hand-edits the pin and reads the PR as codeowner (the box applies it once merged) | No Renovate manager reads the `group_vars` literals | Not tracked (no FU matches `matchbox_version`) | Renovate proposes the pin; the rest already runs |
| **16 — Proxmox hosts** | Runs `ansible/pve-upgrade.yml` and the reboots (`devbox run host-maint`), one host per attended window | Nothing in git declares the intent; a host reboot takes its guests down | FU-306 (the per-guest verb on the box), then compute High Availability (ROADMAP §"HA model", layer 3); ADR-152 keeps it out of the box program | The box drains, upgrades and reboots one host at a time |
| **19 — backup Garage LXC** | Hand-edits the version beside the in-cluster chart re-vendor, then re-runs `ansible/garage-backup.yml` | No proposer, no applier row, and no detector for a git-versus-live version split | Not tracked; the fit is an `apply_ansible` row in the box policy (ADR-152) | The box applies the play on merge and its `--check` belt sees a split |
| **3 — hand pins** (`cchv-server`; four agent-coordinator refs the deploy-pin sweep misses) | Bumps the viewer image by hand; would have to fix the four stale refs | No deploy-pin job builds the viewer; why the sweep misses the four refs is not diagnosed | Rides homelab#1985 | Every first-party ref moved by a deploy-pin PR |
| **2 and 10 — pins no manager reads** (`ghcr.io/k3d-io/k3d` in `agents/images.env`; `NIX_VERSION` in the arc-runner image) | Bumps them by hand, when someone notices | No manager reads `images.env`; the `NIX_VERSION` manager resolved nothing (2026-08-01) | Rides homelab#1985 | A working manager on each line |
| **11 — the seat's own claude-code** (the jail image) | Rebuilds the jail image on the host | The jail is host-built by nature; the version-set belt watches the lag (`VersionSetMembersDisagree` on claude-code is firing 2026-11-12) | Nothing — a person owns their own workstation | — |
| **Version sets without one source** (the devbox binary across runner / jail / box; Python per service) | Moves the members together by hand | The members live in different repos and files and nothing groups them | FU-240 (devbox); the Python set is watched only by the migration lens | One source, one bump (§Version SETS) |
| **The register itself** | Runs `devbox run dependency-coverage` and commits the result | No job regenerates it after a pin merge (gap G8) | homelab#1985 (the post-merge regenerator, an operator call) | A master-push job commits the regenerated pair |

**Fully hands-off today** — proposed, gated, merged, deployed and (where a revert exists) reverted
with no person on the path:

- **Class 8, GitHub Actions** — every update type, with the drilled pin-revert chain behind it.
- **Class 12, the Deno CI tooling** — patch, minor and mermaid majors.
- **Class 1 charts**, patch and minor, and the armed majors (argo-workflows, kube-prometheus-stack
  with its CRD chart) — ArgoCD deploys the merge; the chart-revert receiver and the upgrade lease
  are the reverts.
- **Class 2 images**, digest, patch and minor (the revert stays by hand, above).
- **Class 3 deploy-pin PRs** — agent-base, agent-coordinator, agent-gateway, arc-runner.
- **Class 4** argo-cd and argocd-apps at every update type, longhorn patch and minor — the merge is
  the deploy, the box applies it.
- **Class 5 provider pins** on the roots the box plans, when the plan is empty.
- **Class 7, the weekly devbox lock**, majors included (opentofu excepted) — its revert chain
  carried a real regression on 2026-11-10.
- **Class 10** runner base image and `DEVBOX_VERSION`, and **class 17** the Renovate helm pin.
- **Class 13**, the box's flake lock, moves in the weekly lock PR and the box re-activates itself
  hourly; the register's proof column has not caught up, and the activation was not re-read for
  this pass. **Class 18** has the lane but no bump has used it yet.
- **Class 15 applies** — the box, on merge.

### Last proven end to end — per LANE, org-wide (hand-kept)

The generated table above carries homelab's own proof column per class and per dependency. This
table is its hand-kept companion for what the generator does not read: **other repos' merges,
drills and negative proofs, one row per LANE** ([`renovate.md`](renovate.md) §"The automerge vs
review split", ADR-141). Rows whose evidence is a plain homelab merge live in the generated column
and are not repeated here. Minute-by-minute drill timelines are on homelab#1991 and #1990.

| Class → lane | Last proven end to end | Evidence |
|---|---|---|
| **GitHub Actions, pin/minor** → grouped `automerge` (reflex approves, CI at head) | **2026-09-27** | agent-runtime#157 + openrouter-operator#77 merged on their own once `/.github/workflows/` was un-owned |
| **GitHub Actions, major** → the same grouped lane (no lens until a dependency graduates, ADR-141) | **2026-09-27** | agent-coordinator#22 auto-merged, no human, no lens |
| **Actions pin, post-merge rollback** → the `workflow-pin-revert` chain | **2026-09-27 (drill)** | agent-coordinator#20 (deliberate bad pin) → `GithubWorkflowRunFailed` → revert #21 opened by the App, reflex-approved, merged; about 3.5 min from alert to merged revert, no human |
| **terraform providers, patch/minor** → the box's empty plan gates a mechanical `automerge` (ADR-131) | **2026-09-28** | #2075 (proxmox) and #2096 (talos) merged by Renovate on the reflex's approval + `management-sentinel` green (`+0 ~0 -0`), no human |
| **terraform provider major** → armed `major`, the lens's approval completes the merge | ❌ **not yet** (read 2026-11-12) | armed 2026-10-04 (ADR-141); no provider major has arrived — the one proof homelab#1991 still waits for |
| **terraform provider pin, post-merge rollback** → the `tofu-provider-revert` chain | **2026-10-04 (drill)** | synthetic `MgmtApplyErroredOnNewProvider` → revert #2209 opened by the App, reflex-approved, sentinel green, merged, box applied; no human. The box-side detector itself is fixture-proven only |
| **terraform docker-image bump on a `kubernetes_deployment`, post-merge rollback** → the `tofu-image-revert` chain | **2026-09-28 (drill)** | #2085 (bad tag) → `KubeDeploymentRolloutStuck` → revert #2086 merged 6.5 min after the alert, no human (homelab#1988, 2026-09-28 comment) |
| **tofu helm chart major** (class 4: argo-cd, argocd-apps) → armed `major`, lens, the box bracket deploys | **2026-10-11** | #2488 (argo-cd 9.7.1 → 10.9.6): lens-approved, merged, box bracket CONFIRMED, 81/81 Applications Healthy+Synced |
| **Helm charts / in-cluster images** (classes 1, 2) → `deps-review` / `automerge` | **2026-10-04** | the first wave: #2220 (digest, `automerge`), #2223 (argo-events, `deps-review`) and four more, every ArgoCD sync Healthy. Unproven: a `deps-review` CHANGES_REQUESTED → worker-adapts round on a chart |
| **chart major behind the lens** (kube-prometheus-stack) | **2026-10-13** | #2550 (kps → v92): `major` label, lens APPROVED, merged by Renovate, no human |
| **chart whose cone holds its own detector, post-merge rollback** → the ⚓ upgrade lease (ADR-150) | **2026-10-10 (drill)** | #2423 armed and confirmed its own lease; a synthetic expired lease → revert #2441 opened by `homelab-sentinel`, reflex-approved, merged, ArgoCD back on the previous version Synced/Healthy, CRDs untouched; no hand act on the chain. Renovate's re-proposal of the reverted version (#2486) went red on `pin-only-lint` check (h), as designed |
| **argo-workflows chart, post-merge rollback** → the `chart-revert` receiver (ADR-149) | **2026-10-05 (drill)** | #2276 bump → synthetic `ArgoControllerSilent` → #2279 revert merged and synced in 10 min 12 s, no human |
| **devbox lock major** → armed `major`, the lens's approval completes the merge | **2026-10-26** | agent-runtime#183 (opencode 1.19.0 → 2.1.1): opened `lock-lane: arm`, lens APPROVED, merged by Renovate, no human |
| **devbox lock, post-merge rollback** → the `workflow-pin-revert` lock shape + `pin-only-lint` check (i) | **2026-11-10 (real regression)** | #3233 (the weekly lock) merged 21:32Z and broke CI on master (a package the binary cache did not carry) → revert #3245 (`revert-lock-6b0ba075`) opened by the App 21:51Z, reflex-approved, merged by the App 22:31Z. One hand act afterwards, off the chain: the revert blamed five packages whose versions had merely moved, and the seat appended `exonerated-locks:` to free them. The class fix is #3251 (the weekly job holds a package the cache lacks). Drilled hands-off before that on 2026-10-11 (#2503 → #2504, 12 min) |
| **pre-commit hooks, patch/minor** → `automerge` | **2026-09-27** | openrouter-operator#73 merged on the bot approval once the hook file was carved out of that repo's CODEOWNERS |
| **Python runtime deps, patch/minor** → `deps-review`, a worker adapts on the `renovate/*` branch | **2026-10-12** | sleep-tracking#191: red for days, the worker pushed the fix to the Renovate branch, reflex APPROVED, merged |
| **base-image major** → the lens, then a person arms it | **2026-10-31** | agent-coordinator#29 (node 24 → 26): lens APPROVED, merged 15:41Z under the operator's login, build smoke green, deploy-pin #3059 auto-merged, loop workflows clean on the new image. Not yet merged by Renovate on a standing rule; the previous-tag revert (`revert-coord-<sha8>`, [design Part 7](designs/fu-1990-workflow-pin-revert.md)) has run only as a dry run — homelab#1988 |
| **substrate** (Talos, Kubernetes, Cilium) → never self-merges | ❌ **no Renovate proof** | hand-proposed by ruling: the 2026-09-22 box-run Talos rollout (ADR-132) and the 2026-10-31 attended Cilium bumps (FU-319) |

### Version SETS — what must move together (operator ruling 2026-09-27; owner #2014)

Some versions are used in several places and a bump in one place alone is worse than no bump. A
set is a cross-repo relation, so this list is hand-kept: the generated register carries each
in-repo member's pin and proof as its own row and knows nothing of the members in other repos.
homelab#2014 (closed 2026-10-31) gave the claude-code and kubectl/kind sets one source,
`version-sets/devbox.lock`; the other sets have none. Whether a set is in sync is a fact only this
table states:

| Set | Members and how each is set today | In sync? |
|---|---|---|
| **claude-code** | **source:** `version-sets/devbox.lock` (`claude-code@latest`), stamped by the weekly `devbox-update` homelab leg. Consumers read the stamp at build time: the worker image (agent-base), the coordinator + reviewer image (agent-coordinator), and the seat (claude-jail, at a hand host rebuild). A stamp change on master rings both cluster images' builds (`version-sets-dispatch.yaml`) | ⚠ read 2026-11-12: stamp 2.1.316, worker and coordinator images 2.1.316, the homelab seat 2.1.322 (ahead of the stamp); `VersionSetMembersDisagree{tool="claude-code"}` is firing. The seat moves only on a host rebuild — the belt (`argocd/resources/version-sets/`) watches the lag |
| **kubectl / kubernetes / kind** | fleet Kubernetes: `machines/machines.yaml` + `tofu/variables.tf`, box-run rollout; **image kubectl source:** `version-sets/devbox.lock` `kubectl@<fleet minor>` — the stamp rebinds to `kubernetes_version`'s minor on every pass; kubectl in repos and the seat: devbox `@latest` weekly (skew-watched, not bounded); kind: devbox `@latest` in the e2e repos + stamped | ✅ read 2026-11-12: fleet 1.36, stamp 1.36.3, worker and coordinator images 1.36.3, the jail 1.37.2 — inside the one-minor skew rule `VersionSetKubectlSkew` watches |
| **crossplane chart + engine digest** | chart `targetRevision` in `argocd/platform/crossplane.yaml` (Renovate `argocd` manager) + the `crossplane.io/engine-image-digest.<version>` annotation beside it that the docker-free render (`scripts/xr-render-lib.sh`) keys by chart version (regex customManager); `groupName: crossplane` → one PR. The chart rides no cooldown: the crossplane index re-stamps every entry's `created` on each publish, so a cooldown withheld the chart while the digest went out alone | ✅ one PR by rule; no grouped crossplane PR has been drawn since the cooldown fix (gap G15) |
| **kube-prometheus-stack chart + prometheus-operator CRDs** | chart `targetRevision` in `argocd/platform/kube-prometheus-stack.yaml` (`skipCrds: true`) + the `prometheus-operator-crds` Application (ADR-151); one Renovate group; the box belt `check_kps_crds` fails on skew | ✅ read 2026-11-12: chart 92.18.0, CRD chart 32.0.2, live CRDs and operator both v0.94.2. ⚠ the group can still split into a patch and a minor branch (gap G16) |
| **devbox / nix** | `DEVBOX_VERSION` / `NIX_VERSION` in the arc-runner image (regex-managed); devbox in the jail (`DEVBOX_USE_VERSION`); the box's closure; the host `/nix` | ⚠ read 2026-11-12: runner image 0.19.0 (Renovate, #3171), jail 0.18.3 — FU-240 |
| **python (per service)** | image `FROM python:X.Y-slim` (Renovate `dockerfile`, `deps-review`); `devbox.json` `python@X.Y` (hand — `devbox update` re-resolves `@latest` only); `pyproject.toml` `requires-python`, ruff `target-version`, mypy `python_version` (hand) | ❌ no source. openrouter-operator#80 (2026-09-27) moved the image to 3.14 with everything else on 3.11; the migration lens now names the set (`agents/lenses/migration.md` §Version SETS). Not re-read since |
| **platform component ↔ stack test pins** (ADR-158) | prod: Grafana = the one the kps chart deploys, Postgres = the CNPG cluster major; stacks: the image pinned in each stack's kind/e2e test manifests. **A window, not equality:** prod ≤ pin ≤ prod + 1 minor. Each stack's Renovate proposes over its test manifests; the migration lens gates. The kps / CNPG lane never waits for a stack | ⚠ prod Grafana is 13.3.0 (read 2026-11-12). Stack side as of 2026-10-31, not re-read: sleep-tracking 13.2.5 (behind), oracle-fleet e2e Grafana 11.3.0 and `postgres:16-alpine` (behind, no Renovate over `scripts/e2e/`) |

The cloudflared connector image was a set until 2026-10-26; it is one pin now
(`argocd/resources/publicroute/composition.yaml`), because its second member had no deploy edge
(gap G16's rule: an armed pin needs an automated deploy edge).

**The model to match:** `devbox-update.yaml` — one weekly job re-resolves every repo together, one
PR per repo. Anything that floats on its own cron is a tracked gap, not a solution.

### "Tofu" is not one class — the five roots differ in owner, credential and blast radius

Classes 4–6 span five state roots that need different rulings:

| Root | Credential | Ruling |
|---|---|---|
| `tofu/github` | org-admin PAT (applies, **host only**) + a read-only PAT on the management box (plans) | **Applies operator-only; plans automated** (ADR-131): state on Garage, the box plans every PR touching the root (`management-sentinel`) and reads drift with a read-only token |
| `tofu/cloudflare` | scoped CF token, in jail | **No pin a running thing consumes** — what stays is credential/singleton class (the mTLS client cert + hostname association, `wg`/`*.local`, the minutark bootstrap). Plans automated, applies by hand in the jail; its provider lockfile rides the box's provider-pin lane |
| `tofu/infisical` | Infisical creds | Slated to leave tofu for ESO/Crossplane — don't invest automation here; excluded from the provider manager |
| `tofu/provisioning` | PVE token | PXE content is **inert until the next netboot** — the safest root to automate; planned by the box, applied by hand |
| `tofu/` (main) | PVE token + talosconfig + kubeconfig + KeePass env | State and credentials live on the management box, which plans and applies it ([`management-box.md`](management-box.md) §MB2/§MB3); FU-012's open half is the box-scoped credential swap |

What is left in the main root is deliberate. kube-prometheus-stack, metrics-server, forgejo and
garage moved to `argocd/platform/` Applications (class 4 → class 1), which gave them a native
path→deploy edge. ArgoCD adopts a live Helm release silently as long as the Application name equals
the release name, and the empty-diff pre-flight (`helm template` → `kubectl diff -f -`) is the gate
that proves the adoption. What stays in tofu is class 4 (argo-cd, argocd-apps, longhorn) and
Cilium (class 6) — by ADR-005, the pieces ArgoCD needs in order to run — plus the substrate
(Proxmox, Talos, VMs, the image factory), and the raw-`kubernetes_*` residue, kept on purpose as
the management box's nondestructive test surface ([`management-box.md`](management-box.md) §The
test surface).

---

## What a full platform dependency upgrade should look like

Five stages. Which classes have which stage built is the register above; where a person still
stands in for a stage is §What is still manual.

### 1. Propose

- **Renovate opens the PR** against the global policy in
  [`renovate-global.json`](../.github/renovate-global.json): 7-day cooldown (security bypasses it;
  pins, digests and Docker tags are timestamp-optional — a tag without a release timestamp would
  otherwise sit pending forever), Actions SHA-pinned, OSV alerts on, every major labelled `major`
  (the lens marker) — the LANE is the blast class's (ADR-141).
- **The classification decides the lane, not the reviewer's mood:** digest/pin → `automerge`;
  runtime version bumps and base-image minors → `deps-review`; **every** major → `major` (the lens
  marker), un-armed unless a rule arms that dependency — EXCEPT GitHub Actions, where every update
  type rides the grouped `automerge` lane until a dependency graduates on evidence (ADR-141;
  [`renovate.md`](renovate.md) §"The automerge vs review split").
- **First-party artifacts never ride Renovate** — a `2026.<m>.<d>-g<sha>` version doesn't order, so
  the deploy-pin PR opens them (ADR-084).
- Which lane has actually carried a merge is §"Last proven end to end" — a lane without a dated
  row there is still aspirational.

### 2. Review

- **`automerge` lane** — no human, no LLM. The gate *is* cooldown + CI + the `renovate-approve`
  reflex. A human diffing two SHA-256s is theatre.
- **`deps-review` lane** — the **LLM reviewer** via the merge-path review reflex, not a human.
  Harmless → approve → auto-merge. Needs adaptation → `CHANGES_REQUESTED` → a worker adapts the
  code **on the `renovate/*` branch**. Never close the PR: closing is not a terminal action —
  [`renovate.md`](renovate.md) §Coordinator × Renovate explains why (churn, and vulnerability PRs
  are recreated regardless). To abandon an upgrade durably, change the **config**.
- **`major` lane** — un-armed by default, coordinator-owned, a human merges
  (`agents/major-handoff.sh` sets `major/awaiting-human` only on the reviewer's APPROVED at head
  under the migration lens's four headings). An ARMED `major` merges on the lens's APPROVED with
  the class's revert chain behind it: a graduated GitHub Actions dependency, a devbox lock major
  (class 7), terraform provider majors, argo-cd / argocd-apps, argo-workflows and
  kube-prometheus-stack with its CRD chart. Un-graduated Actions majors carry no `major` at all —
  they ride the grouped `automerge` lane. Terraform provider patch/minor merge mechanically on the
  box's empty plan (class 5).
- **Class 7 (devbox lock) majors ARM — the ADR-141 rule applied to the class; the lane detail
  lives here.** The lock's blast radius, consumer by consumer: **CI** runs the PR's own lock, so the
  toolchain is proven BEFORE the merge; the one push-only consumer (`runner-image.yaml`, triggered
  by the lock) fails into `GithubWorkflowRunFailed` → the `workflow-pin-revert` **lock shape** (a
  lock-only merge is pin-only by construction; branch `revert-lock-<sha8>`, body line
  `reverted-locks: <name>@<version> …`) → `pin-only-lint` check (i) refuses the re-resolve for 30
  days; **the jail** sees it on the next `devbox run` (a human by nature); **the worker image**
  rebakes weekly and the ride belts detect a broken toolchain. The ONE one-way door is
  **opentofu**: its first apply stamps the state and an older binary refuses to read it, so a lock
  revert would leave the box unable to plan — a major of a `HUMAN_PACKAGES` member
  (`scripts/devbox-update.sh`, default `opentofu`) keeps the PR un-armed on the human lane (line
  and patch moves stay armed). The lane is written on the PR body as
  `lock-lane: mechanical | arm | human — <why>`. The body also lists same-major downgrades and
  `major.minor` line moves of the packages that matter (`lock_moves`); the PR stays armed and the
  lens answers that list line by line (operator ruling 2026-10-06: rely on the lens). Coarseness,
  named: one reverted version holds the WHOLE weekly PR red (one lock, all packages) — the lever
  out is a `devbox.json` pin of that one package, or an `exonerated-locks:` line on the revert
  when the chain blamed a package that was not the cause.
- **Platform-specific review question the app lanes don't ask:** *does this bump violate a platform
  invariant?* The ip-plan ranges (ADR-088), storage caps (ADR-089,
  [`storage-ledger.md`](storage-ledger.md)), the `bgp=advertise` label contract, secret
  references-never-values. That's a **policy-as-code** job, not a reading job — the same L0 lane
  [`agents/iac-lane.md`](agents/iac-lane.md) §Assurance layers builds for `-iac`.

### 3. Test / lint

What `ci` gates on a homelab PR: the authoritative list is `.github/workflows/ci.yaml` — the
workflow is the list; homelab has no `devbox run ci` aggregate task. The local pre-flight is
`devbox run diff-ci` (the gates the diff selects, `scripts/diff-ci.sh`).

**What is missing for a dependency bump specifically:**

- **No `tofu validate` / `tofu plan` in `ci`** for classes 4–6 (`fmt -check` is in; `validate`
  stays out — the FU-130 WAN class). The plan comes from outside `ci` instead: the box's
  `management-sentinel` (a required check) plans every PR head touching a root it holds (ADR-131);
  the roots it does not plan are excluded from the provider manager.
- **No render gate on a third-party chart bump** — gap G3 below.
- **No policy-as-code** for the platform invariants above.

### 4. Rollout

This is where the three regimes diverge:

- **GitOps classes (1, 2, 3)** — ArgoCD syncs on merge. The missing piece is **not** the trigger, it
  is the **post-deploy verdict**: ArgoCD health is a *shallow* gate (a schema-skew outage once
  stayed green on a `tcpSocket` probe). The deterministic deploy-revert — Degraded ≤120 m after a
  bump → auto-revert PR ([`agents/iac-lane.md`](agents/iac-lane.md) §"ArgoCD health is NOT the
  post-deploy gate", FU-044) — covers `-iac` deploy bumps and, on the platform, only the
  **reversible class**: a first-party image pin, no CRD/schema migration, no data-layer coupling.
  **⚖ Extending it wholesale is REJECTED (operator, 2026-08-04):** revert is not free for the
  stateful charts (garage, CNPG: CRD/schema downgrade, PVC expectations, data-layer skew), with no
  second net if the revert also fails. Charts get a revert one at a time, each with its own actor
  outside the chart's cone (the `chart-revert` receiver, ADR-149; the upgrade lease, ADR-150);
  everything else Degraded goes to alert triage. Ruling + precondition:
  [`agents/iac-lane.md`](agents/iac-lane.md) §"Auto-revert does NOT generalize to the platform".
- **Tofu classes (4, 5)** — the management box is the applier. A class-4 merge is applied by the
  box inside an evidence bracket, forward only ([`management-box.md`](management-box.md) §Helm
  release applies); a class-5 pin merges only on an empty plan, so there is nothing to apply.
  "Merged but not applied" and "live drifted from state" are visible, not silent: the box plans
  every master move and `MgmtApplyResidueStanding` alerts on an unapplied plan (§MB2/§MB3).
- **Substrate (6)** — a deliberate, staged node rollout run by the box's reconciler: canary node
  per type first, control planes last, a workload-health hold between nodes
  ([`management-box.md`](management-box.md) §MB4). VMs upgrade in place too (ADR-014 as amended),
  but only with the platform- and schematic-correct factory installer. Cilium is the exception: a
  seat-run window ([`runbook.md`](runbook.md) §"Class-6 bump: Cilium").
- **Outside both (9, 14, 15, 16, 19)** — box-applied per ADR-152 (ROADMAP §Deploy paths), never an
  in-cluster ansible Job: for **OPNsense** an in-cluster Job sits *inside its own blast radius* —
  the cone rule below.

**Where the runner sits — the dependency-cone rule.** Belts are read-only (`--check`, `plan`,
drift alerts) and safe to automate anywhere, including in-cluster. **Applies are only safe to
automate from a runner outside the change's dependency cone, or with an out-of-band deadman.**
Concretely: an in-cluster `tofu apply` touching Cilium, ArgoCD, Longhorn or the VM definitions can
sever its own pod's network/storage/node mid-apply. An in-cluster ansible Job pushing OPNsense
config changes the router that carries the Job's own network path: a bad apply cuts both the
connection *and* every rollback path, and ArgoCD can't even report the failure anywhere reachable.
The commit-confirm shape fixes the latter: schedule a config restore on the target *before*
applying, cancel it only when the post-apply health probe passes. Matchbox, in the same ansible
family, has a near-zero cone (nothing depends on it until the next PXE boot) — which is why the
ansible surfaces are four classes: router config (9), router firmware (14), Matchbox (15) and the
Proxmox hosts (16). The full no-human end-state analysis (the router pair, management network,
out-of-band coordinator, what remains genuinely human):
[`spikes/no-human-in-the-loop.md`](spikes/no-human-in-the-loop.md).

**The commit-confirm shape, generalized: the ⚓ upgrade lease (ADR-150).** When the change's cone
contains the detector itself — kube-prometheus-stack, a node-by-node substrate rollout — no
in-cluster alert can judge it. The actor declares the upgrade with a deadline, verifies and DELETES
the declaration, and the management box reverts whatever is still declared past its deadline. The
box diagnoses nothing; an expired lease has one meaning. Mechanism:
[`management-box.md`](management-box.md) §MB5; the chart it was built for: §Worked case below.

### 5. Monitoring

A bump is not done when it merges; it is done when nothing broke. What exists and what doesn't:

| Signal | Exists? | Notes |
|---|---|---|
| ArgoCD app health / sync status | ✅ | shallow — see above. In Prometheus (`argocd/resources/argocd-metrics/`): `ArgoCDAppDegraded` 15 m, `ArgoCDAppSyncFailed` 10 m, `ArgoCDAppOutOfSync` 1 h on autosync apps, `ArgoCDNotificationDeliveryFailing`, `ArgoCDMetricsAbsent` — all `triage: dig` |
| Prometheus + Alertmanager → alert triage | ✅ | `triage: now` → the responder, `triage: dig` → the scheduled deep dig (ADR-148; [`agents/roles.md`](agents/roles.md) §responder) |
| Blackbox probes on service endpoints | ✅ | seconds-grade, dumb |
| Deep [contract probe](glossary.md) post-deploy | ⚠ partial | the **prober** role ([`agents/roles.md`](agents/roles.md) §prober) runs on a 6-hourly cron, report-only; it is not triggered by a sync and files no issue — FU-102 |
| Storage-cap breach visibility | ✅ | Garage admin metrics + `garage-alerts`, Longhorn metering, the pve thin-pool meter (`PveThinPool*`); what is left is FU-093 ([`storage-ledger.md`](storage-ledger.md)) |
| **Renovate liveness** | ✅ | `github_renovate_last_pr_timestamp` per repo on the github-exporter → `RenovateSilent` (14 d org-wide, `warning`) |
| **Coverage-table rot** | ✅ | `github_dependency_coverage_gap_rows` / `_complete` / `_last_proven_timestamp` per class → `DependencyClassProofStale` (a complete class whose proof is >90 d old) — §The dependency inventory |
| **Substrate currency / support window** | ✅ | the management box's belt compares the declared Talos / Kubernetes / Cilium versions against upstream releases and alerts on "a newer minor exists" (`MgmtSubstrateBehind` — firing for Kubernetes, read 2026-11-12) and on "ours is EOL" — [`management-box.md`](management-box.md) §MB2. Not a thing Renovate could have covered: class 6 must not auto-deploy |
| **Router firmware currency** | ❌ | nothing reads `firmware/status` — class 14's detector gap, ROADMAP §Deploy paths step 1 |
| Drift between tofu applies | ⚠ partial — `MgmtApplyResidueStanding` + `MgmtNode*Drift` | FU-235 (the `install_disk` axis is the one not covered) |

**The observation window** ([`agents/iac-lane.md`](agents/iac-lane.md) §Progressive delivery) is
the frame: sync → health → *window* → promote or revert. A platform bump gets that window only
where a lease or a box bracket wraps it (class 4, kube-prometheus-stack); for the rest of classes
1–3 the alerts above are the only watcher after the sync.

### Worked case — kube-prometheus-stack: the chart that is its own detector

The register's class-1 row reads ✅ across the board for this chart. What the generated table
cannot say, in one place:

**Cadence** (read 2026-10-06). 14 chart majors in the preceding 365 days (276 releases); the
maintainers cut a chart major whenever the embedded prometheus-operator bumps a MINOR, a subchart
(kube-state-metrics, grafana) bumps a major, or a default moves. About half the chart majors are
packaging only. Chart semver is not blast class here any more than it was for argo-workflows
(ADR-149); the lens reads the operator appVersion from the chart index first.

**Three lanes:**

| lane | what happens |
|---|---|
| patch / minor (`deps-review`, armed) | `prometheus-rules-lint` checks the committed upstream alert-name list against the pin; Renovate re-renders that list ON the branch (`postUpgradeTasks` running `scripts/upstream-alerts-refresh.sh`), so the PR is born green unless the chart adds an alert NAME. A new name needs a `triage` classification — the worker-adapts leg (gap G12b) |
| chart major, operator minor unchanged | the major handoff ARMS on the lens's `appVersion: unchanged (<v>)` line (`agents/major-handoff.sh`, `agents/lenses/migration.md` §Charts) → the lens's APPROVED merges |
| chart major crossing an operator minor | armed, with the CRD chart as group partner: the lens's APPROVED merges, the upgrade lease is the revert (proven on #2550, §Last proven) |

**The CRDs have an owner (ADR-151).** The chart syncs with `skipCrds: true` — Helm installs
`crds/` once and never upgrades it — so the ten `monitoring.coreos.com` CRDs are a second
Application, upstream's `prometheus-operator-crds` chart: server-side apply (the CRDs exceed the
client-side annotation limit), `Delete=false` so a prune can never take the cone down, and ONE
Renovate group with the stack chart so the pair moves in one PR. The box belt `check_kps_crds`
compares the CRDs' `operator.prometheus.io/version` with the operator image. The lease's revert
never downgrades the CRD chart (`keep` in `policy/mgmt/upgrade-leases.yaml`).

**Why an alert-fed revert does not work here.** The `chart-revert` receiver (ADR-149) is fed by an
Alertmanager route, and kube-prometheus-stack IS Alertmanager and Prometheus: a bump that stops the
Prometheus StatefulSet stops every alert, including the one that would name the bump. No
alert-shaped detector can tell "the upgrade broke it" from "the disk filled up". Hence the lease:
the Application's **PreSync** hook arms it when the sync starts, the **PostSync** hook runs the
chart's real checks — Prometheus and Alertmanager `/-/ready`, rule-evaluation failures at zero,
`Watchdog` present in the Alertmanager API, the operator pod Ready, the CRD version equal to the
operator image — and deletes it; the box reverts an expired one with a pin-only PR that carries a
`reverted-charts:` line, which `pin-only-lint` check (h) holds against Renovate for 30 days. The
hooks live in `argocd/resources/kube-prometheus-stack-lease/`, the record CLI is
`agents/upgrade-lease.sh`; the record's fields, the box loop and the window rule are
[`management-box.md`](management-box.md) §MB5.

**What stays human after it:** an operator minor whose CRD schema change is not additive (a revert
cannot downgrade a CRD), read by the lens from the operator changelog; and the grafana subchart
major (a UI with sqlite-sync state and no probe — gap G5). The one timing hole: a healthy roll that
genuinely outlasts `expected-end` reverts — the fix is a longer deadline on that subject's record,
never a smarter box.

### Gap register — open rows

Gaps the Renovate waves found, by the id the code comments and ADRs cite. The operator's end state
for S9: **not involved in updates or reverts** — every row ends in a mechanical revert or an alert
someone reads, or it stays open. Every open row rides homelab#1985 unless it names another owner
(operator, 2026-10-06: no new FUs for this stint). Read 2026-11-12.

| # | Gap | What would close it | Owner |
|---|---|---|---|
| G3 | A third-party chart bump has no render gate before ArgoCD sync: `ci`'s `argocd-validate-pins.sh` renders only `ghcr.io/teststuffstash/charts`, so a new required value or a CRD skew fails at sync time (`ArgoCDAppSyncFailed` is the only catch) | `scripts/component-check.sh` already `helm template`s every chart pin in `argocd/platform/` and reports a render failure; its `--enforce` mode is wired to nothing — wiring it red on a Renovate chart PR is the gate ([`agents/iac-lane.md`](agents/iac-lane.md) §L0b) | homelab#1985 |
| G5 | Several class-1/2 dependencies have only the generic rollout belt (counted 11 of 30 on 2026-10-04: cert-manager, forgejo, infisical, metrics-server, busybox, alloy, nginx, nginx-unprivileged, otel-collector, kube-rbac-proxy, blackbox-exporter): a bump that starts clean and serves wrong is invisible | a per-service alert or blackbox probe per row; the contract probe is the general answer | FU-102 |
| G8 | The register is regenerated by hand; every pin merge leaves this doc and the github-exporter JSON stale, and two PRs that both regenerate it conflict. A `--check` in `ci` cannot be the fix — a pin PR's own bump is what makes the committed output stale | a master-push job that commits the regenerated pair (an operator call, homelab#1985 comment 2026-09-28) | homelab#1985 |
| G10 | The deploy-revert chain's report-only exits mostly report to nobody: they echo to the workflow pod's log and exit 0 (`agents/coordinator/deploy-revert-argo.yaml`) | `ArgoCDAppDegraded` is the durable report for the class; the chain's own verdict landing somewhere a reader looks | homelab#1985 |
| G12b | A CI-red ARMED Renovate PR needs an actor. Built: a red or changes-requested armed `deps-review` PR rides the `unarmed-major` unit (proven, sleep-tracking#191); a red armed `automerge` PR rides it too (#2995) — but its first real ride (#3233, 2026-11-10) exited without changing anything. ADR-162 added the floor under it: a dead run is retried, and a ride that changes nothing ends on a human | the first red armed `automerge` PR a worker actually fixes in place | homelab#1985 |
| G15 | A grouped version-set PR is armed only when every member has `automerge: true`. The rule for the regex members landed and `devbox run renovate-lane-lint` asserts it on every computed branch | a live grouped crossplane PR whose body reads `Automerge: Enabled` — not yet observed | homelab#1985 |
| G16 | **An armed Renovate pin needs an automated deploy edge**, and a class-level ✅ can hide a member that has none. Closed twice (the prometheus-operator CRDs, ADR-151; the cloudflared tofu pin, retired 2026-10-26). Open residue: `separateMinorPatch: true` can split the kube-prometheus-stack group into a patch branch and a minor branch that the cooldown staggers, so the CRD chart can land days before the stack chart (2026-10-30, #3036; the skew cleared itself) | exempt the group from `separateMinorPatch` in `.github/renovate-global.json` (operator-direct) + a `renovate-lane-lint` case for a split group | homelab#1985 |

**Closed, kept as names** (code comments, ADRs and the Renovate config cite them): G1 ArgoCD health
reached nothing — `ArgoCDAppDegraded` / `ArgoCDAppSyncFailed`. G2 the deploy-revert's dead first
hop — `ArgoCDNotificationDeliveryFailing`. G4 chronically OutOfSync autosync Applications —
`ArgoCDAppOutOfSync` + `manifest-lint`'s `xrd-default-ok` rule. G6 up to three PRs per chart — by
design (`separateMinorPatch`, `prHourlyLimit` paces). G7 no reader for `triage: dig` alerts — the
deep dig (ADR-148). G9 `pin-only-lint` and SemVer-with-comment lines — fixed. G11 a chart pin with
a hand-kept sibling — one grouped PR (§Version SETS, crossplane). G12 the kube-prometheus-stack
alert list — re-rendered on the Renovate branch (§Worked case). G13 a sibling pin in a terraform
default — grouped, then retired with G16. G14 a chart bump that breaks the engine its revert runs
on — the `chart-revert` receiver outside Argo's cone (ADR-149). G17 the lock gate was blind to
same-major downgrades and line moves — `lock_moves` in the PR body (§2 Review).
