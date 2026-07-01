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
# Adding a repo: copy a block + its `import`, then plan/apply. Both current repos are private with
# identical settings, but they're spelled out per-repo (not for_each) so each stays independently editable.

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
