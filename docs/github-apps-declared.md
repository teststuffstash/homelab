# GitHub Apps — declared state

_GENERATED from [`github-apps.yaml`](github-apps.yaml) by `devbox run github-apps-md` — edit the yaml, never this file (the lint enforces sync). Change flow: PR the yaml → the `GithubAppPermissionDrift` alert rings → the operator clicks the grant → the alert clears. Live install matrix + drift verdicts: [`github-apps.md`](github-apps.md)._

## `homelab-agents`

Worker + coordinator git identity — homelab-agents[bot] is the PR author; mints the per-repo worker tokens (agent-git-<repo>, FU-089 central) and the coordinator/loop tokens.

_app_id `4150968` · install_id `142724430` · installs: **selected** · keys: Infisical AGENTS_GH_APP_PRIVATE_KEY, ~/.claude/homelab-github-agents/_

| Permission | Level | Why |
|---|---|---|
| `metadata` | read | baseline — every App needs it |
| `contents` | write | worker/coordinator clone+push (agent-git-<repo> gens, composition.yaml; agents/coordinator/git-token.yaml) |
| `pull_requests` | write | workers open PRs; coordinator merges (git-token.yaml) |
| `issues` | write | queue labels, strike/report comments, coordinator C6 (composition worker gens + git-token.yaml) |
| `checks` | read | coordinator `gh pr checks` (git-token.yaml + composition loop-git gens; fine-grained PATs cannot read Checks — App-only) |
| `statuses` | read | merge-path require_passed_checks reads (loop-git gens) |
| `actions` | read | coordinator `gh run watch`/rerun on agent repos (loop-git gens) |
| `workflows` | write | fleet#134 — track/chassis carve-out needs workers pushing .github/workflows/ci.yaml; DECLARED 2026-07-26 ahead of the grant (the drift alert rings until the operator clicks) |

## `homelab-reviewer`

The review bot's identity — homelab-reviewer[bot] submits approve/request-changes. Distinct App on purpose: GitHub blocks self-approval, so it must not be the PR author.

_app_id `4199252` · install_id `143941082` · installs: **selected** · keys: Infisical REVIEWER_GH_APP_PRIVATE_KEY, ~/.claude/homelab-github-reviewer/_

| Permission | Level | Why |
|---|---|---|
| `metadata` | read | baseline |
| `contents` | write | the approval must COUNT — GitHub only counts reviews from a repo writer (contents:read ⇒ authorAssociation NONE, ignored) |
| `pull_requests` | write | submit reviews |
| `checks` | read | reviewer reads CI state (composition loop-reviewer gens) |
| `statuses` | read | same |
| `actions` | read | reviewer reads run logs on private repos (loop-reviewer gens) |
| `code_quality` | read | OPERATOR RULING 2026-07-26: deliberate future-proof read — a reviewer probing a surface that 422s mid-review reads as 'something is there'; harmless reads are pre-granted so review probes fail honest-empty, not permission-denied |
| `discussions` | read | same ruling — deliberate future-proof reviewer read |
| `license_compliance_alerts` | read | operator future-proof-reads ruling 2026-07-26 (see code_quality) |
| `repository_advisories` | read | same ruling |
| `repo_secret_scanning_dismissal_requests` | read | same ruling |
| `security_events` | read | same ruling |
| `issues` | **absent (decided)** | reviewer never labels/comments issues — the coordinator lane owns that; keeps the reviewer's blast radius review-only |

## `homelab-merge`

The merge-serializer identity — update-pr-branch.yml's branch-update push. Dedicated App: its key sits in an org Actions secret readable by the semi-trusted CI plane, so minimal.

_app_id _unfilled_ · installs: **selected** · keys: org Actions secret via tofu/github/actions_secrets.tf, KeePass_

| Permission | Level | Why |
|---|---|---|
| `metadata` | read | baseline |
| `contents` | write | branch-update push |
| `pull_requests` | write | update-branch is a /pulls/ mutation — an App needs BOTH contents+PR write or it 403s |
| `checks` | read | require_passed_checks |
| `statuses` | read | require_passed_checks |
| `issues` | **absent (decided)** | the conflict-labeling step uses GITHUB_TOKEN instead — a leaked merge key must not grant issue writes |

## `homelab-renovate`

Self-hosted Renovate's identity (renovate.yaml) + devbox-update/runner-image lockfile fetches.

_app_id _unfilled_ · installs: **selected** · keys: org Actions secrets RENOVATE_APP_ID/RENOVATE_APP_PRIVATE_KEY, KeePass_

| Permission | Level | Why |
|---|---|---|
| `metadata` | read | baseline |
| `contents` | write | renovate branches; devbox-update.sh pushes; runner-image warm-store lockfile fetch (private repos) |
| `pull_requests` | write | renovate + devbox-update PRs; runner-image self-bump PR |
| `issues` | write | the Dependency Dashboard issue |
| `workflows` | write | renovate bumps pinned action refs under .github/workflows/ |
| `vulnerability_alerts` | **absent (decided)** | DECIDED — vulnerability data comes from Renovate's OSV alerts, not GitHub Dependabot (docs/renovate.md §OSV: 'we use OSV instead and ignore that warning'; self-host ethos, no repo Dependency-graph settings needed) |

## `homelab-labels`

Label-sync identity (agent label set across repos).

_app_id _unfilled_ · installs: **all** · keys: KeePass_

| Permission | Level | Why |
|---|---|---|
| `metadata` | read | baseline |
| `issues` | write | create/update labels (labels ride the Issues permission) |

## `homelab-deploy`

Deploy-pin bump PRs into deploy-target repos (FU-051; homelab, sleep-iac, oracle-iac).

_app_id _unfilled_ · installs: **selected** · keys: org Actions secrets DEPLOY_APP_*, KeePass_

| Permission | Level | Why |
|---|---|---|
| `metadata` | read | baseline |
| `contents` | write | push the bump branch |
| `pull_requests` | write | open + auto-merge the bump PR |

## `homelab-arc`

Actions Runner Controller registers the org homelab-ephemeral scale set.

_app_id _unfilled_ · install_id `142353606` · installs: **all** · keys: in-cluster arc-github-app Secret, KeePass_

| Permission | Level | Why |
|---|---|---|
| `org:self_hosted_runners` | write | runner registration |
| `metadata` | read | baseline |

## `homelab-runner-registrar`

The Proxmox CI-runner VM mints its own registration tokens at boot (ADR-082).

_app_id `4141567` · install_id `142515626` · installs: **selected** · keys: ci-runner VM cloud-init (/etc/runner-app/private-key.pem), KeePass_

| Permission | Level | Why |
|---|---|---|
| `org:self_hosted_runners` | write | runner registration |
| `metadata` | read | baseline |

> FU-017: merge into homelab-arc — identical grants
