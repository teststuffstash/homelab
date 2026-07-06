# Org-level GitHub Actions secrets — the ONLY workflow-visible secrets the platform needs. Managed here
# so "how is the org configured" stays answered by this root (like the rulesets/repos/labels), and drift
# is detected. Consumed by the FU-041 updater workflow (`update-pr-branch.yml` in each agent repo), which
# mints a homelab-merge App token so its branch-update push RE-TRIGGERS CI — a bare GITHUB_TOKEN push would
# not, and a strict branch would never go green. See docs/agents/merge-path.md + docs/github-setup.md §4.
#
# DEDICATED App (homelab-merge), NOT homelab-agents: reusing agents would copy its broad key (issues:write,
# multi-repo, the coordinator identity) into a GitHub org Actions secret readable by the CI plane — which
# runs semi-trusted agent-authored code. homelab-merge is minimal (contents:write + read-only PR/checks),
# so a leaked org secret only grants branch-updates. Bootstrap: scripts/github-merge-app-bootstrap.sh.
#
# ⚠ SECRETS-IN-STATE: the github provider stores the secret `value` in state (encrypted only in transit to
# GitHub). This root's state is LOCAL + gitignored and already run outside the jail with an admin token, so
# the merge App key here is the same posture as that admin token — but it IS a second at-rest copy of a
# Tier secret whose durable source stays Infisical (`MERGE_GH_APP_PRIVATE_KEY`). The ID is not sensitive.
#
# Both vars are injected by scripts/github-tf.sh (from the cred dir), so the one command is:
#   devbox run github-tofu apply       # OUTSIDE the jail — loads org admin token + merge id/key, runs tofu

resource "github_actions_organization_secret" "merge_gh_app_id" {
  secret_name = "MERGE_GH_APP_ID"
  visibility  = "all" # every agent repo's workflow reads it
  value       = var.merge_gh_app_id
}

resource "github_actions_organization_secret" "merge_gh_app_private_key" {
  secret_name = "MERGE_GH_APP_PRIVATE_KEY"
  visibility  = "all"
  value       = var.merge_gh_app_private_key
}

# homelab-deploy App creds → the sleep-tracking `deploy` workflow (deploy.yaml) mints a sleep-iac-scoped
# token to open the version-bump PR (FU-025, docs/sleep-iac.md §"Deploy pipeline"). Bootstrap:
# scripts/github-deploy-app-bootstrap.sh; `count` skips these until the App exists (deploy_app_id set),
# so the github root applies cleanly before then.
#
# ⚠ visibility = SELECTED (sleep-tracking only), NOT "all" like the merge secrets: this key grants
# contents+PR write on sleep-iac ⇒ it can deploy anything, so it must not be readable by every repo's CI
# plane (which runs semi-trusted agent-authored code). Only the deploy workflow needs it.
# The secret + its repo allow-list are split: the inline `selected_repository_ids` on the secret is
# deprecated, so the allow-list lives in the companion `_repositories` resource below.
resource "github_actions_organization_secret" "deploy_app_id" {
  count       = var.deploy_app_id != "" ? 1 : 0
  secret_name = "DEPLOY_APP_ID"
  visibility  = "selected"
  value       = var.deploy_app_id
}

resource "github_actions_organization_secret" "deploy_app_private_key" {
  count       = var.deploy_app_private_key != "" ? 1 : 0
  secret_name = "DEPLOY_APP_PRIVATE_KEY"
  visibility  = "selected"
  value       = var.deploy_app_private_key
}

# Which repos' build/deploy mints a deploy-App token to open a bump PR: sleep-tracking (→ sleep-iac),
# openrouter-operator + agent-runtime + agent-coordinator (→ homelab: chart pin / agents/images.env).
# Keep TIGHT — the key can deploy (contents+PR write on homelab / sleep-iac), so only repos that open a
# deploy PR read it (not every CI plane).
# Only sleep-tracking/snore-recorder/sleep-iac are managed github_repository RESOURCES; the rest are read
# via data sources — we just need the repo_id to scope a secret (no need to adopt the repo into tofu).
data "github_repository" "openrouter_operator" { full_name = "${var.org}/openrouter-operator" }
data "github_repository" "agent_runtime" { full_name = "${var.org}/agent-runtime" }
data "github_repository" "agent_coordinator" { full_name = "${var.org}/agent-coordinator" }

