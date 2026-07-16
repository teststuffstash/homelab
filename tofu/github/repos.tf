# The agent-target repos, FULLY managed as code — every writable, non-deprecated attribute is declared,
# so "how is this repo configured" is answered by reading this file (no click-ops; boot-from-git). Values
# were captured from the live repos (`tofu plan` + `gh repo view`); the only deliberate changes from
# current state are allow_auto_merge + delete_branch_on_merge → true (the reviewer→auto-merge flow) and
# archive_on_destroy → true (a `tofu destroy` ARCHIVES the repo, never deletes it — safety net).
# Deprecated attrs are intentionally omitted (provider warns + removing them): has_downloads and
# vulnerability_alerts (no-ops); default_branch / private are computed (use github_branch_default /
# visibility). Removing them changes nothing — they were already their default values.
#
# Run OUTSIDE the jail with the fine-grained admin PAT (Administration:R/W for repos/rulesets, Issues:R/W
# for labels.tf). See README.md. The `import` blocks adopt the live repos on first apply.
#
# Adding a repo: run `scripts/new-agent-repo.sh <name> [--public|--private] [--no-labels]` — it appends
# the block here (with an `import` iff the repo already exists), wires protected_repos + label_repos, and
# prints the App-install click + the out-of-jail apply. Or copy a block + its `import` by hand. Both
# current repos are private with identical settings, but they're spelled out per-repo (not for_each) so
# each stays independently editable.

import {
  to = github_repository.sleep_tracking
  id = "sleep-tracking"
}

import {
  to = github_repository.snore_recorder
  id = "snore-recorder"
}

resource "github_repository" "sleep_tracking" {
  name         = "sleep-tracking"
  description  = ""
  homepage_url = ""
  topics       = []
  visibility   = "private"

  has_issues      = true
  has_projects    = true
  has_wiki        = false
  has_discussions = false
  is_template     = false

  allow_merge_commit          = true
  allow_squash_merge          = true
  allow_rebase_merge          = true
  allow_auto_merge            = true # ← change: GitHub completes the PR once approval + CI pass
  allow_update_branch         = false
  allow_forking               = false
  delete_branch_on_merge      = true # ← change: clean up the worker's agent/* branch after merge
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
    # The single unavoidable exception to "declare everything": has_downloads is a deprecated GitHub
    # feature with no schema default and not computed — DECLARING it emits a deprecation warning, but
    # OMITTING it perpetually diffs true->false (the provider can't tell "keep" from "set false"). So we
    # neither set it nor reconcile it. It's a dead no-op attribute.
    ignore_changes = [has_downloads]
  }
}

resource "github_repository" "snore_recorder" {
  name         = "snore-recorder"
  description  = ""
  homepage_url = ""
  topics       = []
  visibility   = "private" # the REPO is private; only its ghcr package is public (a separate setting)

  has_issues      = true
  has_projects    = true
  has_wiki        = false
  has_discussions = false
  is_template     = false

  allow_merge_commit          = true
  allow_squash_merge          = true
  allow_rebase_merge          = true
  allow_auto_merge            = true # ← change
  allow_update_branch         = false
  allow_forking               = false
  delete_branch_on_merge      = true # ← change
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
    # The single unavoidable exception to "declare everything": has_downloads is a deprecated GitHub
    # feature with no schema default and not computed — DECLARING it emits a deprecation warning, but
    # OMITTING it perpetually diffs true->false (the provider can't tell "keep" from "set false"). So we
    # neither set it nor reconcile it. It's a dead no-op attribute.
    ignore_changes = [has_downloads]
  }
}

