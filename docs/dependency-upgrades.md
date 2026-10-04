# Dependency upgrades — the homelab platform's own path

**This doc owns homelab's own dependency lifecycle**: what a platform dependency bump *should* look
like from proposal through review, test/lint, rollout and monitoring — per dependency class, because
homelab has three different reconciliation regimes and a bump means something different in each.

**Not this doc.** The org-wide **Renovate policy** (threat model, cooldown, the automerge-vs-review
split, the coordinator×Renovate verbs) is [`renovate.md`](renovate.md) — it applies to every repo
the App autodiscovers and is not repeated here. The **app-stack** deploy shapes (app+chart,
operator chart, pod image) are `ROADMAP.md` → *Programs in flight* → "Deploy paths" (FU-051). The
surfaces homelab doesn't reconcile at all are FU-097, same section.

The ledger rule this feeds: [`management-box.md`](management-box.md) §The capability ledger
(FU-097, archived 2026-10-03 — generalized to dependency classes 2026-09-27). **Tracked by:** FU-051 (the app-side sibling), FU-046 (reviewable dep bumps),
**FU-151** (the `automerge` label — §2's mechanical lane — is not set by the `-iac` deploy
producers, so those bumps skip LLM review only by timing), FU-016 (SLSA signing/SBOM). ADR-084
(deploy shape), ADR-093 (Argo as the orchestration engine), ADR-088/089 (the invariants a bump
must not break), ADR-141 (blast class picks the lane). The §Ground truth finding was FU-125
(archived 2026-09-27); the lanes and the residue are stint S9, homelab#1985 (open originals:
#1988 lanes by class, #1992 the generated coverage table + liveness gauges, #2014 version sets).

---

## Ground truth first: what Renovate has actually done in homelab

Measured 2026-08-01 from run #115 of `.github/workflows/renovate.yaml` (job logs) and the repo's
PR/branch/issue history. **This section is evidence, not design** — the design below exists because
of it.

**Renovate has never opened a single dependency PR in homelab — and org-wide this is a
REGRESSION, not a never-worked.** FU-014's rollout evidence (archived 2026-07-12; preserved here
because that archive entry expires ~2026-08-16) records real bumps flowing on 2026-07-05/06: a
sleep-tracking docker-digest PR that produced a sleep-iac deploy PR 8 minutes later, plus
devbox-update bumps. sleep-tracking is now one of the four `integration-unauthorized` repos. So
the write path **worked** and then broke somewhere in the 2026-07-06 → 08-01 window. The cause
turned out to be a permission the App never had, not a change to the App — diagnosed below.

| Observation | Evidence |
|---|---|
| Renovate runs every ~6h and has for weeks | 115 workflow runs, **every one `success`** |
| homelab *is* autodiscovered and *is* extracted | run #115: `homelab` first of 10 repos, **97 deps across 36 files** |
| …and then aborts | `result: "repository-changed"` after 43.9s — "Repository has changed during renovation - aborting" |
| **Every other repo aborted too, in the same run** | 6 × `repository-changed`, **4 × `integration-unauthorized`** (sleep-tracking, snore-recorder, oracle-fleet, oracle-iac) |
| Net PRs opened by that run | **zero**, across all ten repos |
| No Dependency Dashboard exists | the global config extends `:dependencyDashboard`; there is no such issue on homelab |
| One orphaned branch | `renovate/pin-dependencies`, pushed **2026-07-27**, SHA-pinning 7 workflow files — **no PR was ever opened for it** |
| The only "renovate" PRs here aren't Renovate's | `runner-image-pin` and `devbox-update` branches — first-party workflows using the App as an author identity |
| Onboarding PR | #2 "Configure Renovate", closed 2026-07-06 — correct, the policy is the global file (`onboarding: false`) |

Two more findings from the same log:

- **Config validation warning, silently tolerated:** `"prPriority" can't be used in
  "vulnerabilityAlerts". Allowed objects: packageRules.` The security fast-track's `prPriority: 10`
  is **dropped**. The rest of the `vulnerabilityAlerts` block is fine.
