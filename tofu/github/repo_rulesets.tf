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

  # Org admins (you) bypass the required check too, matching the org structural ruleset — otherwise a
  # required check (which only reports on a PR) blocks even the owner's direct-to-master, since a bare
  # push has no check run. The agents App is deliberately NOT listed, so its PRs must still go green.
  bypass_actors {
    actor_id    = 1
    actor_type  = "OrganizationAdmin"
    bypass_mode = "always"
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

# Per-repo REQUIRED APPROVAL — the reviewer half of the agentic merge gate. The org structural ruleset
# keeps required_approving_review_count = 0 ("approvals are a per-repo choice"); this makes it 1 on the
# agent-target repos. GitHub aggregates PR rules across rulesets by the most-restrictive value, so 1
# wins over the org's 0. Effect: an agent PR (homelab-agents[bot]) needs a native approving review from
# a DISTINCT identity — homelab-reviewer[bot] (self-approval is blocked) — before GitHub auto-merge fires.
# Kept a separate ruleset from required-checks so approvals and checks enforce/toggle independently.
resource "github_repository_ruleset" "required_approval" {
  for_each = var.protected_repos

  name        = "required-approval"
  repository  = each.key
  target      = "branch"
  enforcement = var.enforcement

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  # Org admins (you) bypass, matching the org structural ruleset — so an owner's direct-to-master isn't
  # blocked for want of an approval. The agents App is deliberately NOT listed, so its PRs still need one.
  bypass_actors {
    actor_id    = 1
    actor_type  = "OrganizationAdmin"
    bypass_mode = "always"
  }

  # homelab-deploy App bypass — ONLY on sleep-iac, and only once the App is bootstrapped (deploy_app_id
  # set). The deploy pipeline's version-bump PR is MECHANICAL (a one-line chart `targetRevision` bump the
  # sleep-tracking deploy workflow opens), so we gate it with CI, not an LLM review: the App is a bypass
  # actor for the approval rule, so a CI-green bump auto-merges without one. Blast radius stays small — the
  # App grants only contents+PR write on sleep-iac. See docs/sleep-iac.md §"Deploy pipeline".
  dynamic "bypass_actors" {
    for_each = (each.key == "sleep-iac" && var.deploy_app_id != "") ? [tonumber(var.deploy_app_id)] : []
    content {
      actor_id    = bypass_actors.value
      actor_type  = "Integration" # a GitHub App
      bypass_mode = "always"
    }
  }

  rules {
    pull_request {
      required_approving_review_count   = 1    # the reviewer bot's approval
      dismiss_stale_reviews_on_push     = true # new commits after approval re-open the gate
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }
  }
}