resource "github_repository" "sleep_iac" {
  name         = "sleep-iac"
  description  = "IaC/deploy for the sleep stack (FU-025)"
  homepage_url = ""
  topics       = []
  visibility   = "public"

  has_issues      = true
  has_projects    = true
  has_wiki        = false
  has_discussions = false
  is_template     = false

  allow_merge_commit          = true
  allow_squash_merge          = true
  allow_rebase_merge          = true
  allow_auto_merge            = true # GitHub completes the PR once approval + CI pass
  allow_update_branch         = false
  allow_forking               = true # PUBLIC repos are always forkable — GitHub ignores false, so match it (no perpetual diff)
  delete_branch_on_merge      = true # clean up the worker's agent/* branch after merge
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
    # has_downloads is a deprecated no-op attribute: declaring it warns, omitting it perpetually
    # diffs true->false. So we neither set nor reconcile it (see the header repos in this file).
    ignore_changes = [has_downloads]
  }
}

import {
  to = github_repository.openrouter_operator
  id = "openrouter-operator"
}

resource "github_repository" "openrouter_operator" {
  name         = "openrouter-operator"
  description  = ""
  homepage_url = ""
  topics       = []
  visibility   = "public"

  has_issues      = true
  has_projects    = true
  has_wiki        = false
  has_discussions = false
  is_template     = false

  allow_merge_commit          = true
  allow_squash_merge          = true
  allow_rebase_merge          = true
  allow_auto_merge            = true # GitHub completes the PR once approval + CI pass
  allow_update_branch         = false
  allow_forking               = true
  delete_branch_on_merge      = true # clean up the worker's agent/* branch after merge
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
    # has_downloads is a deprecated no-op attribute: declaring it warns, omitting it perpetually
    # diffs true->false. So we neither set nor reconcile it (see the header repos in this file).
    ignore_changes = [has_downloads]
  }
}

import {
  to = github_repository.agent_runtime
  id = "agent-runtime"
}

resource "github_repository" "agent_runtime" {
  name         = "agent-runtime"
  description  = ""
  homepage_url = ""
  topics       = []
  visibility   = "public"

  has_issues      = true
  has_projects    = true
  has_wiki        = false
  has_discussions = false
  is_template     = false

  allow_merge_commit          = true
  allow_squash_merge          = true
  allow_rebase_merge          = true
  allow_auto_merge            = true # GitHub completes the PR once approval + CI pass
  allow_update_branch         = false
  allow_forking               = true
  delete_branch_on_merge      = true # clean up the worker's agent/* branch after merge
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
    # has_downloads is a deprecated no-op attribute: declaring it warns, omitting it perpetually
    # diffs true->false. So we neither set nor reconcile it (see the header repos in this file).
    ignore_changes = [has_downloads]
  }
}

import {
  to = github_repository.agent_coordinator
  id = "agent-coordinator"
}

resource "github_repository" "agent_coordinator" {
  name         = "agent-coordinator"
  description  = ""
  homepage_url = ""
  topics       = []
  visibility   = "public"

  has_issues      = true
  has_projects    = true
  has_wiki        = false
  has_discussions = false
  is_template     = false

  allow_merge_commit          = true
  allow_squash_merge          = true
  allow_rebase_merge          = true
  allow_auto_merge            = true # GitHub completes the PR once approval + CI pass
  allow_update_branch         = false
  allow_forking               = true
  delete_branch_on_merge      = true # clean up the worker's agent/* branch after merge
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
    # has_downloads is a deprecated no-op attribute: declaring it warns, omitting it perpetually
    # diffs true->false. So we neither set nor reconcile it (see the header repos in this file).
    ignore_changes = [has_downloads]
  }
}

import {
  to = github_repository.homelab
  id = "homelab"
}

