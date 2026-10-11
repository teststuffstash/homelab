# Renovate — dependency updates + supply-chain hardening (the S2C2F consumer leg)

Self-hosted Renovate keeps our dependencies current **and** is our first line of defence for the
things we *ingest* — the consumer side of the supply chain ([`slsa.md`](slsa.md) names this **S2C2F**
but hadn't built it — since built). LIVE since 2026-09-25 (the App's missing `statuses` grant,
FU-125 — archived 2026-09-27) and routed through the S9 lanes since 2026-09-27 (homelab#1985,
ADR-141); which class has actually merged through which lane is the generated coverage table in
[`dependency-upgrades.md`](dependency-upgrades.md) §The dependency inventory (homelab#1992 — one row
per pin × proposer/gate/edge/detector/revert/canary/last proven) and its per-lane companion §"Last
proven end to end"; liveness is the `github_renovate_last_pr_timestamp` gauge → `RenovateSilent`,
never the workflow's own verdict.

## Shape

```
homelab/.github/workflows/renovate.yaml   scheduled runner on the ARC tier, runs as the homelab-renovate
   │  (autodiscover; RENOVATE_CONFIG_FILE = the global baseline)   App → walks the repos it's installed on
   ▼
homelab/.github/renovate-global.json      the SUPPLY-CHAIN BASELINE enforced on EVERY repo (below)
   ▼
<repo>/renovate.json                      per-repo EXTRACTION coverage + automerge preferences (§Scope)
   ▼
reviewer-approve reflex (per repo)        homelab-reviewer bot approves `automerge`-labelled PRs →
                                          satisfies required-approval → GitHub merges on CI-green
                                          (idempotent since 2026-08-11: per-PR concurrency group +
                                          fail-closed APPROVED-at-head dup check — homelab#114)
```

**Scope — who owns what.**
- The baseline **fails closed**: every non-major update a named rule does not place lands in
  `deps-review`, armed — so every ecosystem has a reader with no platform work (the catch-all rules in
  `renovate-global.json`; their description says how they avoid the `addLabels` union).
- Explicit rules only **lower** cost (a class → mechanical `automerge`, or dev vs runtime tiers), and are
  added when a pattern appears in ≥2 stacks.
- One blessed variant per language gets first-class lanes (Python = uv, i.e. the `pep621` manager);
  other variants work at review cost.
- A stack's `renovate.json` owns **extraction** coverage (`managerFilePatterns`, `customManagers`,
  `ignorePaths` for repo-specific files — e.g. dropping the `**/tests/**` preset skip) plus automerge
  preferences, and never overrides a lane (majors → `automerge` is out of contract).
- A lane hole a stack finds is a baseline bug — report it to homelab (#1988's no-lane class;
  `devbox run renovate-lane-lint` is the check).

"Add a repo to Renovate" = install the `homelab-renovate` App on it (autodiscover does the rest).
Bootstrap: `scripts/github-app-bootstrap.sh homelab-renovate`.

A lane is trusted only once [`dependency-upgrades.md`](dependency-upgrades.md) §"Last proven end to
end" carries a merge for it; liveness is the `RenovateSilent` gauge (the 2026-07 → 09-25 silent
stretch, §Ground truth there, is why the workflow's own green is never the signal).

## Threat model — mitigate a Trivy-style compromise

The Trivy compromise (March 2026): attackers hijacked the repo to publish **backdoored binaries**
(v0.69.4+) and **re-pointed 76/77 action tags** (`aquasecurity/trivy-action` `0.0.1…0.34.2`) to a
credential-stealing payload. A naive "always take the latest tag" pipeline would have ingested it
immediately. Our baseline blunts both vectors:

| Mitigation (`renovate-global.json`) | What it stops | Idea from |
|---|---|---|
| **Cooldown** — `minimumReleaseAge: "7 days"` | Adopting a freshly-compromised version inside the detection window (Trivy was caught in days). Non-security only. | pnpm `minimumReleaseAge` |
| **SHA-pin Actions** — `helpers:pinGitHubActionDigests` | **Tag re-pointing** — a hijacked `@v4` can't inject if we're on the immutable commit SHA. Renovate keeps the SHA current (+ the tag in a comment). | SLSA / pinning |
| **OSV alerts** — `osvVulnerabilityAlerts` | Known-vulnerable **direct** deps already on the base branch; raises fix PRs from OSV (no GitHub Dependabot dependency — self-host ethos). **Security fixes bypass the cooldown** (get them in fast, CI still gates). It never sees a TRANSITIVE dependency, nor what a PR brings in — that is the next row. | SLSA S2C2F |
| **Lockfile intake** — `lock-intake-lint` in `ci` ([ADR-143](adr.md)) | What a PR's lockfile change brings in, transitive included: fails an OSV-flagged (incl. `MAL-`), <7-day-old or install-script-bearing version. Static — reads lockfiles + registry metadata, runs nothing — so it decides before any step executes dependency code. Covers `deno.lock` + `package-lock.json`; any other lockfile type fails closed until it has an extractor. | the #2032 lodash-es miss |

