# Renovate — dependency updates + supply-chain hardening (the S2C2F consumer leg)

Self-hosted Renovate keeps our dependencies current **and** is our first line of defence for the
things we *ingest* — the consumer side of the supply chain, which [`slsa.md`](slsa.md) names
**S2C2F**. It has opened, gated and merged PRs on every lane since 2026-09-27 (ADR-141; the remaining
lane work is homelab#1985, open).

This doc owns how Renovate runs, the supply-chain baseline, and the rules for handling a Renovate
PR. It does **not** own:

- which dependency class rides which lane, and what is still moved by hand —
  [`dependency-classes.yaml`](dependency-classes.yaml), rendered in
  [`dependency-upgrades.md`](dependency-upgrades.md) §The dependency inventory;
- which lane has actually merged end to end — [`dependency-upgrades.md`](dependency-upgrades.md)
  §"Last proven end to end". A lane is trusted only once that table carries a merge for it.

**Liveness is the `github_renovate_last_pr_timestamp` gauge → `RenovateSilent`** (no new
`renovate/*` PR anywhere in the org for 14 days), never the workflow's own verdict: the workflow
stayed green through a stretch in which Renovate opened nothing
([`dependency-upgrades.md`](dependency-upgrades.md) §Ground truth).

## Shape

| Piece | What it does |
|---|---|
| `.github/workflows/renovate.yaml` | A GitHub Actions workflow on the ARC runner tier (`homelab-ephemeral`), every 6 hours (`0 */6 * * *`) or by `workflow_dispatch` (with a `dryRun` input). It mints a token for the `homelab-renovate` App and runs the pinned `renovatebot/github-action` with `RENOVATE_AUTODISCOVER`, so it walks every repo the App is installed on. Not the Mend hosted App. |
| `.github/renovate-global.json` | The global config (`RENOVATE_CONFIG_FILE`): the supply-chain baseline **and** the lane classification, applied to every repo. `onboarding: false` + `requireConfig: optional` — a repo needs no config of its own to be classified. It also holds homelab's own extraction (the `argocd` / `kubernetes` file patterns, the `customManagers`); homelab has no `renovate.json`. |
| `<repo>/renovate.json` (optional) | A stack's extraction coverage and automerge preferences (§Scope). |
| `renovate-approve` (per repo) | The 3-line caller of `renovate-approve.reusable.yml`: the `homelab-reviewer` App approves a bot PR labelled `automerge` + `dependencies` and not `major`, once per head. That satisfies the required approval on repos that have one, and GitHub auto-merge lands the PR on green CI. |
| the review reflex + the coordinator | Everything that is not mechanical: `deps-review` and `major` PRs ([`agents/merge-path.md`](agents/merge-path.md); §Coordinator × Renovate PRs). |

PR pacing is `prHourlyLimit: 3` per repo per run, so a backlog drains over days instead of landing
as one wave on the reviewer and the shared App rate-limit pool (FU-290). The workflow rings no
coordinator doorbell for the same reason; the per-stack `coordinate-<stack>` crons pick the PRs up
on their own schedule.

The `homelab-renovate` App identity also opens the weekly `devbox-update` PRs and the deploy-pin
PRs (`deploy/*` branches), so a PR's author does not say "Renovate proposed this" — the
`renovate/*` branch does.

### Scope

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
- A lane hole a stack finds is a baseline bug — report it to homelab (homelab#1988's no-lane class;
  `devbox run renovate-lane-lint` is the check).

"Add a repo to Renovate" = install the `homelab-renovate` App on it (autodiscover does the rest).
Which repos Renovate has opened a PR on is the gauge's `repo` label. The App's permissions are
declared in [`github-apps.yaml`](github-apps.yaml); bootstrap is
`scripts/github-app-bootstrap.sh homelab-renovate`.

## Threat model — mitigate a Trivy-style compromise

The Trivy compromise (March 2026): attackers hijacked the repo to publish **backdoored binaries**
(v0.69.4+) and **re-pointed 76/77 action tags** (`aquasecurity/trivy-action` `0.0.1…0.34.2`) to a
credential-stealing payload. A naive "always take the latest tag" pipeline would have ingested it
immediately. Our baseline blunts both vectors:

| Mitigation (`renovate-global.json`) | What it stops | Idea from |
|---|---|---|
| **Cooldown** — `minimumReleaseAge: "7 days"` | Adopting a freshly-compromised version inside the detection window (Trivy was caught in days). Non-security only. Timestamp-optional for pins, digests and the Docker datasource (their releases carry no timestamp), and off for the crossplane chart (its index re-stamps every entry) — CI and the revert are the gate there. | pnpm `minimumReleaseAge` |
| **SHA-pin Actions** — `helpers:pinGitHubActionDigests` | **Tag re-pointing** — a hijacked `@v4` can't inject if we're on the immutable commit SHA. Renovate keeps the SHA current (+ the tag in a comment). | SLSA / pinning |
| **OSV alerts** — `osvVulnerabilityAlerts` | Known-vulnerable **direct** deps already on the base branch; raises fix PRs from OSV (no GitHub Dependabot dependency — self-host ethos). **Security fixes bypass the cooldown** (get them in fast, CI still gates). It never sees a TRANSITIVE dependency, nor what a PR brings in — that is the next row. | SLSA S2C2F |
| **Lockfile intake** — `lock-intake-lint` in `ci` ([ADR-143](adr.md)) | What a PR's lockfile change brings in, transitive included: fails an OSV-flagged (incl. `MAL-`), <7-day-old or install-script-bearing version. Static — reads lockfiles + registry metadata, runs nothing — so it decides before any step executes dependency code. Covers `deno.lock`, `package-lock.json` and `uv.lock`; any other lockfile type fails closed until it has an extractor. | the #2032 lodash-es miss |

Not built: **verifying SLSA provenance / signatures** on consumed artifacts
(`cosign verify-attestation`), which would reject a backdoored artifact even *inside* the cooldown.
It needs the upstream to publish verifiable provenance plus a verify step in CI; the plan is
[`slsa.md`](slsa.md)'s, as a later phase.

## The automerge vs review split — "is there anything a human can actually review?"

The principles, which every lane applies; **the per-class rulings themselves live in ONE place,
[`dependency-classes.yaml`](dependency-classes.yaml) (rendered as the register in
[`dependency-upgrades.md`](dependency-upgrades.md) §The dependency inventory) — this doc does not
restate them, and a lane question is answered there, cell by cell.**

- **Digest bumps are mechanical** (`@sha256`, SHA-pinned Actions): a human comparing two hashes is
  theatre; the gates are the cooldown, CI on the head and the reviewer reflex (`automerge` label →
  `renovate-approve` approval → CI-green auto-merge).
- **Reviewable bumps go to the LLM reviewer, not a human** (`deps-review`, armed): the merge-path
  review reflex + the migration lens read the changelog; APPROVED merges, CHANGES_REQUESTED or a
  red head brings a worker to adapt the code on the Renovate branch (§Coordinator × Renovate PRs).
- **Majors are un-armed by default and ARM per class on evidence** (ADR-141): an armed class keeps
  the `major` label and gets no `automerge` label, so `renovate-approve` refuses it and the lens's
  APPROVED completes the merge — behind that class's own detector + revert pair (the register's
  columns). An un-armed major is the coordinator's and ends on a human
  ([`agents/coordinator/README.md`](../agents/coordinator/README.md) §Dependency major bumps).
  GitHub Actions majors ride the mechanical lane, grouped; one graduates to its own ungrouped
  `major` PR the first time a revert names it, its PR goes red, or a review asks for an adaptation.
  A chart major arms itself when it is packaging-only (`appVersion: unchanged`,
  `agents/major-handoff.sh`). The marker must not leak: Renovate MERGES `addLabels` across rules,
  so every mechanical rule is restricted to non-major update types.
