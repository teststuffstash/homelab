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
    # converges the fleet, so the lifecycle block below ignores this ONE attribute's drift;
    # 1 stays as the create value (every existing ruleset was created with it successfully).
    actor_id    = 1
    actor_type  = "OrganizationAdmin"
    bypass_mode = "always"
  }

  # The homelab-merge App (FU-041 updater) bypasses — added 2026-08-07 for #118. `update-pr-branch`
  # pushes a merge commit straight onto a PR's HEAD branch via the update-branch API, and since the
  # goal lane went live (2026-08-06) a head branch can itself be `goal/**`, i.e. covered here. A bare
  # push carries no check run, so required-status-checks rejects it: "Required status check 'ci' is
  # expected" — one half of the observed 422 (the other half is required-approval-goal below).
  # ⚠ A ruleset bypass is per-RULESET, not per-ref, so this also waives required-checks on
  # ~DEFAULT_BRANCH for this App. Bounded, and checked before adding: homelab-merge still cannot
  # reach master, because the ORG structural ruleset (org_ruleset.tf) requires a PR there and does
  # not list it, and required-approval below still demands an approving review it cannot waive.
  # This is NOT the agents App — that one stays off every bypass list so agent PRs must go green.
  bypass_actors {
    actor_id    = tonumber(var.merge_gh_app_id) # Integration actor_id = the GitHub App id
    actor_type  = "Integration"
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
    # NARROWED 2026-08-07 (#118) from the whole `bypass_actors` list to that one attribute: ignoring
    # the list wholesale made every LATER bypass-actor edit a SILENT NO-OP on already-created
    # rulesets — the Integration actor above would never have been reconciled. Safe to narrow,
    # because this ignore only ever suppressed PLAN NOISE: the value Terraform would write is the
    # config value, which is what we want live anyway, so the worst case of narrowing is a diff
    # that re-asserts actor_id = 1 — never a wrong live state.
    ignore_changes = [bypass_actors[0].actor_id]
  }

}

# Per-repo REQUIRED APPROVAL — the reviewer half of the agentic merge gate. The org structural ruleset
# keeps required_approving_review_count = 0 ("approvals are a per-repo choice"); this makes it 1 on the
# agent-target repos. GitHub aggregates PR rules across rulesets by the most-restrictive value, so 1
# wins over the org's 0. Effect: an agent PR (homelab-agents[bot]) needs a native approving review from
# a DISTINCT identity — homelab-reviewer[bot] (self-approval is blocked) — before GitHub auto-merge fires.
# Kept a separate ruleset from required-checks so approvals and checks enforce/toggle independently.
#
# SPLIT master vs goal/** (2026-08-06, the FU-143/#29 goal lane): require_code_owner_review is a
# pull_request-rule flag, so with ONE ruleset covering both refs a codeowner gate meant for the
# goal→master ASSEMBLY PR would also bind every CHILD PR into goal/** that touches an owned path
# (circles: the evidence-chain child writes into /specs/) — serialising the fan-out on a human.
# Two rulesets, same approval rule; the codeowner flag exists ONLY on the master-targeted one.
# Consequence for oracle-fleet (the flag's first user): its /specs/ + /.agents/ codeowner gate now
# binds only where work lands on MASTER — a future goal lane there gets bot-approved children too.
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
      include = ["~DEFAULT_BRANCH"]
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
  #
  # (And no homelab-merge App bypass here either, unlike its goal/** twin below — DELIBERATE, not an
  # oversight of #118. The updater only ever pushes to a PR's HEAD branch, and a head branch is never
  # master; the master-targeted approval gate has no legitimate reason to be waivable by any App.)

  rules {
    pull_request {
      required_approving_review_count   = 1    # the reviewer bot's approval
      dismiss_stale_reviews_on_push     = true # new commits after approval re-open the gate
      require_last_push_approval        = false
      required_review_thread_resolution = false
      # Per-repo opt-in (oracle-fleet /specs/ + /.agents/; circles same shape for the goal lane):
      # PRs touching CODEOWNERS paths block on a code-owner (human) review — the bot's approval
      # doesn't satisfy it. No-owned-path PRs unaffected. MASTER-targeted only (see the split
      # note above): the goal→master assembly PR is the intended catch (its diff always touches
      # /specs/ — the provenance requirement), and the operator merges it via OrgAdmin override.
      require_code_owner_review = each.value.require_code_owner_review
    }
  }
  lifecycle {
    # the OrganizationAdmin actor_id read-back is nondeterministic (see bypass_actors note) —
    # without this, every plan re-diffs whichever cohort disagrees with the literal.
    # NARROWED 2026-08-07 (#118) for the same reason as its two siblings — no bypass-actor change
    # is needed on THIS ruleset today, but leaving one wholesale ignore in the file leaves the
    # silent-no-op trap armed for whoever edits it next. All three now ignore only the noisy field.
    ignore_changes = [bypass_actors[0].actor_id]
  }

}

