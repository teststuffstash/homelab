# Renovate — dependency updates + supply-chain hardening (the S2C2F consumer leg)

Self-hosted Renovate keeps our dependencies current **and** is our first line of defence for the
things we *ingest* — the consumer side of the supply chain ([`slsa.md`](slsa.md) names this **S2C2F**
but hadn't built it — since built). The LIVE status is FU-125 — Renovate regressed to zero
delivered PRs, see [`dependency-upgrades.md`](dependency-upgrades.md) §Ground truth.

## Shape

```
homelab/.github/workflows/renovate.yaml   scheduled runner on the ARC tier, runs as the homelab-renovate
   │  (autodiscover; RENOVATE_CONFIG_FILE = the global baseline)   App → walks the repos it's installed on
   ▼
homelab/.github/renovate-global.json      the SUPPLY-CHAIN BASELINE enforced on EVERY repo (below)
   ▼
<repo>/renovate.json                      per-repo automerge preferences only, on top of the baseline
   ▼
reviewer-approve reflex (per repo)        homelab-reviewer bot approves `automerge`-labelled PRs →
                                          satisfies required-approval → GitHub merges on CI-green
                                          (idempotent since 2026-08-11: per-PR concurrency group +
                                          fail-closed APPROVED-at-head dup check — homelab#114)
```

"Add a repo to Renovate" = install the `homelab-renovate` App on it (autodiscover does the rest).
Bootstrap: `scripts/github-app-bootstrap.sh homelab-renovate`.

⚠ As of 2026-08-01 this path delivers ZERO PRs org-wide while reporting success — FU-125; verify
against [`dependency-upgrades.md`](dependency-upgrades.md) §Ground truth before trusting it.

## Threat model — mitigate a Trivy-style compromise

The Trivy compromise (March 2026): attackers hijacked the repo to publish **backdoored binaries**
(v0.69.4+) and **re-pointed 76/77 action tags** (`aquasecurity/trivy-action` `0.0.1…0.34.2`) to a
credential-stealing payload. A naive "always take the latest tag" pipeline would have ingested it
immediately. Our baseline blunts both vectors:

| Mitigation (`renovate-global.json`) | What it stops | Idea from |
|---|---|---|
| **Cooldown** — `minimumReleaseAge: "7 days"` | Adopting a freshly-compromised version inside the detection window (Trivy was caught in days). Non-security only. | pnpm `minimumReleaseAge` |
| **SHA-pin Actions** — `helpers:pinGitHubActionDigests` | **Tag re-pointing** — a hijacked `@v4` can't inject if we're on the immutable commit SHA. Renovate keeps the SHA current (+ the tag in a comment). | SLSA / pinning |
| **OSV alerts** — `osvVulnerabilityAlerts` | Known-vulnerable deps; raises fix PRs from OSV (no GitHub Dependabot dependency — self-host ethos). **Security fixes bypass the cooldown** (get them in fast, CI still gates). | SLSA S2C2F |

Not yet built (the strongest, aspirational leg): **verify SLSA provenance / signatures** on consumed
artifacts (`cosign verify-attestation`) so a backdoored artifact is rejected even *inside* the cooldown.
Needs the upstream to publish verifiable provenance + a verify step in CI — [`slsa.md`](slsa.md) Phase-later.

## The automerge vs review split — "is there anything a human can actually review?"

- **Digest bumps automerge** (base-image `@sha256`, SHA-pinned Actions). A human comparing two hashes
  is security theatre; the real gates are the **cooldown + CI + the reviewer reflex**, not eyeballs.
- **Reviewable bumps go to the LLM reviewer, not a human** — runtime dep *version* bumps (changelogs
  exist; they run in prod), major base-image changes. These carry `deps-review`, arm
  auto-merge, and flow through the **merge-path review reflex** (FU-046): the reviewer approves the
  harmless ones (→ auto-merge) and requests changes on the rest (→ a worker adapts the code). No human.
- **GitHub Actions MAJORS merge on their own (ADR-141, S9 homelab#1985).** Blast class decides the lane,
  semver decides the lens: an Actions major carries `major` (the reviewer runs the migration lens —
  upstream notes, known issues, runner compatibility — as the merge gate) and is ARMED (the
  CI-exercised class: a `pull_request` workflow runs the PR's own file, so green CI on the bumped head
  is the proof). Push-only workflows (`build-image`, deploy jobs) are covered after the merge by the
  FU-1990 revert chain: `GithubWorkflowRunFailed` on master → `workflow-pin-revert` reverts the pin PR
  as an `automerge`+`dependencies` PR the reflex approves (PR#2002) → the re-proposed version is
  refused by `pin-only-lint` check (e) in `ci` (the revert body's `reverted-pins:` line, 30 days), so it
  stays red until Renovate proposes a newer release. Bumps are grouped per repo per wave (one PR, one
  review, one revert) and rebase themselves. Every other major stays un-armed on the human lane until
  its class row is complete (#1988).
- **Security fixes** (OSV) fast-track: no cooldown, `automerge`, auto-approved, auto-merged.

Each merge that touches a deploy path (`uv.lock`, `Dockerfile`, …) flows through the automated deploy
(ADR-084), so a hands-off dep bump reaches prod on its own.

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

The coordinator loop runs in-cluster, unsuspended since 2026-07-28 (`reflexes-argo.yaml`), but the
changes-requested→worker transition isn't built yet, so a reviewer-rejected Renovate PR simply **parks** — open, changes-requested,
auto-merge hard-blocked. Safe: no duplication, no churn, nothing auto-acts on it.

## Gotchas encountered

- **`pinGitHubActionDigests` pins our OWN reusable workflows too** — the first live run
  (2026-09-25) SHA-pinned every `teststuffstash/homelab/.github/workflows/*.reusable.yml@master`
  caller, freezing it at one homelab commit (and queueing a digest PR per master move). First-party
  `teststuffstash/**` refs are excluded in the global config; `@master` is the contract.
- **`@latest` devbox/nix pins are un-trackable** → Renovate mis-resolves them (it once proposed
  downgrading gitleaks to a dead 5-yr-old release). The `nix`/`devbox` manager is **disabled**; devbox
  updates are owned instead by the weekly **`devbox-update`** job (`scripts/devbox-update.sh` /
  `.github/workflows/devbox-update.yaml`), which keeps `@latest` but
  re-resolves *all* repos' locks in one pass so the shared toolchain aligns (nix cache + agent-base bake
  hits) — alignment a per-repo Renovate bump can't give.
- **Don't double-manage Docker digests** — the built-in `dockerfile` manager already updates
  `FROM …@sha256`; a `customManagers` regex on the same line just produces "could not determine new
  digest" warnings. Removed.
- **GitHub Dependabot alerts** need an App permission + repo Dependency-graph/Dependabot settings; we
  use **OSV instead** and ignore that warning. (Grant `vulnerability_alerts:read` to the App only if you
  specifically want GitHub's alert source too.)