locals {
  deploy_repos = [
    github_repository.sleep_tracking.repo_id,
    data.github_repository.openrouter_operator.repo_id,
    data.github_repository.agent_runtime.repo_id,
    data.github_repository.agent_coordinator.repo_id,
  ]
}

resource "github_actions_organization_secret_repositories" "deploy_app_id" {
  count                   = var.deploy_app_id != "" ? 1 : 0
  secret_name             = github_actions_organization_secret.deploy_app_id[0].secret_name
  selected_repository_ids = local.deploy_repos
}

resource "github_actions_organization_secret_repositories" "deploy_app_private_key" {
  count                   = var.deploy_app_private_key != "" ? 1 : 0
  secret_name             = github_actions_organization_secret.deploy_app_private_key[0].secret_name
  selected_repository_ids = local.deploy_repos
}

# homelab isn't managed as a github_repository here (only the app/stack repos are) — read its id so we
# can scope the RENOVATE_APP_* secrets to the repo that runs the Renovate workflow.
data "github_repository" "homelab" {
  full_name = "${var.org}/homelab"
}

# homelab-renovate App creds → the self-hosted Renovate runner (homelab .github/workflows/renovate.yaml)
# mints a token to open dependency PRs (FU-014). Scoped to the HOMELAB repo only — the key grants
# contents+PR+issues+workflows write on the repos Renovate manages, so it must not be readable elsewhere.
resource "github_actions_organization_secret" "renovate_app_id" {
  count       = var.renovate_app_id != "" ? 1 : 0
  secret_name = "RENOVATE_APP_ID"
  visibility  = "selected"
  value       = var.renovate_app_id
}

resource "github_actions_organization_secret" "renovate_app_private_key" {
  count       = var.renovate_app_private_key != "" ? 1 : 0
  secret_name = "RENOVATE_APP_PRIVATE_KEY"
  visibility  = "selected"
  value       = var.renovate_app_private_key
}

resource "github_actions_organization_secret_repositories" "renovate_app_id" {
  count                   = var.renovate_app_id != "" ? 1 : 0
  secret_name             = github_actions_organization_secret.renovate_app_id[0].secret_name
  selected_repository_ids = [data.github_repository.homelab.repo_id]
}

resource "github_actions_organization_secret_repositories" "renovate_app_private_key" {
  count                   = var.renovate_app_private_key != "" ? 1 : 0
  secret_name             = github_actions_organization_secret.renovate_app_private_key[0].secret_name
  selected_repository_ids = [data.github_repository.homelab.repo_id]
}

# homelab-reviewer App creds → the reviewer-approves-Renovate reflex (sleep-tracking
# renovate-approve.yaml) posts an approving review on Renovate's automerge PRs, satisfying
# required-approval so auto-merge completes. Scoped to sleep-tracking only.
resource "github_actions_organization_secret" "reviewer_app_id" {
  count       = var.reviewer_app_id != "" ? 1 : 0
  secret_name = "REVIEWER_APP_ID"
  visibility  = "selected"
  value       = var.reviewer_app_id
}

resource "github_actions_organization_secret" "reviewer_app_private_key" {
  count       = var.reviewer_app_private_key != "" ? 1 : 0
  secret_name = "REVIEWER_APP_PRIVATE_KEY"
  visibility  = "selected"
  value       = var.reviewer_app_private_key
}

# The renovate-approve reflex runs on every repo that requires an approving review (require_approval=true
# in var.protected_repos) — the reviewer bot's approval is what lets a Renovate automerge PR complete
# there. sleep-iac/homelab opt out (CI-only), so they're excluded.
locals {
  reviewer_repos = [
    github_repository.sleep_tracking.repo_id,
    github_repository.snore_recorder.repo_id,
    data.github_repository.openrouter_operator.repo_id,
    data.github_repository.agent_runtime.repo_id,
    data.github_repository.agent_coordinator.repo_id,
  ]
}

resource "github_actions_organization_secret_repositories" "reviewer_app_id" {
  count                   = var.reviewer_app_id != "" ? 1 : 0
  secret_name             = github_actions_organization_secret.reviewer_app_id[0].secret_name
  selected_repository_ids = local.reviewer_repos
}

resource "github_actions_organization_secret_repositories" "reviewer_app_private_key" {
  count                   = var.reviewer_app_private_key != "" ? 1 : 0
  secret_name             = github_actions_organization_secret.reviewer_app_private_key[0].secret_name
  selected_repository_ids = local.reviewer_repos
}
