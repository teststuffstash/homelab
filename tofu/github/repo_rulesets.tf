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
      # `goal/**` = a GOAL'S INTEGRATION BRANCH (FU-090 leg (c), 2026-08-05): a stacked base that a
      # goal's child PRs merge INTO, named for the goal that owns it (goal/<issue>-<slug>). It is
      # protected for the same reason master is — children AUTO-MERGE into it once CI is green and
      # the reviewer approves, and GitHub's auto-merge waits on branch-protection conditions, so an
      # UNPROTECTED base means auto-merge fires on open: no CI, no review. Protecting it is what
      # makes feature→goal automatic and safe; goal→master stays a human decision (operator).
      # NOT `research/**`: the researcher arms PUSH DIRECTLY to those branches, and a ruleset there
      # would gate their own pushes. Disjoint prefixes on purpose — `fix/**` heads, `research/**`
      # researcher outputs, `goal/**` integration bases.
      include = ["~DEFAULT_BRANCH", "refs/heads/goal/**"]
      exclude = []
    }
  }

  # Org admins (you) bypass the required check too, matching the org structural ruleset — otherwise a
  # required check (which only reports on a PR) blocks even the owner's direct-to-master, since a bare
  # push has no check run. The agents App is deliberately NOT listed, so its PRs must still go green.
  bypass_actors {
    # actor_id noise: for OrganizationAdmin the API's read-back is INCONSISTENT — measured
    # 2026-07-25, four rulesets read 0 while ten read 1 for the identical write. No literal
    # converges the fleet, so the lifecycle block below ignores bypass_actors drift entirely;
    # 1 stays as the create value (every existing ruleset was created with it successfully).
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
  lifecycle {
    # the OrganizationAdmin actor_id read-back is nondeterministic (see bypass_actors note) —
    # without this, every plan re-diffs whichever cohort disagrees with the literal.
    ignore_changes = [bypass_actors]
  }

}

# Per-repo REQUIRED APPROVAL — the reviewer half of the agentic merge gate. The org structural ruleset
# keeps required_approving_review_count = 0 ("approvals are a per-repo choice"); this makes it 1 on the
# agent-target repos. GitHub aggregates PR rules across rulesets by the most-restrictive value, so 1
# wins over the org's 0. Effect: an agent PR (homelab-agents[bot]) needs a native approving review from
# a DISTINCT identity — homelab-reviewer[bot] (self-approval is blocked) — before GitHub auto-merge fires.
# Kept a separate ruleset from required-checks so approvals and checks enforce/toggle independently.
resource "github_repository_ruleset" "required_approval" {
  # Only repos that opt into a review gate. sleep-iac opts OUT (require_approval=false): its PRs are
  # mechanical deploy bumps gated by CI, and GitHub's App bypass can't waive the approval on a merge.
  for_each = { for k, v in var.protected_repos : k => v if v.require_approval }

  name        = "required-approval"
  repository  = each.key
  target      = "branch"
  enforcement = var.enforcement

  conditions {
    ref_name {
      # `goal/**` = a GOAL'S INTEGRATION BRANCH (FU-090 leg (c), 2026-08-05): a stacked base that a
      # goal's child PRs merge INTO, named for the goal that owns it (goal/<issue>-<slug>). It is
      # protected for the same reason master is — children AUTO-MERGE into it once CI is green and
      # the reviewer approves, and GitHub's auto-merge waits on branch-protection conditions, so an
      # UNPROTECTED base means auto-merge fires on open: no CI, no review. Protecting it is what
      # makes feature→goal automatic and safe; goal→master stays a human decision (operator).
      # NOT `research/**`: the researcher arms PUSH DIRECTLY to those branches, and a ruleset there
      # would gate their own pushes. Disjoint prefixes on purpose — `fix/**` heads, `research/**`
      # researcher outputs, `goal/**` integration bases.
      include = ["~DEFAULT_BRANCH", "refs/heads/goal/**"]
      exclude = []
    }
  }

  # Org admins (you) bypass, matching the org structural ruleset — so an owner's direct-to-master isn't
  # blocked for want of an approval. The agents App is deliberately NOT listed, so its PRs still need one.
  bypass_actors {
    # actor_id noise: for OrganizationAdmin the API's read-back is INCONSISTENT — measured
    # 2026-07-25, four rulesets read 0 while ten read 1 for the identical write. No literal
    # converges the fleet, so the lifecycle block below ignores bypass_actors drift entirely;
    # 1 stays as the create value (every existing ruleset was created with it successfully).
    actor_id    = 1
    actor_type  = "OrganizationAdmin"
    bypass_mode = "always"
  }

  # (No homelab-deploy App bypass here: sleep-iac isn't in this ruleset at all — require_approval=false —
  # because a GitHub App's Integration bypass does NOT waive the "required approvals" rule on a merge, so
  # bypassing was never going to let the App's deploy-bump merge through. CI gates the bump instead.)

  rules {
    pull_request {
      required_approving_review_count   = 1    # the reviewer bot's approval
      dismiss_stale_reviews_on_push     = true # new commits after approval re-open the gate
      require_last_push_approval        = false
      required_review_thread_resolution = false
      # Per-repo opt-in (oracle-fleet): PRs touching CODEOWNERS paths (/specs/, /.agents/) block on a
      # code-owner (human) review — the bot's approval doesn't satisfy it. No-owned-path PRs unaffected.
      require_code_owner_review = each.value.require_code_owner_review
    }
  }
  lifecycle {
    # the OrganizationAdmin actor_id read-back is nondeterministic (see bypass_actors note) —
    # without this, every plan re-diffs whichever cohort disagrees with the literal.
    ignore_changes = [bypass_actors]
  }

}