resource "github_repository" "homelab" {
  name         = "homelab"
  description  = "Infrastructure-as-code home network — Talos Kubernetes (Proxmox + bare-metal), OPNsense, Cilium BGP, Longhorn, Home Assistant. Boot-from-git, no click-ops."
  homepage_url = ""
  topics = [
    "ansible",
    "bare-metal",
    "cilium",
    "cloudflare-tunnel",
    "esphome",
    "gitops",
    "home-assistant",
    "homelab",
    "infrastructure-as-code",
    "kubernetes",
    "longhorn",
    "matchbox",
    "opentofu",
    "opnsense",
    "proxmox",
    "pxe",
    "self-hosted",
    "talos-linux",
  ]
  visibility = "public"

  has_issues      = true
  has_projects    = true
  has_wiki        = true
  has_discussions = false
  is_template     = false

  allow_merge_commit          = true
  allow_squash_merge          = true
  allow_rebase_merge          = true
  allow_auto_merge            = true # GitHub completes the PR once approval + CI pass
  allow_update_branch         = false
  allow_forking               = true
  delete_branch_on_merge      = true # clean up the worker's agent/* branch after merge
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
    # has_downloads is a deprecated no-op attribute: declaring it warns, omitting it perpetually
    # diffs true->false. So we neither set nor reconcile it (see the header repos in this file).
    ignore_changes = [has_downloads]
  }
}

# allure-behavior-snippets — evidence-snippets tool riding the oracle stack claim (context-only;
# re-homes with the next spec-heavy stack). Adopted 2026-07-16 so the merge path can arm PRs
# (allow_auto_merge was false — renovate/automerge lanes can't work without it). PUBLIC repo,
# default branch MAIN (not master). Import before the first apply (outside the jail):
#   devbox run github-tofu import github_repository.allure_behavior_snippets allure-behavior-snippets
resource "github_repository" "allure_behavior_snippets" {
  name         = "allure-behavior-snippets"
  description  = ""
  homepage_url = ""
  topics       = []
  visibility   = "public"

  has_issues      = true
  has_projects    = true
  has_wiki        = true # was enabled at creation; keep — flipping it deletes wiki content
  has_discussions = false
  is_template     = false

  allow_merge_commit          = true
  allow_squash_merge          = true
  allow_rebase_merge          = true
  allow_auto_merge            = true # GitHub completes the PR once approval + CI pass
  allow_update_branch         = false
  allow_forking               = true # forced true on public repos
  delete_branch_on_merge      = true # clean up renovate/agent branches after merge
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
    ignore_changes = [has_downloads]
  }
}

resource "github_repository" "oracle_fleet" {
  name         = "oracle-fleet"
  description  = ""
  homepage_url = ""
  topics       = []
  # FU-055: flips to "public" at the stack's open-sourcing milestone (design doc is out-of-repo);
  # when it does, allow_forking must become true (GitHub forces it on public repos — see sleep_iac).
  visibility = "private"

  has_issues      = true
  has_projects    = true
  has_wiki        = false
  has_discussions = false
  is_template     = false

  allow_merge_commit          = true
  allow_squash_merge          = true
  allow_rebase_merge          = true
  allow_auto_merge            = true # GitHub completes the PR once approval + CI pass
  allow_update_branch         = false
  allow_forking               = false
  delete_branch_on_merge      = true # clean up the worker's agent/* branch after merge
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
    # has_downloads is a deprecated no-op attribute: declaring it warns, omitting it perpetually
    # diffs true->false. So we neither set nor reconcile it (see the header repos in this file).
    ignore_changes = [has_downloads]
  }
}

resource "github_repository" "oracle_iac" {
  name         = "oracle-iac"
  description  = "IaC/deploy for the oracle stack"
  homepage_url = ""
  topics       = []
  visibility   = "private"

  has_issues      = true
  has_projects    = true
  has_wiki        = false
  has_discussions = false
  is_template     = false

  allow_merge_commit          = true
  allow_squash_merge          = true
  allow_rebase_merge          = true
  allow_auto_merge            = true # GitHub completes the PR once approval + CI pass
  allow_update_branch         = false
  allow_forking               = false
  delete_branch_on_merge      = true # clean up the worker's agent/* branch after merge
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
    # has_downloads is a deprecated no-op attribute: declaring it warns, omitting it perpetually
    # diffs true->false. So we neither set nor reconcile it (see the header repos in this file).
    ignore_changes = [has_downloads]
  }
}