Not yet built (the strongest, aspirational leg): **verify SLSA provenance / signatures** on consumed
artifacts (`cosign verify-attestation`) so a backdoored artifact is rejected even *inside* the cooldown.
Needs the upstream to publish verifiable provenance + a verify step in CI — [`slsa.md`](slsa.md) Phase-later.

## The automerge vs review split — "is there anything a human can actually review?"

The principles, which every lane applies; **the per-class rulings themselves live in ONE place,
[`dependency-classes.yaml`](dependency-classes.yaml) (rendered as the register in
[`dependency-upgrades.md`](dependency-upgrades.md) §The dependency inventory) — this doc does not
restate them, and a lane question is answered there, cell by cell.**

- **Digest bumps are mechanical** (`@sha256`, SHA-pinned Actions): a human comparing two hashes is
  theatre; the gates are the cooldown, CI on the head and the reviewer reflex (`automerge` label →
  reflex approval → CI-green auto-merge).
- **Reviewable bumps go to the LLM reviewer, not a human** (`deps-review`): the merge-path review
  reflex + the migration lens read the changelog; APPROVED merges, CHANGES_REQUESTED parks the PR for
  a worker to adapt the code on the Renovate branch (FU-046).
- **Majors are un-armed by default and ARM per class on evidence** (ADR-141): the `major` label is
  kept and no `automerge` label is added, so the reflex refuses it and the lens's APPROVED completes
  the merge — behind that class's own detector + revert pair (the register's columns). An Actions major
  graduates to its own ungrouped `major` PR the first time a revert names it, its PR goes red, or a
  review asks for an adaptation. A chart major arms itself when it is packaging-only
  (`appVersion: unchanged`, `agents/major-handoff.sh`). The marker must not leak: Renovate MERGES
  `addLabels` across rules, so every mechanical rule is restricted to non-major update types.
- **The management box is the gate where a merge is an apply** (tofu providers, tofu-managed charts):
  the sentinel's plan-on-PR must be empty or a default backfill (ADR-131); the lens is the merge gate
  for majors; the box's bracket is the deploy edge, forward only (FU-301).
- **Security fixes** (OSV) fast-track: no cooldown, `automerge`, auto-approved, auto-merged.

Each merge that touches a deploy path (`uv.lock`, `Dockerfile`, …) flows through the automated
deploy (ADR-084), so a hands-off dep bump reaches prod on its own.

## Coordinator × Renovate PRs — "close" is NOT a terminal action

A Renovate PR is **not** an agent PR, so the coordinator's usual escalation verbs differ — Renovate,
not the coordinator, owns whether an update should exist:

- **Reviewer requests changes** → the PR stays OPEN (changes-requested doesn't close it), Renovate
  won't duplicate it, and `rebaseWhen: conflicted` keeps it stable. Action: **dispatch a worker to adapt
  the code on the renovate branch** (FU-046) — never close. **Not on the GitHub Actions lane** (ADR-141):
  those PRs are grouped per repo per wave and ride `rebaseWhen: behind-base-branch` — Renovate keeps its
  own branch current and re-extracts master on every rebase (a call site added on master after the PR
  opened gets bumped on the next rebase, never by a request-changes), and it stops maintaining a branch
  the moment anyone else pushes to it (its edited-PR rule — the operator's update-branch on
  agent-coordinator#14 is why the third `actions/checkout` site there was never bumped). The reviewer
  reads such a PR as a batch member with no fixer behind it; the in-cluster updater leaves untouched
  Renovate PRs to Renovate.
- **Closing a Renovate PR is not "done."** With Renovate's default `recreateWhen: auto`, a manually
  closed PR is *not* recreated for the **same** version (close = "reject this version"), but Renovate
  DOES open a fresh PR when a **newer** version lands → a reject→close→new-version→reject **churn**; and
  **vulnerability PRs are recreated even when closed**. So a bare close never durably abandons an upgrade.
- **To abandon an upgrade durably, change the Renovate CONFIG, not the PR:** `ignoreDeps`, a
  `matchPackageNames … "enabled": false` rule, or an `allowedVersions`/`matchCurrentVersion` pin. That is
  the coordinator's (or human's) "don't do this bump" verb for Renovate PRs.

The coordinator loop runs in-cluster, unsuspended since 2026-07-28 (`reflexes-argo.yaml`); the
changes-requested→worker transition exists for `major` PRs (the brief's major play, step 3) but has
never fired on a `renovate/*` branch (FU-046, unproven as of 2026-09-27) — until it does, a
reviewer-rejected Renovate PR simply **parks**: open, changes-requested, auto-merge hard-blocked.
Safe: no duplication, no churn, nothing auto-acts on it.

## Gotchas encountered

- **Validate the LANES, not just the syntax: `devbox run renovate-lane-lint`** before landing a change
  to `renovate-global.json`. Renovate arms a grouped branch only when EVERY member has
  `automerge: true` while labels are the UNION — a rule gap on one member produces a lane-labelled,
  un-armed PR nobody reads (G15: #2295 sat 16 h green). The verb runs Renovate itself
  (`--platform=local --dry-run=lookup`, trace log) over the checkout and asserts one lane per branch;
  ~2 min of datasource lookups, so a seat verb, not CI (operator 2026-10-06 — CI WAN stays locked
  down). `--self-test` replays the fixture; `--trace FILE` re-asserts a saved run.
- **`postUpgradeTasks` run in the SLIM image, with no shell.** The pinned `renovatebot/github-action`
  runs `ghcr.io/renovatebot/renovate:<version>` — containerbase + `jq`, no helm/yq/python — and executes
  each command via execa (no `&&`, no pipes unless `allowShellExecutorForPostUpgradeCommands`, which we
  do not set). Tools come from a runtime `install-tool <tool> <ver>` command (slim keeps
  `binarySource=install`; the `-full` image sets `global`, which also disables `installTools`), every
  command string must match the global `allowedCommands` exactly (compiled as a Handlebars template
  first), and `fileFilters` is the ONLY way a generated file reaches the commit (never `git add`). The
  one consumer today: the kube-prometheus-stack rule re-rendering the upstream alert list on its branch
  (G12 — `scripts/upstream-alerts-refresh.sh` is yq-free for exactly this container). The `install-tool helm`
  version is Renovate-proposed (2026-10-10): two `customManagers` over `renovate-global.json` itself
  (depName `helm/helm`) rewrite the command AND its regex-escaped `allowedCommands` entry in one branch
  (`currentValueTemplate` + `autoReplaceStringTemplate` for the escaped half), so the pair never drifts
  apart; the PR is codeowner-gated (`/.github/`). A dry run
  (`workflow_dispatch` → `dryRun`) still executes the commands and logs `DRY-RUN: Would commit files`,
  but only when a branch is (re)built — an up-to-date branch runs nothing, so the proof is the next bump.
- **`pinGitHubActionDigests` pins our OWN reusable workflows too** — the first live run
  (2026-09-25) SHA-pinned every `teststuffstash/homelab/.github/workflows/*.reusable.yml@master`
  caller, freezing it at one homelab commit (and queueing a digest PR per master move). First-party
  `teststuffstash/**` refs are excluded in the global config; `@master` is the contract.
- **`@latest` devbox/nix pins are un-trackable** → Renovate mis-resolves them (it once proposed
  downgrading gitleaks to a dead 5-yr-old release). The `nix`/`devbox` manager is **disabled**; devbox
  updates are owned instead by the weekly **`devbox-update`** job (`scripts/devbox-update.sh` /
  `.github/workflows/devbox-update.yaml`), which keeps `@latest` but
  re-resolves *all* repos' locks in one pass so the shared toolchain aligns (nix cache + agent-base bake
  hits) — alignment a per-repo Renovate bump can't give. The PR body carries a second section —
  same-major downgrades + compatibility-line moves of python3/opentofu/kubectl/openssl — that the
  migration lens answers line by line; it informs, never un-arms (G17, ADR-141 as amended 2026-10-06).
  A lock MAJOR is armed too (`major` kept, the lens's APPROVED completes the merge; opentofu majors
  excepted — §"The automerge vs review split"); a reverted lock version is refused by `pin-only-lint`
  check (i) for 30 days, which holds the WHOLE weekly PR red — the lever out is a `devbox.json` pin of
  that one package (`"<pkg>": {"version": "<x.y.z>"}`), dropped once nixpkgs moves on.
- **Don't double-manage Docker digests** — the built-in `dockerfile` manager already updates
  `FROM …@sha256`; a `customManagers` regex on the same line just produces "could not determine new
  digest" warnings. Removed.
- **GitHub Dependabot alerts**: OSV stays the vulnerability source, but the `Cannot access vulnerability
  alerts` WARN cannot be ignored — it is a *Repository Problem*, and Renovate ensures a Dependency
  Dashboard issue on every repo that has one, `dependencyDashboard: false` notwithstanding (10 open
  dashboards org-wide on 2026-09-27; agent-coordinator#1 deleted → #24 re-created within the hour).
  So the App declares `vulnerability_alerts: read` (`docs/github-apps.yaml`, the FU-098 flow: PR the
  declaration, click in the App settings + approve the install, `GithubAppPermissionDrift` clears).
  With the WARN gone and no pending branches, the dashboards stop being ensured — close them once.
