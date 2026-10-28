# The org's security contact surface (2026-10-28): ONE disclosure policy, published as the org-default
# community-health file, plus GitHub private vulnerability reporting (PVR) on every public repo.
#
# files/SECURITY.md is the policy's only home — security.txt `Policy:` and the minutark.ee security
# page LINK to the published copy (github.com/teststuffstash/.github/blob/HEAD/SECURITY.md), never
# restate it. A repo-level SECURITY.md would override the org default; none exists (checked
# 2026-10-28), keep it that way.

# `.github` = GitHub's special repo whose community-health files are the default for every repo in
# the org that lacks its own. Must be PUBLIC for the defaults to apply. Created here (no import).
resource "github_repository" "dot_github" {
  name        = ".github"
  description = "Org-wide defaults for teststuffstash — the security policy (SECURITY.md), managed from homelab tofu/github"
  visibility  = "public"
  auto_init   = true # an initial commit, so the default branch exists for github_repository_file

  has_issues      = false # vulnerabilities never go to public issues — the policy says so
  has_projects    = false
  has_wiki        = false
  has_discussions = false
  is_template     = false

  allow_merge_commit          = true
  allow_squash_merge          = true
  allow_rebase_merge          = true
  allow_auto_merge            = false # no PR lane — content is written by this root
  allow_update_branch         = false
  allow_forking               = true # PUBLIC repos are always forkable — GitHub ignores false
  delete_branch_on_merge      = true
  web_commit_signoff_required = false

  merge_commit_title          = "MERGE_MESSAGE"
  merge_commit_message        = "PR_TITLE"
  squash_merge_commit_title   = "COMMIT_OR_PR_TITLE"
  squash_merge_commit_message = "COMMIT_MESSAGES"

  archive_on_destroy = true

  security_and_analysis {
    secret_scanning { status = "disabled" }
    secret_scanning_push_protection { status = "disabled" }
  }

  lifecycle {
    # has_downloads: deprecated no-op attribute (see the header of repos.tf).
    ignore_changes = [has_downloads]
  }
}

# The commit lands straight on the default branch: the org PR ruleset covers this repo too, and the
# org-admin token this root runs with is its bypass actor (org_ruleset.tf). Needs Contents:R/W on the
# token (README.md §Run it).
resource "github_repository_file" "security_policy" {
  repository          = github_repository.dot_github.name
  file                = "SECURITY.md"
  content             = file("${path.module}/files/SECURITY.md")
  commit_message      = "SECURITY.md: org disclosure policy (managed by homelab tofu/github)"
  overwrite_on_create = true
}

# PVR is NOT here: the provider has no resource for it (integrations/terraform-provider-github#2399)
# and a provisioner is refused by the management sentinel (policy/mgmt/plan-input.yaml deny_patterns).
# scripts/github-tf.sh reconciles it after every successful `apply` instead (one idempotent API PUT
# per public repo in the org).