# The goal/** twin of required-approval — same approval rule, NEVER the codeowner flag (the split
# note above). `goal/**` = a GOAL'S INTEGRATION BRANCH (FU-090 leg (c), 2026-08-05): a stacked base
# that a goal's child PRs merge INTO, named for the goal that owns it (goal/<issue>-<slug>). It is
# protected for the same reason master is — children AUTO-MERGE into it once CI is green and the
# reviewer approves, and GitHub's auto-merge waits on branch-protection conditions, so an
# UNPROTECTED base means auto-merge fires on open: no CI, no review. Protecting it is what makes
# feature→goal automatic and safe; goal→master stays a human decision (operator).
# NOT `research/**`: the researcher arms PUSH DIRECTLY to those branches, and a ruleset there
# would gate their own pushes. Disjoint prefixes on purpose — `fix/**` heads, `research/**`
# researcher outputs, `goal/**` integration bases.
resource "github_repository_ruleset" "required_approval_goal" {
  for_each = { for k, v in var.protected_repos : k => v if v.require_approval }

  name        = "required-approval-goal"
  repository  = each.key
  target      = "branch"
  enforcement = var.enforcement

  conditions {
    ref_name {
      include = ["refs/heads/goal/**"]
      exclude = []
    }
  }

  bypass_actors {
    # actor_id noise: for OrganizationAdmin the API's read-back is INCONSISTENT — measured
    # 2026-07-25, four rulesets read 0 while ten read 1 for the identical write. No literal
    # converges the fleet, so the lifecycle block below ignores this ONE attribute's drift;
    # 1 stays as the create value (every existing ruleset was created with it successfully).
    actor_id    = 1
    actor_type  = "OrganizationAdmin"
    bypass_mode = "always"
  }

  # The homelab-merge App (FU-041 updater) bypasses — added 2026-08-07 for #118, the other half of
  # the same 422. This ruleset's pull_request rule means "changes to goal/** must come via a
  # reviewed PR", which by construction forbids the update-branch API's direct push onto a PR head
  # branch that IS a goal branch (circles PR #54, head `goal/29-p0-complete`). Latent since
  # 2026-08-06; it bit the first time the FIFO queue reached such a PR.
  # Why this is not the caveat recorded on required-approval above: THAT warning is about GitHub
  # refusing to let an App's Integration bypass waive required approvals when MERGING a pull
  # request. This is a raw ref update — a different enforcement path, which a bypass actor does
  # cover. Confirm empirically after apply in the repo's Rule Insights: the App's update-branch
  # push should read "Bypass", not "Fail". If it reads Fail, the actor entry is wrong (wrong id),
  # not the approach.
  # Note this does NOT let homelab-merge merge a goal PR or approve anything — the App has no
  # approval permission and the rule above still needs the reviewer bot's review.
  bypass_actors {
    actor_id    = tonumber(var.merge_gh_app_id) # Integration actor_id = the GitHub App id
    actor_type  = "Integration"
    bypass_mode = "always"
  }

  rules {
    pull_request {
      required_approving_review_count   = 1    # the reviewer bot's approval
      dismiss_stale_reviews_on_push     = true # new commits after approval re-open the gate
      require_last_push_approval        = false
      required_review_thread_resolution = false
      # DELIBERATELY no require_code_owner_review here — a codeowner gate on goal/** would
      # serialise the children's fan-out on a human (the reason this ruleset exists apart).
    }
  }
  lifecycle {
    # the OrganizationAdmin actor_id read-back is nondeterministic (see bypass_actors note) —
    # without this, every plan re-diffs whichever cohort disagrees with the literal.
    # NARROWED 2026-08-07 (#118) — see the identical note on required_checks: ignoring the whole
    # list made any later bypass-actor edit a silent no-op on already-created rulesets.
    ignore_changes = [bypass_actors[0].actor_id]
  }

}

