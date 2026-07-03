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