- **The [management box](management-box.md) is the gate where a merge is an apply** (tofu
  providers, tofu-managed charts): the sentinel's plan-on-PR must be empty or a default backfill
  (ADR-131); the lens is the merge gate for majors; the box's bracket is the deploy edge, forward
  only.
- **Security fixes** (OSV) fast-track: no cooldown, labels `security` + `automerge`, auto-approved,
  auto-merged. One that is also a major keeps `major` and rides the major lane.

Each merge that touches a deploy path (`uv.lock`, `Dockerfile`, …) flows through the automated
deploy (ADR-084), so a hands-off dep bump reaches prod on its own.

## Coordinator × Renovate PRs — "close" is NOT a terminal action

A Renovate PR is **not** an agent PR, so the coordinator's usual escalation verbs differ — Renovate,
not the coordinator, owns whether an update should exist. The coordinator's own procedure is
[`agents/coordinator/README.md`](../agents/coordinator/README.md) §Dependency major bumps; the
rules that follow from how Renovate behaves:

- **A stuck PR gets a worker on the Renovate branch, not a close.** The review reflex reads green
  heads only, so the scan's `unarmed-major` unit owns the rest: an un-armed `major` in any state,
  an armed `deps-review` PR that is red or changes-requested, and an armed `automerge` PR that is
  red at a settled head (gap G12b) or has sat untouched for a day (ADR-162). The bound is five
  rides, then `agent/arbitrate` for a human. Never close a `deps-review` PR; a hopeless mechanical
  one is closed with an issue naming the failing step, because the bump comes back on Renovate's
  next run and the issue is the record. **Not on the GitHub Actions lane** (ADR-141): those PRs
  are grouped per repo per wave, and the reviewer reads one as a batch member with no fixer behind
  it.
