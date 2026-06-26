# Per-repo REQUIRED STATUS CHECKS layered on top of the org structural ruleset. Each agent-target
# repo requires its PR-triggered checks (and an up-to-date branch) before merge — this is the gate
# the agent's PR must turn green, alongside the org "PR required" rule.
resource "github_repository_ruleset" "required_checks" {
  for_each = var.protected_repos

  name        = "required-checks"
  repository  = each.key
  target      = "branch"
  enforcement = var.enforcement

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    required_status_checks {
      strict_required_status_checks_policy = true # branch must be up to date before merge

      dynamic "required_check" {
        for_each = each.value.required_checks
        content {
          context = required_check.value
          # integration_id = 15368  # pin the check source to GitHub Actions if a name ever collides
        }
      }
    }
  }
}