# PUSH ruleset — the enforcement-grade native version of the sentinel's path rule (iac-lane.md
# §L0b; the sleep-iac#28 hole: in-repo CI runs the PR's own workflow code, so a required check
# the PR can rewrite is not a gate against the worker). A push ruleset evaluates the PUSH, on
# every branch, before any PR machinery — a worker cannot even stage a workflow edit. Shipped
# with the G01 enforcement flip (2026-08-18) alongside the required `iac-sentinel` context; the
# sentinel's own path-rule stays as the belt (it also covers `scripts/ci*`, which this ruleset
# leaves alone — those are repo-relative CI entrypoints, not GitHub-executed workflow files).
# ⚠ GitHub allows push rules on PRIVATE repos only (422 "Source public repos cannot have push
# rules", learned at the flip apply) — see the restrict_workflow_pushes comment in variables.tf
# for what carries the fence on public repos. Today this materializes on oracle-iac alone.
resource "github_repository_ruleset" "workflow_push_guard" {
  for_each = { for k, v in var.protected_repos : k => v if v.restrict_workflow_pushes }

  name        = "workflow-push-guard"
  repository  = each.key
  target      = "push"
  enforcement = var.enforcement

  # Push rulesets take no ref conditions — they apply to every push to the repository.

  # Org admins (operator + jail seat) bypass: workflow edits are the operator lane by doctrine
  # (CLAUDE.md §How changes land — governance files the bot cannot gate).
  bypass_actors {
    # actor_id noise: same OrganizationAdmin read-back inconsistency as the three rulesets
    # above — the lifecycle block ignores this one attribute's drift.
    actor_id    = 1
    actor_type  = "OrganizationAdmin"
    bypass_mode = "always"
  }

  # homelab-merge (FU-041 updater): update-branch pushes a merge commit onto a PR HEAD, and
  # that commit carries whatever master changed — including workflow edits — so without a
  # bypass the updater 422s on any PR open across a workflow-touching master commit (#118's
  # class). The App pushes only to PR heads; it cannot reach master (org ruleset requires a
  # PR there and does not list it).
  bypass_actors {
    actor_id    = tonumber(var.merge_gh_app_id)
    actor_type  = "Integration"
    bypass_mode = "always"
  }

  # homelab-renovate: its Actions SHA-pinning branches edit `.github/workflows/**` by design.
  # The PRs still gate on the human codeowner where CODEOWNERS owns that path (homelab) — the
  # bypass only lets the branch be PUSHED. Conditional: the App id is empty until bootstrapped.
  dynamic "bypass_actors" {
    for_each = var.renovate_app_id != "" ? [1] : []
    content {
      actor_id    = tonumber(var.renovate_app_id)
      actor_type  = "Integration"
      bypass_mode = "always"
    }
  }

  rules {
    file_path_restriction {
      restricted_file_paths = [".github/workflows/**"]
    }
  }

  lifecycle {
    # same OrganizationAdmin actor_id read-back nondeterminism as the sibling rulesets.
    ignore_changes = [bypass_actors[0].actor_id]
  }
}