- **Renovate owns its PRs' currency, conflicts and autoclose (ADR-153).**
  `rebaseWhen: behind-base-branch` is the org default: Renovate keeps every UNTOUCHED PR current,
  re-extracts master on each rebase (a call site added after the PR opened is bumped on the next
  rebase), rebases on conflict and autocloses a superseded PR — and it stops maintaining a branch
  the moment anyone else pushes to it (its edited-PR rule: one foreign commit makes the PR
  "Edited/Blocked", neither rebased nor autoclosed). So:
  - The in-cluster updater keeps its hands off an untouched Renovate PR, with ONE exception: a
    merge-ready one (armed + approved + green, currency the only gap) it updates, so the fast path
    keeps the updater's 15-minute currency instead of Renovate's 6-hour run.
  - **When that update misses** — master moves again before the merge, or the update pulls a red
    in — the branch carries the updater's merge commit, so the updater **hands it back**: it
    ticks Renovate's rebase/retry checkbox and Renovate's next run rebuilds the branch as its own
    (`agents/renovate-currency.sh` `renovate_handback`, one predicate shared by the updater and
    the scan). The hand-back reaches every armed Renovate PR, behind or not: a merged-into PR
    whose CI has concluded red, or a red codeowner park, is handed back without waiting for master
    to move; in-flight or absent checks wait.
  - An untouched PR with a merge conflict gets the same checkbox tick from the scan — never
    `update-branch`.
  - **A worker-adapted branch is never handed back** — Renovate's rebuild would drop the worker's
    commit. It moves by merging master into it.
- **Closing a Renovate PR is not "done."** With Renovate's default `recreateWhen: auto`, a manually
  closed PR is *not* recreated for the **same** version (close = "reject this version"), but Renovate
  DOES open a fresh PR when a **newer** version lands → a reject→close→new-version→reject **churn**; and
  **vulnerability PRs are recreated even when closed**. So a bare close never durably abandons an upgrade.
- **To abandon an upgrade durably, change the Renovate CONFIG, not the PR:** `ignoreDeps`, a
  `matchPackageNames … "enabled": false` rule, or an `allowedVersions`/`matchCurrentVersion` pin. That is
  the coordinator's (or human's) "don't do this bump" verb for Renovate PRs.

## devbox — the weekly `devbox-update` job

**`@latest` devbox/nix pins are un-trackable**, so Renovate mis-resolves them (it once proposed
downgrading gitleaks to a dead 5-year-old release). The `nix`/`devbox` managers are **disabled**;
devbox updates are owned by the weekly **`devbox-update`** job (`scripts/devbox-update.sh` /
`.github/workflows/devbox-update.yaml`, Mondays 03:00 UTC), which keeps `@latest` but re-resolves
*all* matrix repos' locks in one pass so the shared toolchain aligns (nix cache + agent-base bake
hits) — alignment a per-repo Renovate bump can't give. The devbox binary's own version is a
separate pin, and moving it in step everywhere is FU-240.

- **Non-major lock moves are armed and mechanical.** The PR body carries a second section —
  same-major downgrades + compatibility-line moves of python3/opentofu/kubectl/openssl — that the
  migration lens answers line by line; it informs, never un-arms (gap G17).