- **A custom manager resolves nothing:** `Found no results from datasource that look like a version
  (dependency=NixOS/nix)` — the `NIX_VERSION` pin in `docker/arc-runner/Dockerfile` has never been
  updatable (NixOS/nix releases don't match the `github-releases` version shape being asked for).

### Why this matters more than the individual bugs

The workflow is **green**. Nothing anywhere says "Renovate did nothing again." This is the same
failure class as FU-108 (the exporter's Search API silently omitting private repos) and FU-113 (a
deferral that reads as silence): **a probe that reports success while doing nothing is worse than
one that fails**, because it buys false confidence in a supply-chain control that
[`renovate.md`](renovate.md) describes as the first line of defence against a Trivy-style
compromise. The cooldown, the SHA-pinning and the OSV alerts are all real policy — and none of them
have been *applied* to homelab.

**Diagnosed 2026-09-25 (debug run 36107468534): both halves are ONE missing permission —
`statuses`.** Renovate reads each branch's commit statuses and writes `renovate/stability-days`
(the `minimumReleaseAge` cooldown's status). The App was never granted `statuses`, so every repo
403s after extraction: `x-accepted-github-permissions: statuses=read` surfaces as
`integration-unauthorized`, `statuses=write` as `repository-changed`. The two earlier hypotheses —
an App permission/installation regression since 2026-07-06, and the ~6h schedule racing the loop's
push traffic — are both ruled out (the live declared-vs-live page matched on every other permission
and all ten installs). The fix is the declaration in [`github-apps.yaml`](github-apps.yaml) plus the
grant in the App settings (the `GithubAppPermissionDrift` belt rings until it lands).

> **Acceptance for "Renovate works in homelab":** at least one `renovate/*` PR has been opened,
> gated and merged. **MET 2026-09-27** — #2008 (an Actions minor through the grouped mechanical
> lane), #2021 (the SHA-pinning PR, rebuilt under the first-party exclusion), #2012 (npm),
> #1983/#1996/#1997 (terraform providers through the human plan); the per-class record is
> §"Last proven end to end" below. (The dashboard-issue-exists half of this acceptance was
> RETIRED 2026-08-18: `dependencyDashboard` is now `false` in the global config by operator
> ruling — the dashboard is an interactive click-ops surface nothing here reads; liveness is the
> gauge, next-step 2.)

---

## The dependency inventory, and whether a path rule can trigger deployment

Renovate extracted **97 dependencies across 7 managers** on 2026-08-01 (§Ground truth); the generated
register below carries the current count from the repo's own files. The question "can a path rule
trigger deployment?" has a different answer per class, because homelab runs **three reconciliation
regimes**:

- **GitOps (ArgoCD)** — 27 of 34 platform Applications have `syncPolicy.automated`, watching
  `argocd/resources/*`, `argocd/platform/*`, `agents/coordinator`, `agents/fixer/*`. A merge here
  **deploys itself**. A path rule is not just possible, it is already the mechanism.
- **OpenTofu** — plan/apply from the jail is the **deliberate human gate** (FU-097 says keep it). A
  path rule can only *plan and report*; it must never apply.
- **Unreconciled** — ansible (OPNsense, Matchbox), Home Assistant config, the Proxmox host. A merge
  deploys **nothing**. This is the FU-097 gap.

<!-- BEGIN GENERATED dependency-coverage — do not edit; edit docs/dependency-classes.yaml (rulings) or the pinned files (dependencies) and run `devbox run dependency-coverage` -->

**102 pinned dependencies in 12 classes; 91 rows carry a ⚠ column; 2 class(es) complete, 1 of them without a 👤 cell.** ✅ built and proven · 👤 a human by ruling (filled, not a gap — the owner stays by design) · ⚠ missing. A row is complete when no column is ⚠ and the proof is recent (≤90 d — `DependencyClassProofStale` fires when a complete class's proof ages out; `github_dependency_coverage_gap_rows` counts the ⚠ rows).

#### Per class — the seven columns

| # | Class | Pinned where · manager | Proposer | Merge gate | Deploy edge | Detector | Revert | Canary | Last proven E2E | Rows (⚠) | Owner may leave? |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | **Helm charts, GitOps** | `argocd/platform/*.yaml` `spec.source.chart` + `targetRevision` · `argocd (needs `managerFilePatterns` — NOT configured, so nothing proposes these today)` | ⚠ Renovate's `argocd` manager has no default file match and renovate-global.json does not configure one — no PR has ever proposed a chart bump here (§Ground truth: 97 deps extracted, none of them these) | ✅ minor → `deps-review` (reflex + lens), major → un-armed `major` lane (renovate-global.json; ADR-141 for the arm rule) | ✅ ArgoCD `syncPolicy.automated` — a merge IS the deploy (27 of 34 Applications auto-sync) | ⚠ ArgoCD health is shallow (the meta-11 schema-skew outage stayed green on a tcpSocket probe); the contract probe is FU-102 | 👤 a human `git revert` — the FU-044 deterministic revert is scoped to first-party image pins; extending it to charts REJECTED (operator 2026-08-04, IAC-G09: CRD/schema downgrades are not reversible by a revert) | ⚠ none — a chart bump lands on the only instance; ARC controller/runners must move in lockstep (two files, one version) | — never | 14 (14) | no — 3 ⚠ column(s), 14 ⚠ row(s), never proven |
| 2 | **In-cluster images, GitOps** | `image:` in `argocd/resources/**/*.yaml` + `agents/coordinator/*.yaml` (third-party refs; first-party = class 3) · `kubernetes (needs `managerFilePatterns` — NOT configured) / none for agents/images.env` | ⚠ unmanaged — Renovate's `kubernetes` manager has no default file match and none is configured; digest-pinned refs never move (cloudflared 2026.5.2, python:3.13-slim@sha256, k3d:5-dind@sha256) | ✅ digest → `automerge` (reflex), version minor → `deps-review`, major → un-armed (renovate-global.json) — the lanes exist, nothing feeds them | ✅ ArgoCD auto-sync of the manifest — path-scoped per resource dir | ⚠ ArgoCD health (shallow) + the per-service alert belts where they exist; no post-deploy contract probe (FU-102) | 👤 a human `git revert`; the FU-044 chain's pin-only predicate covers FIRST-PARTY pins only (class 3) | ⚠ none — single replica for most of these | — never | 16 (16) | no — 3 ⚠ column(s), 16 ⚠ row(s), never proven |
| 3 | **First-party images** | `agents/images.env` (agent-base, agent-coordinator) + every `image: ghcr.io/teststuffstash/…` ref the deploy-pin sweep must reach (`argocd/**`, `agents/coordinator/*.yaml`) · `n/a — the deploy-pin PR (ADR-084); Renovate never touches our own artifacts (a `2026.<m>.<d>-g<sha>` tag does not order)` | ✅ the image repo's `deploy-pin` job (agent-runtime → agent-base, agent-coordinator) and `runner-image.yaml` (arc-runner) open `deploy/*` / `runner-image-pin` PRs; weekly `schedule` rebuilds since 2026-09-27 | ✅ `automerge`+`dependencies` → renovate-approve reflex → CI-green auto-merge (`pin-only-lint` guards the diff shape) | ✅ ArgoCD auto-sync; the deploy-pin sweep bumps every mirrored literal by git-grep (images.env header) — a ref with a DIFFERENT tag than images.env is one the sweep missed (⚠ on the row) | ⚠ ArgoCD Degraded → `/deploy-degraded` (wired 2026-08-04) but NEVER fired by a real Degraded homelab app (FU-044); a bare `:latest`-equivalent ref is invisible to it | ✅ the cluster pin IS the revert (operator 2026-09-27): `deploy-revert-argo.yaml`'s pin-only predicate opens the revert PR; the FU-1990 sibling chain proved the shape end to end in the 2026-09-27 drill (agent-coordinator#20 → #21, ~3.5 min) | ⚠ none — the pin rolls every consumer at once (the coordinator, the reviewer, the sentinel, the transcript viewer) | 2026-10-02 ([#2187](https://github.com/teststuffstash/homelab/pull/2187)) | 4 (4) | no — 2 ⚠ column(s), 4 ⚠ row(s) |
| 4 | **Helm charts, tofu-managed** | `helm_release` blocks in `tofu/*.tf`, version from `tofu/variables.tf` defaults · `terraform (a `var.*_version` default — Renovate's helm datasource does not follow it)` | ⚠ a hand edit of the variable default — Renovate's terraform manager reads `helm_release.version` literals, not a `var.` indirection (§Ground truth: 0 PRs) | 👤 PR + the management sentinel's plan-on-PR (ADR-131) + the codeowner read — these are ADR-005 substrate (ArgoCD, Longhorn) by ruling | 👤 the management box applies only the allowlisted residue; a `helm_release` change refuses to a human `devbox run mgmt-tf -- apply` (docs/management-box.md §The test surface) | ✅ `MgmtApplyResidueStanding` — merged-but-unapplied residue alerts after 24 h (FU-252); plan-on-PR shows the diff before merge | 👤 `git revert` + a human apply; ArgoCD/Longhorn downgrades carry CRD/schema risk (IAC-G09) | ⚠ none — one release per chart | — never | 3 (3) | no — 2 ⚠ column(s), 3 ⚠ row(s), never proven |
| 5 | **Tofu providers** | `tofu/**/versions.tf` `required_providers` (the `~>` range) + `.terraform.lock.hcl` (the real pin) · `terraform` | ✅ Renovate `terraform` — lockfile + constraint PRs flow since the `statuses` grant (2026-09-25; #1976/#1981/#1983/#1984/#1996/#1997 merged 2026-09-27); the two roots the box does not plan are excluded from the manager (row overrides) | ✅ the management box is the gate, mechanically (ADR-131 amended 2026-09-27, #2026): stage 1 admits the `provider-pin` diff shape, stage 2 plans the head with the new provider and a pin must plan EMPTY — relative to master's own pending plan, or a default backfill (null→default attributes a release adds, #2191) — and keep every stored schema/identity version (the state-compatibility check, 2026-10-04) — `management-sentinel` green on `+0 ~0 -0` → `automerge` (reflex approves, auto-merge lands); red = the only provider PRs a human sees (`mgmt-human-plan`). Built on six human-ordered `+0` plans; merging on the sentinel's own green since 2026-09-28 (#2075 proxmox, #2096 talos; #2213 random on 2026-10-04 — Renovate merged, reflex-approved, no human). MAJORS armed 2026-10-04 (operator; ADR-141 amended): `major` kept, no `automerge` label, the migration lens's APPROVED completes the merge | ✅ an empty plan IS the deploy: the box's next plan/apply runs the new provider binary (registry-signed, hash-verified by tofu); nothing to apply by construction | ✅ the sentinel's plan-on-PR (red = `provider bump changes the plan`, by design) + `MgmtApplyResidueStanding` on main; post-merge, `MgmtApplyErroredOnNewProvider` names the provider when the first CHANGING apply under a new version errors (2026-10-04, docs/management-box.md §MB3); the external roots plan read-only on the box (FU-237/FU-238) | ✅ `git revert` of the lockfile + the same empty plan; lockfile-only BY GATE since 2026-10-04 — a pin that would raise a stored schema/identity version never merges on the sentinel, so the downgrade reads the state back (docs/management-box.md §MB3); the `tofu-provider-revert` chain (2026-10-04, agents/coordinator/deploy-revert-argo.yaml) reverts the introducing pin on `MgmtApplyErroredOnNewProvider` — DRILLED 2026-10-04 (synthetic alert → #2209 merged + applied, no human; §Last proven); provider MAJORS armed 2026-10-04 behind this chain (ADR-141 amended) | ⚠ none — `tofu/provisioning` is the low-blast root a provider bump could land on first, but nothing orders the roots | 2026-10-04 ([#2047](https://github.com/teststuffstash/homelab/pull/2047)) | 14 (14) | no — 1 ⚠ column(s), 14 ⚠ row(s) |
| 6 | **Cluster substrate** | `tofu/variables.tf` defaults (`talos_version_*`, `kubernetes_version`, `cilium_version`) + `machines/machines.yaml` · `terraform (weak) — human-proposed until ROADMAP G-D (operator 2026-09-18)` | 👤 a human bump PR of the variable default — Renovate stays off class 6 until a few ATTENDED bumps through the box path have passed (operator 2026-09-21, ROADMAP G-D); the substrate belt says when we are behind or EOL (FU-254, docs/management-box.md §MB2) | 👤 PR + plan-on-PR + the install-impact line (§MB3) + the codeowner read; Kubernetes minors need a recreate-from-git drill first (design sitting 2026-09-25) | ✅ the box-run rollout: `mgmt-reconcile` rolls `reconcile: auto` nodes — 13/13 incl. 3 CPs on 2026-09-22 (#1879, ADR-132; VMs in place since ADR-014's 2026-09-18 amendment) | ✅ `MgmtNode*Drift` declared-vs-live per node (FU-235) + the substrate currency belt (FU-254) + the rollout's workload-health hold (FU-278) | 👤 forward by default (rollout ruling 2026-09-22): a revert is a human commit + the same rollout; the post-apply health gate parks, never reverts | ✅ per-type canary node via the per-node `talos_version` override (FU-033 lever) — the reconciler rolls canaries first, CPs last | 2026-09-22 (capability ledger — Talos install rollout, workers + CPs (`mgmt-reconcile`): #1879: 13/13 v1.14.1 09:43→13:17Z, canary per type, CPs last) | 4 (0) | no — complete, but a 👤 cell keeps the human by ruling |
| 7 | **devbox/nix toolchain** | `devbox.json` (all `@latest`) → `devbox.lock` (the resolved version) · `nix/devbox DISABLED on purpose (an `@latest` pin is untrackable — docs/renovate.md §Gotchas)` | ✅ the weekly synchronized `devbox-update.yaml` — one job re-resolves EVERY repo's lock together, one PR per repo (the model other classes must match, #2014) | ✅ `automerge`+`dependencies` → reflex → CI-green; a major in the resolved set relabels the PR `major` and disarms it (scripts/devbox-update.sh) | ✅ self-deploying for CI and the jail (`devbox run` reads the lock); the agent-base image rebuilds weekly (class 3 carries the pin) | ⚠ CI on the PR is the only check; nothing compares the jail's, the runner's and the worker image's resolved versions (the #2014 version-set gap; FU-240 for the box↔jail devbox skew) | ✅ `git revert` of the lock — nothing else references the store paths | ⚠ none — every repo moves in the same weekly pass by design (alignment over caution) | 2026-09-07 ([#1488](https://github.com/teststuffstash/homelab/pull/1488)) | 37 (37) | no — 2 ⚠ column(s), 37 ⚠ row(s) |
| 8 | **GitHub Actions** | `uses:` in `.github/workflows/*.y*ml` (third-party; first-party `teststuffstash/**@master` floats by contract) · `github-actions` | ✅ Renovate `github-actions`, SHA-pinned (`helpers:pinGitHubActionDigests`), grouped per repo per wave — #2021 (pin) and #2008 merged 2026-09-27 | ✅ every update type incl. majors rides the grouped `automerge` lane (ADR-141 as amended 2026-09-27): reflex approval + CI on the bumped head (a `pull_request` workflow runs the PR's own file) | ✅ self-deploying — the next run uses the merged file | ✅ `GithubWorkflowRunFailed` on master (github-exporter) covers the push-only workflows CI cannot exercise | ✅ the FU-1990 chain: `workflow-pin-revert` reverts the pin PR as `automerge`+`dependencies`, `pin-only-lint` check (e) refuses the reverted pin for 30 d — DRILLED 2026-09-27 (agent-coordinator#20 → #21, no human touch) | ✅ the PR's own `pull_request` run on the bumped head is the pre-merge proof; push-only workflows are canaried by the revert chain instead | 2026-10-02 ([#2175](https://github.com/teststuffstash/homelab/pull/2175)) | 5 (0) | **yes** — complete |
| 9 | **Ansible collections/roles** | `ansible/requirements.yml` (roles live in-repo today — the file is the extraction seam) · `ansible-galaxy` | ✅ Renovate `ansible-galaxy` reads `requirements.yml` by default — nothing is pinned there yet, so nothing to propose | ✅ the standard lanes (minor → `deps-review`, major → un-armed) | ⚠ NONE — a merge deploys nothing until a human runs `scripts/opnsense-playbook.sh`; the FU-097 gap, sharpest here (this is the router) | ⚠ no nightly `--check` diff; a merged OPNsense change sits until a human remembers | 👤 `git revert` + a human playbook run; an in-cluster applier would sit inside its own blast radius (the dependency-cone rule) | ⚠ none — one router; Matchbox (near-zero cone) is the natural first target | — never | 0 (0) | no — 3 ⚠ column(s), never proven |
| 10 | **arc-runner image inputs** | `docker/arc-runner/Dockerfile` — `FROM ghcr.io/actions/actions-runner` + `ARG DEVBOX_VERSION` / `ARG NIX_VERSION` · `dockerfile (FROM) + custom.regex (the two ARGs — renovate-global.json customManagers)` | ✅ Renovate `dockerfile` + `custom.regex` — #2022 (actions-runner 2.337.0, `deps-review`) merged 2026-09-27 | ✅ FROM minor → `deps-review`; ARG patch/minor → `automerge` (custom.regex rule, 2026-09-27); majors → un-armed | ✅ `runner-image.yaml` builds on the merge and opens the `runner-image-pin` PR (class 3 lands it) | ✅ the image build in `ci` (push: false) fails the PR; `GithubWorkflowRunFailed` covers the master build | ✅ the cluster pin is the revert (the previous `arc-runner:` tag stays pullable); the FU-1990 chain covers the workflow half | ⚠ none — the pin PR rolls both scale sets (arc-runners + arc-runners-large) together | 2026-10-02 ([#2186](https://github.com/teststuffstash/homelab/pull/2186)) | 3 (3) | no — 1 ⚠ column(s), 3 ⚠ row(s) |
| 11 | **Harness + tool versions baked into first-party images** | three Dockerfiles in three repos (agent-runtime, agent-coordinator, claude-jail) — NOT extractable from this repo; the in-repo half is class 7/10. Members + sync state: §Version SETS below · `devbox-update (agent-base only); custom.regex for s5cmd; none for claude-code (npm), gh, KUBECTL_VERSION` | ⚠ claude-code floats to npm latest in two images and rides nixpkgs in the third; kubectl in the coordinator image is a hand ARG — owner of the fix: #2014 (version sets) | ✅ the weekly `build-image` rebuild + the class 3 deploy-pin lanes | ✅ a rebuild is a new build-date tag → deploy-pin rolls it (weekly `schedule` since 2026-09-27) | ⚠ nothing checks the three claude-code versions agree, or kubectl's skew against the fleet minor (#2014) | ✅ the cluster pin is the revert (operator 2026-09-27) | ⚠ none | — never | 0 (0) | no — 3 ⚠ column(s), never proven |
| 12 | **JS CI tooling (Deno)** | `scripts/mermaid-lint/deno.json` (+ `deno.lock`) — the docs' mermaid parser, CI-only, run with NO Deno permissions (ADR-143) · `deno` | ✅ Renovate `deno` (ADR-143, 2026-09-29 — the npm lane's #2012 jsdom 30.1.0 merged 2026-09-27 is the prior proof; jsdom left with the switch) | ✅ patch/minor → `automerge`; majors → the un-armed catch-all; `lock-intake-lint` in `ci` fails any intake that is OSV-flagged, <7 d old or install-script-bearing (transitive included — ADR-143) | ✅ self-deploying — `ci` fetches the lock's integrity-pinned tarballs + parses on every PR | ✅ required `ci` (`mermaid-lint` + `lock-intake-lint`) — a broken parser or a bad intake reds the PR before merge | ✅ `git revert` — no runtime consumer | ✅ the PR's own `ci` run exercises the exact dependency that ships | — never | 2 (0) | no — never proven |

#### Per dependency — the register

Columns P/G/D/Det/R/C are the class's proposer / merge gate / deploy edge / detector / revert / canary; a cell carries text only where the dependency differs from its class. Last proven = the newest merged proposer PR whose diff named the dependency (class 6: the capability ledger).

| Class | Dependency | Version | Pinned in | P | G | D | Det | R | C | Last proven E2E |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `argo-events` | 2.4.23 | `argocd/platform/argo-events.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 1 | `argo-workflows` | 1.0.24 | `argocd/platform/argo-workflows.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 1 | `cert-manager` | v1.21.2 | `argocd/platform/cert-manager.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 1 | `cloudnative-pg` | 0.28.3 | `argocd/platform/cnpg-operator.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 1 | `crossplane` | 2.3.2 | `argocd/platform/crossplane.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 1 | `external-secrets` | 2.6.0 | `argocd/platform/eso-operator.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 1 | `forgejo` | 17.1.1 | `argocd/platform/forgejo.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 1 | `gateway-api` | v1.4.1 | `argocd/platform/gateway-api-crds.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 1 | `gha-runner-scale-set` | 0.14.2 | `argocd/platform/arc-runners-large.yaml`, `argocd/platform/arc-runners.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 1 | `gha-runner-scale-set-controller` | 0.14.2 | `argocd/platform/arc-controller.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 1 | `infisical-standalone` | 1.9.0 | `argocd/platform/infisical.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 1 | `kube-prometheus-stack` | 86.1.0 | `argocd/platform/kube-prometheus-stack.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 1 | `metrics-server` | 3.12.2 | `argocd/platform/metrics-server.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 1 | `plugin-barman-cloud` | 0.8.1 | `argocd/platform/plugin-barman-cloud.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `alpine` | 3.20 | `argocd/resources/node-fstrim/fstrim.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `cloudflare/cloudflared` | 2026.5.2@sha256:12ff5c6992a9 | `argocd/resources/publicroute/composition.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `docker.io/library/busybox` | 1.36.1@sha256:73aaf090f3d8 | `argocd/resources/loki/kmsg-reader.yaml`, `argocd/resources/runner-image-prepull/daemonset.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `docker.io/prometheuscommunity/smartctl-exporter` | v0.14.0@sha256:cfe22c36d7d2 | `argocd/resources/smartctl-exporter/daemonset.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `ghcr.io/k3d-io/k3d` | 5-dind@sha256:ee3872700ed0 | `agents/images.env` | ⚠ no Renovate manager reads `agents/images.env` (`AGENT_DIND_IMAGE`) | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `ghcr.io/lablabs/cloudflare_exporter` | 0.2.3@sha256:6bf84a81725c | `argocd/resources/cloudflare-exporter/deployment.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `grafana/alloy` | v1.5.1 | `argocd/resources/loki/alloy.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `grafana/loki` | 3.4.2 | `argocd/resources/loki/loki.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `nginx` | 1.27-alpine | `argocd/resources/registry/registry-fs.yaml`, `argocd/resources/registry/registry.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `nginxinc/nginx-unprivileged` | 1.27-alpine | `argocd/resources/cf-api-proxy/deployment.yaml`, `argocd/resources/devbox-search/deployment.yaml`, `argocd/resources/nix-cache/deployment.yaml` +2 | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `otel/opentelemetry-collector-contrib` | 0.116.1 | `argocd/resources/otel-collector/deployment.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `prom/pushgateway` | v1.11.1 | `argocd/resources/pushgateway/deployment.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `python` | 3.13-slim, 3.13-slim@sha256:cc9dffa47c82 | `argocd/resources/cloudflare-exporter/edge-probe-deployment.yaml`, `argocd/resources/cloudflare-exporter/spend-probe-deployment.yaml`, `argocd/resources/garage-disruption/controller.yaml` +6 | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `quay.io/brancz/kube-rbac-proxy` | v0.22.1 | `argocd/resources/loki/loki-rbac-proxy.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `quay.io/prometheus/blackbox-exporter` | v0.27.0 | `argocd/resources/blackbox/blackbox.yaml` | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 2 | `registry` | 3.0.0 | `argocd/resources/registry-cache/mirror-docker-io.yaml`, `argocd/resources/registry-cache/mirror-ghcr.yaml`, `argocd/resources/registry-cache/mirror-mcr.yaml` +3 | ⚠ | ✅ | ✅ | ⚠ | 👤 | ⚠ | — never |
| 3 | `agent-base` | `AGENT_BASE_IMAGE`=2026.9.28-g3df151221c3d.92 | `agents/images.env` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-09-28 ([#2083](https://github.com/teststuffstash/homelab/pull/2083)) |
| 3 | `agent-coordinator` | `AGENT_COORDINATOR_IMAGE`=2026.9.28-gca94f4a2dd99; 28 manifest ref(s) | `agents/coordinator/coordinate-argo.yaml`, `agents/coordinator/corpus-dispatch-argo.yaml`, `agents/coordinator/deep-dig-argo.yaml` +13 | ✅ | ✅ | ⚠ 28 ref(s) NOT at the images.env pin (22× (none — floats to :latest), 1× 2026.7.25-g141235c93140, 5× 2026.8.7-gd6dc9ced82f2) — the deploy-pin sweep misses them | ⚠ | ✅ | ⚠ | 2026-09-28 ([#2081](https://github.com/teststuffstash/homelab/pull/2081)) |
| 3 | `cchv-server` | v1.18.0 (×1) | `agents/coordinator/transcripts-viewer.yaml` | ⚠ a hand pin — the viewer image is built from the upstream cchv tag by hand (agents/coordinator/transcripts-viewer.yaml header); no deploy-pin job, no Renovate manager for a first-party tag | ✅ | ✅ | ⚠ | ✅ | ⚠ | — never |
| 3 | `homelab/arc-runner` | 2026.10.2-gd0b15ed85110 (×3) | `agents/coordinator/sentinel-argo.yaml`, `argocd/resources/runner-image-prepull/daemonset.yaml` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-10-02 ([#2187](https://github.com/teststuffstash/homelab/pull/2187)) |
| 4 | `argo-cd` | 9.5.21 | `tofu/argocd.tf`, `tofu/variables.tf` | ⚠ | 👤 | 👤 | ✅ | 👤 | ⚠ | — never |
| 4 | `argocd-apps` | 2.0.5 | `tofu/argocd.tf`, `tofu/variables.tf` | ⚠ | 👤 | 👤 | ✅ | 👤 | ⚠ | — never |
| 4 | `longhorn` | 1.12.0 | `tofu/longhorn.tf` | ⚠ | 👤 | 👤 | ✅ | 👤 | ⚠ | — never |
| 5 | `bpg/proxmox` | 0.114.0 (`~> 0.114`) | `tofu/versions.tf`, `tofu/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠ | 2026-09-28 ([#2075](https://github.com/teststuffstash/homelab/pull/2075)) |
| 5 | `bpg/proxmox` | 0.114.0 (`~> 0.114`) | `tofu/provisioning/versions.tf`, `tofu/provisioning/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠ | 2026-09-28 ([#2075](https://github.com/teststuffstash/homelab/pull/2075)) |
| 5 | `cloudflare/cloudflare` | 5.26.0 (`~> 5.0`) | `tofu/cloudflare/versions.tf`, `tofu/cloudflare/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠ | 2026-09-27 ([#1981](https://github.com/teststuffstash/homelab/pull/1981)) |
| 5 | `cloudflare/cloudflare` | 5.25.0 (`~> 5.0`) | `tofu/cloudflare-token/versions.tf`, `tofu/cloudflare-token/.terraform.lock.hcl` | ⚠ DISABLED for this root (renovate-global.json, #2026): `tofu/cloudflare-token` is the one-shot admin-token root the box never plans — moved by hand with a jail plan | ✅ | ✅ | ✅ | ✅ | ⚠ | — never |
| 5 | `hashicorp/helm` | 3.3.0 (`~> 3.0`) | `tofu/versions.tf`, `tofu/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠ | 2026-10-02 ([#2046](https://github.com/teststuffstash/homelab/pull/2046)) |
| 5 | `hashicorp/kubernetes` | 3.2.1 (`~> 3.0`) | `tofu/versions.tf`, `tofu/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠ | 2026-10-04 ([#2047](https://github.com/teststuffstash/homelab/pull/2047)) |
| 5 | `hashicorp/kubernetes` | 3.2.1 (`~> 3.0`) | `tofu/cloudflare/versions.tf`, `tofu/cloudflare/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠ | 2026-10-04 ([#2047](https://github.com/teststuffstash/homelab/pull/2047)) |
| 5 | `hashicorp/kubernetes` | 2.38.0 (`~> 2.31`) | `tofu/infisical/versions.tf`, `tofu/infisical/.terraform.lock.hcl` | ⚠ DISABLED for this root (renovate-global.json, #2026): the box does not plan `tofu/infisical` — moved by hand with a jail plan | ✅ | ✅ | ✅ | ✅ | ⚠ | — never |
| 5 | `hashicorp/random` | 3.9.1 (`~> 3.6`) | `tofu/versions.tf`, `tofu/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠ | 2026-09-27 ([#1976](https://github.com/teststuffstash/homelab/pull/1976)) |
| 5 | `hashicorp/tls` | 4.4.1 (`~> 4.0`) | `tofu/cloudflare/versions.tf`, `tofu/cloudflare/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠ | 2026-09-27 ([#1997](https://github.com/teststuffstash/homelab/pull/1997)) |
| 5 | `Infisical/infisical` | 0.19.32 (`~> 0.19`) | `tofu/infisical/versions.tf`, `tofu/infisical/.terraform.lock.hcl` | ⚠ DISABLED for this root (renovate-global.json, #2026): the box does not plan `tofu/infisical` (policy foreign_roots), so a bump here has no gate — moved by hand with a jail plan; the root is slated to leave tofu | ✅ | ✅ | ✅ | ✅ | ⚠ | 2026-09-27 ([#1984](https://github.com/teststuffstash/homelab/pull/1984)) |
| 5 | `integrations/github` | 6.13.0 (`~> 6.0`) | `tofu/github/versions.tf`, `tofu/github/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠ | 2026-09-27 ([#1983](https://github.com/teststuffstash/homelab/pull/1983)) |
| 5 | `poseidon/matchbox` | 0.5.4 (`~> 0.5`) | `tofu/provisioning/versions.tf`, `tofu/provisioning/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠ | — never |
| 5 | `siderolabs/talos` | 0.12.0 (`~> 0.12`) | `tofu/versions.tf`, `tofu/.terraform.lock.hcl` | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠ | 2026-09-28 ([#2096](https://github.com/teststuffstash/homelab/pull/2096)) |
| 6 | `Cilium` | 1.19.1 | `tofu/variables.tf` | 👤 | 👤 | ✅ | ✅ | 👤 | ✅ | 2026-09-22 (capability ledger — Talos install rollout, workers + CPs (`mgmt-reconcile`): #1879: 13/13 v1.14.1 09:43→13:17Z, canary per type, CPs last) |
| 6 | `Kubernetes` | v1.36.1 | `tofu/variables.tf` | 👤 | 👤 | ✅ | ✅ | 👤 | ✅ | 2026-09-22 (capability ledger — Talos install rollout, workers + CPs (`mgmt-reconcile`): #1879: 13/13 v1.14.1 09:43→13:17Z, canary per type, CPs last) |
| 6 | `Talos (control planes)` | v1.14.1 | `tofu/variables.tf` | 👤 | 👤 | ✅ | ✅ | 👤 | ✅ | 2026-09-22 (capability ledger — Talos install rollout, workers + CPs (`mgmt-reconcile`): #1879: 13/13 v1.14.1 09:43→13:17Z, canary per type, CPs last) |
| 6 | `Talos (workers)` | v1.14.1 | `tofu/variables.tf` | 👤 | 👤 | ✅ | ✅ | 👤 | ✅ | 2026-09-22 (capability ledger — Talos install rollout, workers + CPs (`mgmt-reconcile`): #1879: 13/13 v1.14.1 09:43→13:17Z, canary per type, CPs last) |
| 7 | `age` | 1.3.1 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `ansible` | 2.21.3 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | — never |
| 7 | `argo-workflows` | 3.6.10 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `argocd` | 3.4.6 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `awscli2` | 2.35.11 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `bind` | 9.20.26 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-09-07 ([#1488](https://github.com/teststuffstash/homelab/pull/1488)) |
| 7 | `cilium-cli` | 0.19.7 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `cloudflared` | 2026.8.2 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `crossplane-cli` | 2.4.1 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | — never |
| 7 | `curl` | 8.17.0 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | — never |
| 7 | `deno` | 2.9.5 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | — never |
| 7 | `gh` | 2.98.0 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `gitleaks` | 8.30.1 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `hubble` | 1.19.4 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `infisical` | 0.43.123 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `jq` | 1.8.2 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-09-07 ([#1488](https://github.com/teststuffstash/homelab/pull/1488)) |
| 7 | `k9s` | 0.51.0 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `keepassxc` | 2.7.12 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `kubeconform` | 0.8.0 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `kubectl` | 1.36.3 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `kubernetes-helm` | 4.2.4 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `kyverno` | 1.19.0 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `netcat-gnu` | 0.7.1 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `nixpkgs-unstable` | nixpkgs@3181085bfd08 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | — never |
| 7 | `nmap` | 7.991 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `nodejs_22` | 22.23.2 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | — never |
| 7 | `openssl` | 3.6.0 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | — never |
| 7 | `opentofu` | 1.12.5 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `prometheus` | 3.14.0 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `python3` | 3.12.8 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | — never |
| 7 | `qrencode` | 4.1.1 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-09-07 ([#1488](https://github.com/teststuffstash/homelab/pull/1488)) |
| 7 | `sops` | 3.13.3 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `talosctl` | nixpkgs@4975466d3247 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | — never |
| 7 | `tea` | 0.15.1 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `terraform-providers.cloudflare_cloudflare` | 5.23.0 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | — never |
| 7 | `wireguard-tools` | 1.0.20260223 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 7 | `yq-go` | 4.53.3 | `devbox.lock` | ✅ | ✅ | ✅ | ⚠ | ✅ | ⚠ | 2026-08-31 ([#1131](https://github.com/teststuffstash/homelab/pull/1131)) |
| 8 | `actions/checkout` | 3d3c42e5aac5ba805825da76410c181273ba90b1 (v7) | `.github/workflows/ci.yaml`, `.github/workflows/devbox-cache.reusable.yml`, `.github/workflows/devbox-update.yaml` +3 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-09-27 ([#2038](https://github.com/teststuffstash/homelab/pull/2038)) |
| 8 | `actions/create-github-app-token` | bcd2ba49218906704ab6c1aa796996da409d3eb1 (v3) | `.github/workflows/devbox-update.yaml`, `.github/workflows/renovate-approve.reusable.yml`, `.github/workflows/renovate.yaml` +1 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-09-27 ([#2038](https://github.com/teststuffstash/homelab/pull/2038)) |
| 8 | `docker/login-action` | dbcb813823bdd20940b903addbd779551569679f (v4) | `.github/workflows/devbox-cache.reusable.yml`, `.github/workflows/runner-image.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-09-27 ([#2038](https://github.com/teststuffstash/homelab/pull/2038)) |
| 8 | `docker/setup-buildx-action` | f87e5991a6d7451dcb8d9637bfbc97413f497069 (v4) | `.github/workflows/runner-image.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-09-27 ([#2038](https://github.com/teststuffstash/homelab/pull/2038)) |
| 8 | `renovatebot/github-action` | f3a31a786096ba6b40d0f0ffe11a494ef73bfa7c (v46.3.4) | `.github/workflows/renovate.yaml` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 2026-10-02 ([#2175](https://github.com/teststuffstash/homelab/pull/2175)) |
| 10 | `ghcr.io/actions/actions-runner` | 2.337.0 | `docker/arc-runner/Dockerfile` | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠ | 2026-09-27 ([#2022](https://github.com/teststuffstash/homelab/pull/2022)) |
| 10 | `jetify-com/devbox` | 0.18.4 | `docker/arc-runner/Dockerfile` | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠ | 2026-10-02 ([#2186](https://github.com/teststuffstash/homelab/pull/2186)) |
| 10 | `NixOS/nix` | 2.35.1 | `docker/arc-runner/Dockerfile` | ⚠ the custom manager resolves nothing — `Found no results from datasource that look like a version (dependency=NixOS/nix)` (§Ground truth); fix or remove (#502 acceptance 4) | ✅ | ✅ | ✅ | ✅ | ⚠ | — never |
| 12 | `linkedom` | 0.18.13 | `scripts/mermaid-lint/deno.json` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — never |
| 12 | `mermaid` | 11.17.2 | `scripts/mermaid-lint/deno.json` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — never |

<!-- END GENERATED dependency-coverage -->

**The owner rule (homelab#1992 — FU-097's capability-ledger rule, generalized from box surfaces to
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
`github_renovate_last_pr_timestamp` (→ `RenovateSilent`, the #502 acceptance-3 liveness gauge).
Class 11's members live in three other repos and are not extractable here — §Version SETS below
carries them by hand until #2014 gives them one source.

### Last proven end to end — per LANE, org-wide (S9 #1991; hand-kept)

The generated table above carries homelab's own proof column per class and per dependency
(machine-read from this repo's merged PRs and the capability ledger). This table is its
hand-kept companion for what the generator does not read: **other repos' merges, drills and
negative proofs, one row per LANE** ([`renovate.md`](renovate.md) §"The automerge vs review
split", ADR-141) — the evidence that a lane went through the gates it claims, wherever it first
did. Rows whose evidence is a homelab merge live in the generated column and are not repeated here.

| Class → lane | Last proven end to end | Evidence |
|---|---|---|
| **GitHub Actions, pin/minor** → grouped `automerge` (reflex approves, CI at head) | **2026-09-27** | agent-runtime#157 + openrouter-operator#77 (pin waves) merged on their own once `/.github/workflows/` was un-owned; homelab's #2008/#2021 are class 8's generated row |
| **GitHub Actions, major** → the same grouped lane (ADR-141 amended: no lens until a dependency graduates) | **2026-09-27** | agent-coordinator#22 (`github-actions (major)`) auto-merged 09:51Z, no human, no lens |
| **Actions pin, post-merge rollback** → the FU-1990 chain (`workflow-pin-revert`) | **2026-09-27 (drill)** | agent-coordinator#20 (deliberate bad pin) merged 09:11Z → `GithubWorkflowRunFailed` 09:17Z → revert #21 opened by the App, reflex-approved, merged 09:37Z; ~3.5 min from alert to merged revert, zero human touch; two chain defects found only by the drill (PR#2005 the token mint, PR#2006 the candidate query). Timeline: homelab#1990 |
| **terraform provider pin, post-merge rollback** → the `tofu-provider-revert` chain (S9 #1988) | **2026-10-04 (drill)** | synthetic `MgmtApplyErroredOnNewProvider{provider=random, locked=3.9.1}` injected 11:20:20Z → revert #2209 opened by the App 11:20:51Z (#1976 found as the pin-only introducer), reflex-approved, `management-sentinel` green (plan `+0 ~0 -0`, state compatibility 23 types) → merged 13:03:05Z, box applied 13:03:54Z (`no changes`, stamped); zero human clicks. Three defects found only by the drill: #2210 (body ref), #2211 (judged-types read failed closed on main's empty state list; pr-wait blind to commit statuses); the box-side detector is fixture-proven only. Drill memory line removed from #2209 |
| **pre-commit hooks, patch/minor** → `automerge` | **2026-09-27** | openrouter-operator#73 (gitleaks v8.30.1) merged 12:30Z on the bot approval once `/.pre-commit-config.yaml` was carved out of that repo's whole-repo CODEOWNERS (it had sat REVIEW_REQUIRED two days with APPROVED at head) |
| **terraform providers** → the box's provider-pin plan gates a mechanical `automerge` (ADR-131 amended, #2026) | **2026-09-28** | #2075 (proxmox ~> 0.114) merged 12:49Z and #2096 (talos ~> 0.12) 22:58Z by Renovate on the reflex's approval + `management-sentinel` green (`+0 ~0 -0` on the box's own plan), no human; #2213 (random 3.9.1) the same on 2026-10-04. The lane was built on six human-ordered `+0` plans (2026-09-25..27). #1984 (infisical) merged without a plan — the box holds no infisical root — and was reconciled from the jail afterwards; that root and `tofu/cloudflare-token` are now excluded from the manager. Provider MAJORS armed 2026-10-04 (ADR-141 amended) — their first lens-gated merge is owed |
| **base-image major** → un-armed `major`, the migration lens, a human merges | **2026-09-27** | agent-coordinator#23 (node 22 → 24): lens review under the four headings, `ci` + `build-image` gained a runtime smoke (`claude --version` et al. on the built image, 2b6a9fa), the seat merged 12:18Z; the real acceptance is the first coordinator/reviewer run on `2026.9.27-gca94f4a2dd99` (homelab#2024) |
| **Python runtime deps, patch/minor** → `deps-review` (reflex → CHANGES_REQUESTED → a worker on the `renovate/*` branch) | ❌ **not yet** | FU-046 — no `deps-review` PR has drawn a CHANGES_REQUESTED; openrouter-operator#80 (python 3.14) is `deps-review` but a human merge by that repo's chokepoint rule (operator) |
| **base-image major merging WITHOUT a human** | ❌ **not yet, by design** | stays un-armed until #1988's runtime-in-prod post-merge half exists: a `deploy/agent-coordinator` pin revert on `ArgoWorkflowsFailing` whose pod runs the PREVIOUS tag (a broken coordinator image would otherwise revert the revert lane out of existence) |
| **substrate** (Talos, Kubernetes, Cilium) → never self-merges | ❌ **no Renovate proof** | the 2026-09-22 box-run rollout to Talos v1.14.1 was hand-proposed (row 6 above, ADR-132); the Renovate proposer for class 6 is #1988's substrate row |
| **Helm charts / in-cluster images** (classes 1, 2) → `deps-review` / `major` | ❌ **not yet** | no chart or image bump has ridden Renovate into `argocd/` since the 2026-09-25 restart; the deploy edge (ArgoCD) is proven, the Renovate proposer→gate→merge is not |

### Version SETS — what must move together (operator ruling 2026-09-27; owner #2014)

Some versions are used in several places and a bump in one place alone is worse than no bump
("doing things prematurely is also bad"). The sets, their sources today, and whether they are in
sync. A SET is a cross-repo relation, so this list stays whole and hand-kept until #2014 gives each
set one source: the generated register above carries each in-repo member's pin and proof as its
own row (kubectl in `devbox.lock`, Kubernetes in `tofu/variables.tf`, `DEVBOX_VERSION`/`NIX_VERSION`
in the arc-runner image, the `python` images), and knows nothing of the cross-repo members (the
three claude-code installs, the coordinator image's `KUBECTL_VERSION` ARG, kind in the e2e repos,
each service's python set — class 11). Whether a set is in sync is a fact only this table states:

| Set | Members and how each is set today | In sync? |
|---|---|---|
| **claude-code** | worker (agent-base): devbox `claude-code@latest` → weekly synchronized `devbox-update`; coordinator + reviewer (agent-coordinator image): npm latest at build, rebuilt weekly (Mon 06:00Z); the seat (claude-jail): npm latest at a hand rebuild | ❌ three mechanisms; the two cluster images rebuild on the same cron minute (roughly equal), the jail drifts; no detector |
| **kubectl / kubernetes / kind** | fleet Kubernetes: `machines/machines.yaml` + `tofu/variables.tf`, box-run rollout; kubectl in repos: devbox `@latest` weekly; kubectl in the coordinator image: hand `ARG` (v1.36.1); kind: devbox `@latest` in the e2e repos | ⚠ the skew rule (kubectl within one minor of the server) is nobody's check; the ARG only moves when someone edits it |
| **devbox / nix** | `DEVBOX_VERSION` / `NIX_VERSION` in the arc-runner image (regex-managed); devbox in the jail (`DEVBOX_USE_VERSION`, FU-240); the host `/nix` | ⚠ FU-240's pin is not the runner's |
| **python (per service)** | image `FROM python:X.Y-slim` (Renovate `dockerfile`, `deps-review`); `devbox.json` `python@X.Y` (hand — `devbox update` re-resolves `@latest` only, a pinned major.minor never moves); `pyproject.toml` `requires-python`, ruff `target-version`, mypy `python_version` (hand) | ❌ openrouter-operator#80 (2026-09-27): image 3.11→3.14, everything else 3.11 — CI ran the old runtime, the review approved "no adaptation"; the lens now names the set (`agents/lenses/migration.md` §Version SETS) |

**The model to match:** `devbox-update.yaml` — one weekly job re-resolves every repo together, one PR
per repo, majors to the human lane. Anything that floats on its own cron (row 11) is a tracked gap,
not a solution.

### "Tofu" is not one class — the five roots differ in owner, credential and blast radius

Rows 4–6 above lump five state roots that need different rulings:

| Root | Credential | Ruling |
|---|---|---|
| `tofu/github` | org-admin PAT (applies, **host only**) + a read-only PAT on the management box (plans) | **Applies operator-only; plans automated since 2026-09-13** (FU-238, ADR-131): state on Garage, the box plans every PR touching the root (`management-sentinel`) and reads drift (the belt) with a read-only token — the earlier "nothing automated can even init" line is superseded; applies still never leave the host |
| `tofu/cloudflare` | scoped CF token, in jail | Low blast radius (one zone; a bad apply hurts `ha.teststuff.net`, not the updater). Automatable plan, arguably apply |
| `tofu/infisical` | Infisical creds | Slated to leave tofu for ESO/Crossplane — don't invest automation here |
| `tofu/provisioning` | PVE token | PXE content is **inert until the next netboot** — the safest root to automate |
| `tofu/` (main) | PVE token + talosconfig + kubeconfig + KeePass env | **Mixed**: benign helm releases and dashboards next to VM definitions, Talos configs and Cilium — see the ArgoCD lever below |

Two consequences the table above glosses over:

- **Any automated `tofu plan` has a hard prerequisite: FU-012.** Every root's state is local and
  gitignored **in the jail** — no in-cluster or CI process can plan *at all* until state moves to a
  remote backend (or to wherever the automation runs).
- **The main root's lump is reducible: migrate its helm releases to ArgoCD.** Moving
  kube-prometheus-stack, metrics-server, forgejo(+runner) and garage from `helm_release` to
  `argocd/platform/` Applications converts them class 4 → class 1: the path→deploy edge exists
  natively, ArgoCD OutOfSync **is** the drift belt (no plan cron, no FU-012 dependency, no tofu
  creds anywhere), the FU-044 revert extension covers them, and Renovate targets plain YAML
  `targetRevision`s instead of terraform lockfiles. What stays in tofu — Proxmox/Talos/VMs, Cilium
  (day-0 bootstrap, needed before ArgoCD runs), image factory — is then *exactly* the substrate
  that keeps the human gate, which makes "tofu = human-applied" a coherent rule instead of a lump.
  This is a candidate **ruling** for the FU-097 table, and it is *consistent with* ADR-005's
  governing rule ("anything ArgoCD needs in order to run cannot be ArgoCD-managed") — none of the
  four charts above are things ArgoCD needs. Longhorn IS in ADR-005's substrate list, so moving it
  (even as a manual-sync app) would be an ADR-005 addendum, not a quiet migration.
  ⚠ **The raw-`kubernetes_*` residue the helm move left behind is kept in tofu ON PURPOSE** — it
  is the management box's nondestructive test surface, and it migrates only after the box has
  proven itself and Renovate rides through it: [`management-box.md`](management-box.md) §The
  test surface (operator, 2026-09-13).

### Executing the lever — the migration order and the one unverified fact

Written 2026-08-04 for a fresh session; the design above is already cleared (ADR-005: none of these
four are things ArgoCD needs in order to run — Longhorn is, which is why it is not on the list).
What remains is mechanical, and dangerous in a specific way: each release is a `tofu state rm` +
an ArgoCD Application that must **adopt** the live Helm release. Get adoption wrong on garage and
you do not get a failed apply, you get an empty bucket.

**The gating fact — SETTLED on metrics-server, 2026-08-04: ArgoCD adopts, and it adopts silently.**
It does not install alongside, because it never installs at all: ArgoCD `helm template`s the chart
and applies the rendered objects, so there is no second Helm release to collide with the first. The
two ownership systems agree *by construction*, not by luck, as long as the **Application name equals
the Helm release name** — the chart renders `app.kubernetes.io/instance: {{ .Release.Name }}`, and
ArgoCD's default `label` tracking wants that same key set to the Application name. Keep those names
equal for every remaining release; that equality is the whole mechanism.

Two consequences worth carrying forward:

- **The live Helm metadata survives and is harmless.** `meta.helm.sh/release-*` annotations and
  `app.kubernetes.io/managed-by: Helm` stay on the objects — ArgoCD's rendered output doesn't
  contain them, so the 3-way merge leaves them alone and they don't show as OutOfSync.
- **The pre-flight is free and it is the real gate.** `helm template <release> <chart> --version
  <same> -n <ns>` piped into `kubectl diff -f -` answers "will adoption change anything?" *before*
  any `state rm`. On metrics-server it came back empty, and the subsequent adoption changed nothing
  (Synced/Healthy, one ReplicaSet, pod start time unmoved). Run it per release; an empty diff is the
  green light, a non-empty one is the whole reason the order is least-valuable-first.

⚠ **Rollback works but does not plan clean** (measured, not assumed). `tofu import` restores
ownership with **0 to destroy** — but the helm provider cannot read `repository` or `values` back
out of a release, so the next plan shows **1 to change, in place**: it re-attaches those two
attributes and recomputes `metadata`. Applying it is a no-op Helm upgrade (revision bump), not a
recreate. Do not read that diff as "the import was wrong" — and do not let step 1's "plan clean
first" rule block a rollback.

**Order, least-valuable first:**

| # | release | why here |
|---|---|---|
| 1 | `metrics-server` | the adoption canary — stateless, instantly rebuildable, nothing depends on its history. **DONE 2026-08-04** (`argocd/platform/metrics-server.yaml`) |
| 2 | `forgejo` (+ runner) | stateful but mirrored from GitHub; recoverable. **DONE 2026-08-04** (`argocd/platform/forgejo.yaml`) — needed TWO conversions (admin + DB) and an ArgoCD OCI repo registration |
| 3 | `kube-prometheus-stack` | losing it blinds every alert built this month, incl. the Longhorn metering. **DONE 2026-08-04** (`argocd/platform/kube-prometheus-stack.yaml` + `values/`) — the release that moves alert rules out of the tofu class |
| 4 | `garage` | LAST, and it needed THREE gates rather than one: a backup (FU-137), *two* secrets behind references (`rpcSecret` comes from `random_id` — invisible to a `random_password` grep), and the vendored chart moved out of `tofu/` to `argocd/charts/garage`. **DONE 2026-08-04** (`argocd/platform/garage.yaml`) |

### The secret-in-values gate — why release 1 was free and 2-4 are not

**Discovered while executing 2026-08-04, and it changes the shape of the remaining work: all three
remaining releases inject a secret into the chart through tofu-rendered Helm values.** The
destination (`argocd/platform/`) is a **public git repo**, so a literal lift-and-shift of the values
block publishes a live credential. metrics-server was the only release with no secret in its values
— which is *also* why it was the free canary, a coincidence worth naming rather than trusting again.

| release | the secret in values | tofu source |
|---|---|---|
| `forgejo` | `gitea.admin.password` **and** `gitea.config.database.PASSWD` | `random_password.forgejo_admin` / `random_password.forgejo_db` |
| `kube-prometheus-stack` | `grafana.adminPassword` | `var.grafana_admin_password` (KeePass wallet via `keepass-env.sh`) |
| `garage` | `GARAGE_ADMIN_TOKEN` as a literal env `value` | `random_password.garage_admin_token` |

So each of 2-4 needs a **preparatory step that release 1 didn't have**: convert the value into a
*reference* to a k8s Secret **while tofu still owns the release**, verify the workload is happy
reading it that way, and only then run the migration sequence. Reference-not-value is the
repo's standing rule for the public repo; this is the same rule arriving at a new surface.

Two consequences:

- **The empty-diff pre-flight is what proves the conversion**, not just the migration. Flipping
  `adminPassword: <literal>` → `admin.existingSecret` re-renders the Deployment (env source
  changes), so that diff will NOT be empty — it is a real, intended change that must go through
  tofu apply first. Only once the release is on the reference does the migration diff go empty
  again. Two separate changes, two separate verifications; collapsing them is how a canary stops
  being a canary.
- **The `random_password` resources outlive the `helm_release`.** They stay in tofu state, feeding
  the k8s Secret the chart now reads — so for forgejo and garage, tofu keeps owning the *secret*
  after it stops owning the *release*. That is fine, and it's the ESO/Infisical migration's
  natural next target (`minimize-tofu` direction), not something the lever has to solve first.

**All three conversions landed 2026-08-04** (FU-136 archived) — the mechanism each chart actually
supported, verified rather than trusted from its docs:

| release | how the secret left the values |
|---|---|
| `forgejo` | `gitea.admin.existingSecret: forgejo-admin-creds` (`-creds` because the CHART owns the name `forgejo-admin`) + `gitea.additionalConfigFromEnvs` carrying `FORGEJO__DATABASE__PASSWD` out of the CNPG `forgejo-pg-app` Secret into init-app-ini |
| `kube-prometheus-stack` | `grafana.admin.existingSecret: grafana-admin` |
| `garage` | the `environment` list took a `valueFrom.secretKeyRef` (`garage-admin-token`) — the mechanism that was least certain, on the one release that is unrecoverable |

The `random_password` resources stayed in tofu state as predicted: tofu still owns the *secrets* for
forgejo and garage after it stopped owning the *releases*.

**Per release, the sequence is the labels-handoff shape** (`scripts/labels-handoff.sh` is the worked
example — dry-run by default, refuses to report success when it cannot see state):

1. `devbox run tf-plan` clean first — never migrate on top of unrelated drift.
2. `tofu state list | grep '^helm_release\.<name>$'` — scoped exactly, never a bare name grep.
2b. The **empty-diff pre-flight** above (`helm template` → `kubectl diff -f -`), while tofu still
   owns the release. Nothing is committed to until it comes back empty.
3. `tofu state rm 'helm_release.<name>'` — tofu FORGETS; Helm and the workload are untouched.
4. Add `argocd/platform/<name>.yaml` pinning the SAME chart version and values, `syncPolicy` with
   `selfHeal` but **`prune: false` on the first sync** — a stray prune is the destructive path.
5. Verify: `kubectl get helmrelease/secret -l owner=helm` still shows ONE release, the workload
   never restarted, and the ArgoCD app reports Synced/Healthy without having recreated anything.
6. Only then flip `prune: true`, and only then start the next release.
7. Remove the `helm_release` block from `tofu/*.tf` in the same commit as step 4, so git never
   claims two owners for one release.

**Rollback at any step:** `tofu import 'helm_release.<name>' <ns>/<name>` puts it back under tofu.
Establish that this works on metrics-server too, before it is needed under pressure.

---

## What a full platform dependency upgrade should look like

Five stages. The point of writing them out is that **today only stages 1–3 exist, and only for some
classes** — stages 4 and 5 are where the gaps are.

### 1. Propose

- **Renovate opens the PR** against the global policy in
  [`renovate-global.json`](../.github/renovate-global.json): 7-day cooldown (security bypasses it;
  pins, digests and Docker tags are timestamp-optional since 2026-09-27 — a tag without a release
  timestamp used to sit pending forever), Actions SHA-pinned, OSV alerts on, every major labelled
  `major` (the lens marker) — the LANE is the blast class's (ADR-141).
- **The classification decides the lane, not the reviewer's mood:** digest/pin → `automerge`;
  runtime version bumps and base-image minors → `deps-review`; **every** major → `major` (the lens
  marker), un-armed — EXCEPT GitHub Actions, where every update type rides the grouped `automerge`
  lane until a dependency graduates on evidence (ADR-141 as amended 2026-09-27;
  [`renovate.md`](renovate.md) §"The automerge vs review split").
- **First-party artifacts never ride Renovate** — a `2026.<m>.<d>-g<sha>` version doesn't order, so
  the deploy-pin PR opens them (ADR-084).
- Fires in homelab since 2026-09-25 (§Ground truth); which lane has actually carried a merge is
  §"Last proven end to end" — a class without a dated row there is still aspirational.

### 2. Review

- **`automerge` lane** — no human, no LLM. The gate *is* cooldown + CI + the `renovate-approve`
  reflex. A human diffing two SHA-256s is theatre.
- **`deps-review` lane** — the **LLM reviewer** via the merge-path review reflex, not a human
  (FU-046). Harmless → approve → auto-merge. Needs adaptation → `CHANGES_REQUESTED` → a worker
  adapts the code **on the `renovate/*` branch**. Never close the PR: closing is not a terminal
  action — [`renovate.md`](renovate.md) §Coordinator × Renovate explains why (churn, and
  vulnerability PRs are recreated regardless). To abandon an upgrade durably, change the **config**.
- **`major` lane** — un-armed, coordinator-owned, human merges (`agents/major-handoff.sh` sets
  `major/awaiting-human` only on the reviewer's APPROVED at head under the lens's four headings). An
  ARMED `major` (a GRADUATED GitHub Actions dependency, ADR-141 as amended) is the reflex's: the
  reviewer's lens approves, CI + the FU-1990 revert chain are the gate. Un-graduated Actions majors
  carry no `major` at all — they ride the grouped `automerge` lane. Terraform providers are neither:
  `major/awaiting-human` on any type, the human plan is the gate (row 5).
- **Platform-specific review question the app lanes don't ask:** *does this bump violate a platform
  invariant?* The ip-plan ranges (ADR-088), storage caps (ADR-089,
  [`storage-ledger.md`](storage-ledger.md)), the `bgp=advertise` label contract, secret
  references-never-values. That's a **policy-as-code** job, not a reading job — the same L0 lane
  `iac-lane.md` §Assurance layers builds for `-iac`.

### 3. Test / lint

What `ci` gates on a homelab PR today: the authoritative list is `.github/workflows/ci.yaml`
(~28 `devbox run` steps + 3 inline blocks — highlights: `argocd-validate-pins`, `agents-registration-lint`, `merge-path-lint`,
`github-apps-lint`, `router-self-test`, `manifest-lint` (kubeconform, since 2026-08-04),
`prometheus-rules-lint` (promtool, since 2026-08-11 — FU-158), the ADR-103 replay ratchet,
`tofu fmt -check`). ⚠ homelab has NO `devbox run ci` aggregate task — the workflow is the list.

**What is missing for a dependency bump specifically:**

- **No `tofu validate` / `tofu plan` in CI** for classes 4–6 (`fmt -check` IS in ci since
  2026-08-04; `validate` stays out — the FU-130 WAN class). A provider bump can merge with
  nobody having rendered it.
- ~~No kubeconform for class 2~~ — `manifest-lint` (kubeconform `-strict`) is a required check
  since 2026-08-04; the residue is its CRD skip-set (the G04 sentinel's problem).
- **No policy-as-code** for the platform invariants above.

### 4. Rollout

This is where the three regimes diverge and where the design work is:

- **GitOps classes (1, 2, 3)** — ArgoCD syncs on merge. The missing piece is **not** the trigger, it
  is the **post-deploy verdict**: ArgoCD health is a *shallow* gate (the meta-11 schema-skew outage
  stayed green on a `tcpSocket` probe). The deterministic revert exists —
  Degraded ≤120m after a `deploy/*` bump → auto-revert PR
  ([`agents/iac-lane.md`](agents/iac-lane.md) §"ArgoCD health is NOT the post-deploy gate", FU-044)
  — but it is scoped to `-iac` deploy bumps, **not to a platform chart bump merged into homelab**.
  **⚖ Extending it wholesale is REJECTED (operator, 2026-08-04).** The platform barely has the
  trigger — only first-party image pins move as `deploy/*` (class 3), while classes 1/2/4 move by
  chart-version bumps and hand edits — and revert is not free for the stateful ones (garage, CNPG:
  CRD/schema downgrade, PVC expectations, data-layer skew), with no second net if the revert also
  fails. The extension is scoped to the **reversible class**: a first-party image pin, no
  CRD/schema migration, no data-layer coupling. Everything else Degraded goes to the responder as
  an alert + report-only issue. Ruling + precondition:
  [`agents/iac-lane.md`](agents/iac-lane.md) §"Auto-revert does NOT generalize to the platform"
  (IAC-G09).
- **Tofu classes (4, 5)** — keep the human gate. Add the belt FU-097 asks for: a **`tofu plan` cron
  → alert on non-empty diff**, so "merged but not applied" and "live drifted from state" both become
  visible instead of silent. The prerequisite (FU-012's state move) is met for `main`: the management box plans
  every master move and every PR, and `MgmtApplyResidueStanding` alerts on an unapplied plan
  ([`management-box.md`](management-box.md) §MB2/§MB3). (Or shrink the class instead: the ArgoCD lever
  above removes the need for the belt on everything it migrates.)
- **Substrate (6)** — a deliberate, staged node rollout: one metal node first, `talosctl health`,
  Longhorn rebuild-complete, then the rest. VMs upgrade in place too since ADR-014's 2026-09-18
  amendment, but only with the platform- and schematic-correct factory installer.
- **Unreconciled (9)** — the FU-097 first deliverable. The candidate shape is already precedented:
  an **in-cluster ansible Job** (ArgoCD PostSync or CronWorkflow, creds via ESO), with a nightly
  `--check` diff → alert as the minimum belt even if apply stays manual. ⚠ For **OPNsense**
  specifically the in-cluster Job sits *inside its own blast radius* — see the cone rule below.

**Where the runner sits — the dependency-cone rule.** Belts are read-only (`--check`, `plan`,
drift alerts) and safe to automate anywhere, including in-cluster. **Applies are only safe to
automate from a runner outside the change's dependency cone, or with an out-of-band deadman.**
Concretely: an in-cluster `tofu apply` touching Cilium, ArgoCD, Longhorn or the VM definitions can
sever its own pod's network/storage/node mid-apply — with local state that also means a locked or
half-written state file. An in-cluster ansible Job pushing OPNsense config changes the router that
carries the Job's own network path: a bad apply cuts both the connection *and* every rollback path,
and ArgoCD can't even report the failure anywhere reachable. The commit-confirm shape fixes the
latter: schedule a config restore on the target *before* applying, cancel it only when the
post-apply health probe passes. Matchbox, in the same ansible class, has a near-zero cone (nothing
depends on it until the next PXE boot) — another reason class 9 is not one class. The full
no-human end-state analysis (HA router pair, management network, out-of-band coordinator, what
remains genuinely human): [`spikes/no-human-in-the-loop.md`](spikes/no-human-in-the-loop.md).

### 5. Monitoring

A bump is not done when it merges; it is done when nothing broke. What exists and what doesn't:

| Signal | Exists? | Notes |
|---|---|---|
| ArgoCD app health / sync status | ✅ | shallow — see above |
| Prometheus + Alertmanager → responder triage | ✅ | one bounded LLM session per new fingerprint ([`agents/iac-lane.md`](agents/iac-lane.md) §"one root cause, N alert issues"; FU-133, archived) |
| Blackbox probes on service endpoints | ✅ | FU-099 — seconds-grade, dumb |
| Deep [contract probe](glossary.md) post-deploy | ❌ | the **prober** role ([`agents/roles.md`](agents/roles.md) §prober, FU-102) — the real acceptance signal |
| Storage-cap breach visibility | ✅ | Garage admin metrics scraped + `garage-alerts` belts since #965 (2026-08-25); Longhorn metering since 2026-08-04 — the pve thin-pool `Data%` is FU-093's remaining gap ([`storage-ledger.md`](storage-ledger.md)) |
| **Renovate liveness** | ✅ | `github_renovate_last_pr_timestamp` per repo on the github-exporter → `RenovateSilent` (14 d org-wide, `warning`) since homelab#1992 — the #502 acceptance-3 gauge; the dashboard-issue half was retired by ruling |
| **Coverage-table rot** | ✅ | `github_dependency_coverage_gap_rows` / `_complete` / `_last_proven_timestamp` per class → `DependencyClassProofStale` (a complete class whose proof is >90 d old) — §The dependency inventory |
| **Substrate currency / support window** | ✅ | the management box's belt compares the declared Talos / Kubernetes / Cilium versions against upstream releases and alerts on "a newer minor exists" and on "ours is EOL" — [`management-box.md`](management-box.md) §MB2 (FU-254). The sibling of the row above, and **not** a thing Renovate could have covered: class 6 must not auto-deploy |
| Drift between tofu applies | ⚠ partial — `MgmtApplyResidueStanding` + `MgmtNode*Drift` | FU-097, FU-235 |

**The observation window** (`iac-lane.md` §Progressive delivery) is the frame to reuse: sync → health
→ *window* → promote or revert. Today a homelab platform bump has a sync and a shallow health check,
and then nothing is watching.

---

## Next steps, in dependency order

1. ✅ **Renovate runs again** — the cause was the missing `statuses` permission (§Ground truth,
   diagnosed and granted 2026-09-25); the invalid `vulnerabilityAlerts.prPriority` is dropped
   (validator-clean). ✅ The Actions SHA-pinning landed 2026-09-27 as #2021, rebuilt by Renovate
   under the first-party exclusion (the first cut, #1970, froze
   `teststuffstash/homelab/…reusable.yml@master` at one SHA and was closed — §Gotchas in
   [`renovate.md`](renovate.md)). Remaining: either fix or remove the `NIX_VERSION` custom manager
   (it still resolves nothing).
2. ✅ **Renovate-liveness signal landed (homelab#1992)** — `github_renovate_last_pr_timestamp` on the
   github-exporter + `RenovateSilent`, and the generated coverage table's own rot detector beside it.
   (The dashboard-issue-exists option is gone — `dependencyDashboard: false` by ruling, 2026-08-18.)
3. ✅ **CI gaps closed 2026-08-04** — `manifest-lint` (kubeconform `-strict`) over
   `argocd/resources/*` and `tofu fmt -check -recursive` are both required checks. Two residues by
   decision, not omission: `tofu validate` stays the local `devbox run tf-validate` gate (a provider
   download per PR, the FU-130 WAN class), and **87 of 154 resources are SKIPPED** for want of a
   local CRD schema — `manifest-lint` prints that count every run and fails if it ever validates
   nothing ([`agents/iac-lane.md`](agents/iac-lane.md) §The platform lane).
4. **Extend the FU-044 deterministic revert** to homelab's own ArgoCD apps **for the reversible
   class only** (first-party image pins — no CRD/schema migration, no data-layer coupling); the
   rest stay responder + report-only, per the ruling in §4 above. Half wired 2026-08-04 (pin-only
   predicate in `deploy-revert-argo.yaml`, unit-exercised, never fired by a real Degraded app).
4b. ✅ **Platform lane's path gate landed 2026-08-04/05** — repo-root `CODEOWNERS` + homelab
   flipped to `require_approval` + `require_code_owner_review` (FU-068), then `.agents/fix.yaml`
   made the lane dispatchable (FU-142): [`agents/iac-lane.md`](agents/iac-lane.md) §The platform lane.
5. **FU-097's ruling table**, with ansible/OPNsense first — it is the only class where a merged
   change reaches a *live network device* by hand or not at all.
6. **The prober (FU-102)** is what turns "it synced" into "it works".
7. **Turn on the class 1/2 proposers — AFTER #2047 (operator, 2026-10-04: S9's next session takes
   #2047 first).** Neither class has a proposer: Renovate's `argocd` and `kubernetes` managers have no
   `managerFilePatterns` in [`renovate-global.json`](../.github/renovate-global.json), so every chart
   bump is hand-proposed (homelab#2200, Argo Workflows 1.0.20 → 1.0.24, 2026-10-03, was found by an FU
   sweep, not by a proposer). The change: an `argocd` pattern over `argocd/platform/*.yaml` (+
   `kubernetes` over `argocd/resources/**`), one group for the ARC controller + runners (two files,
   one version — row 1's canary cell), and a PR cap (`prHourlyLimit`/`prConcurrentLimit` ~3) so the
   ~30-chart backlog drains instead of landing as one wave on the reviewer and the shared App GraphQL
   pool (FU-290 — the 2026-09-25 wave drained it). CRD-carrying charts (Argo, Crossplane, Longhorn) still
   reach the `major` lane by update type.
8. **agent-coordinator is the first repo through, but not done-done (read 2026-10-04).** Proven with
   no human: base-image patch/minor, every Actions update type + the pin-revert drill, s5cmd, the
   Monday rebuild → deploy-pin → auto-merged homelab PR (§Last proven). Open: (a) 25 manifest refs the
   deploy-pin sweep never reaches (19 float to `:latest`, 6 stale tags — the register's class-3 row) —
   mechanical, and the one gap that makes "deploys to prod on its own" untrue for those consumers;
   (b) the hand `KUBECTL_VERSION` ARG (§Version SETS, kubectl row — no proposer, no skew check);
   (c) base-image majors stay a human merge until #1988's previous-tag revert exists (§Last proven);
   (d) the claude-code set's three mechanisms (§Version SETS). (a) and (b) are the next repo-level
   deliverables before the next repo onboards the same way.
