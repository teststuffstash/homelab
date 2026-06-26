# Org-wide STRUCTURAL protection on every repo's default branch: require a PR before merging, block
# force-pushes and default-branch deletion. No required status checks here — those are per-repo
# (repo_rulesets.tf), since a repo without a given workflow can never satisfy an org-wide check.
#
# ~DEFAULT_BRANCH / ~ALL target each repo's default branch across all repos regardless of master/main.
resource "github_organization_ruleset" "default_branch" {
  name        = "default-branch-protection"
  target      = "branch"
  enforcement = var.enforcement

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
    repository_name {
      include = ["~ALL"]
      exclude = []
    }
  }

  # Org admins (you) keep direct-to-master for IaC; the agents App is deliberately NOT listed, so its
  # contents:write still can't reach a default branch — belt (token scope) & suspenders (this rule).
  # actor_id 1 = the organization-admin role. Verify in the ruleset Insights while in `evaluate`.
  bypass_actors {
    actor_id    = 1
    actor_type  = "OrganizationAdmin"
    bypass_mode = "always"
  }

  rules {
    deletion         = true # block default-branch deletion
    non_fast_forward = true # block force-push

    pull_request {
      required_approving_review_count   = 0 # PR required; mandatory approvals are a per-repo choice
      require_last_push_approval        = false
      dismiss_stale_reviews_on_push     = false
      required_review_thread_resolution = false
    }
  }
}