- **A lock MAJOR is armed too** (`major` kept, the lens's APPROVED completes the merge). The one
  exception is an opentofu major, which stays un-armed for a human: no lock revert can undo a
  state-format change.
- **A reverted lock version is refused for 30 days** by `pin-only-lint` check (i), which holds the
  WHOLE weekly PR red. The lever out is a `devbox.json` pin of that one package
  (`"<pkg>": {"version": "<x.y.z>"}`), dropped once nixpkgs moves on.
- **Files generated from a pinned tool's output** (today: the replay `gh-json-fields` allowlist)
  are re-rendered from the new lock on the same PR, so a tool bump does not red its own weekly PR.
- **A locked build must be downloadable** (`scripts/lock-cache-check.sh`): devbox installs a
  locked store path from the binary cache and BUILDS it from source when no substituter has it, so
  one uncached package turns every CI warm step into a compile that the runner's memory limit
  kills. The weekly job puts such a package back to its previous lock entry (named in its own PR
  body section; it retries next week), and `ci`'s first step runs the same check before the first
  `devbox run`, so a lock from any other source reds in seconds with the package named. The remedy
  is always the lock entry, never the runner's limit.

## Gotchas

- **Validate the LANES, not just the syntax: `devbox run renovate-lane-lint`** before landing a change
  to `renovate-global.json`. Renovate arms a grouped branch only when EVERY member has
  `automerge: true` while labels are the UNION — a rule gap on one member produces a lane-labelled,
  un-armed PR nobody reads (gap G15). The verb runs Renovate itself
  (`--platform=local --dry-run=lookup`, trace log) over the checkout and asserts one lane per branch;
  ~2 min of datasource lookups over the WAN, so it is a seat verb, not a CI step (CI's WAN egress
  stays locked down). `--self-test` replays the fixture; `--trace FILE` re-asserts a saved run.
- **`postUpgradeTasks` run in the SLIM image, with no shell.** The pinned `renovatebot/github-action`
  runs `ghcr.io/renovatebot/renovate:<version>` — containerbase + `jq`, no helm/yq/python — and executes
  each command via execa (no `&&`, no pipes unless `allowShellExecutorForPostUpgradeCommands`, which we
  do not set). So:
  - tools come from a runtime `install-tool <tool> <ver>` command, called by the script itself (a
    no-op for the seat, where `install-tool` is absent);
  - every command string must match the global `allowedCommands` exactly (compiled as a Handlebars
    template first);
  - `fileFilters` is the ONLY way a generated file reaches the commit (never `git add`);
  - a tool version the script needs lives in the script (`HELM_VERSION=v<x.y.z>`, proposed by a
    `customManager` over that line), never in `renovate-global.json`: `/.github/` is
    codeowner-gated, so a pin there parks every patch on a human;
  - a dry run (`workflow_dispatch` → `dryRun`) still executes the commands and logs
    `DRY-RUN: Would commit files`, but only when a branch is (re)built — an up-to-date branch runs
    nothing.

  The three consumers: `scripts/upstream-alerts-refresh.sh` (the kube-prometheus-stack rule
  re-renders the upstream alert list on its branch), `scripts/vendor-kyverno-policies.sh`
  (re-fetches `policy/component/` on a `KYVERNO_POLICIES_SHA` bump) and
  `scripts/vendor-garage-chart.sh` (rebuilds `argocd/charts/garage` with its local patches on a
  `GARAGE_CHART_TAG` bump). All are bash/curl/sed/awk (the last also git + tar) only, for exactly
  this container.
- **`pinGitHubActionDigests` pins our OWN reusable workflows too**, which would freeze every
  `teststuffstash/homelab/.github/workflows/*.reusable.yml@master` caller at one homelab commit and
  queue a digest PR per master move. First-party `teststuffstash/**` refs are excluded in the
  global config; `@master` is the contract.
- **Don't double-manage Docker digests** — the built-in `dockerfile` manager already updates
  `FROM …@sha256`; a `customManagers` regex on the same line just produces "could not determine new
  digest" warnings.
- **The Dependency Dashboard is off, and two things keep it off.** `dependencyDashboard: false`
  alone does not: `config:recommended` re-enables it at repo level, and any *Repository Problem*
  makes Renovate ensure a dashboard issue regardless. So the global config sets it under `force`,
  and the App declares `vulnerability_alerts: read` ([`github-apps.yaml`](github-apps.yaml)) —
  OSV stays the vulnerability source, the grant only removes the `Cannot access vulnerability
  alerts` warning that counts as a Repository Problem. No dashboard issue is open in the org
  (2026-11-12).
