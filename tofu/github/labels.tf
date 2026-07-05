# The agent state-machine labels (agents/coordinator/README.md §State machine) as code, on the fixer
# repos. The coordinator drives the whole loop by relabelling issues/PRs, so these are load-bearing.
#
# github_issue_label (singular) is NON-authoritative: it manages ONLY these labels and leaves each repo's
# other labels (GitHub defaults, human-added) untouched. Run OUTSIDE the jail (admin PAT — see README.md).
#
# ⚠ If a label ALREADY exists on a repo, `apply` errors "already exists" — import it first (id is
#   <repo>:<name>):
#     tofu -chdir=tofu/github import 'github_issue_label.agent["sleep-tracking::agent/queued"]' 'sleep-tracking:agent/queued'
#   Adopt any pre-existing ones in one pass (harmless if none exist):
#     for r in sleep-tracking snore-recorder; do
#       gh label list --repo teststuffstash/$r --json name -q '.[].name' | while read -r l; do
#         case "$l" in agent-fix|agent/*|agent-budget/*)
#           tofu -chdir=tofu/github import "github_issue_label.agent[\"$r::$l\"]" "$r:$l" ;;
#         esac
#       done
#     done

locals {
  agent_labels = {
    "agent-fix"         = { color = "0e8a16", description = "Opt-in: this issue is fair game for the agent fixer" }
    "agent/queued"      = { color = "fbca04", description = "Ready to dispatch a worker" }
    "agent/in-progress" = { color = "1d76db", description = "A worker pod is running this round" }
    "agent/review"      = { color = "5319e7", description = "PR open, awaiting review (human or agent)" }
    "agent/blocked"     = { color = "b60205", description = "Needs a human — budget escalate / max rounds / ambiguous" }
    "agent/done"        = { color = "0b6b3a", description = "Merged" }
    "agent-budget/xs"   = { color = "c5def5", description = "Estimator cap-tier override: xs" }
    "agent-budget/sm"   = { color = "c5def5", description = "Estimator cap-tier override: sm" }
    "agent-budget/md"   = { color = "c5def5", description = "Estimator cap-tier override: md" }
    "agent-budget/lg"   = { color = "c5def5", description = "Estimator cap-tier override: lg" }
    # Set by the updater workflow (FU-041) when an auto-merge-armed PR's branch conflicts with master —
    # the update-branch API can't resolve it (422), so it's flagged for the coordinator to decide.
    "merge-conflict" = { color = "e11d21", description = "PR branch conflicts with master — updater can't auto-resolve; needs a worker re-run or rebase" }
    # The devbox MAJOR-bump lane (FU-022/FU-047): `major` set by devbox-update.sh (also self-created there
    # with --force); `major/awaiting-human` set by the coordinator once the migration is documented + CI is
    # green — a HUMAN merges. Declared here so provisioning does NOT depend on an in-session `gh` call: a
    # missing label makes a relabel HALF-APPLY and corrupt state (learned live on sleep-tracking#18).
    "major"                = { color = "b60205", description = "MAJOR dependency bump — human-gated, coordinator-owned (not the review reflex)" }
    "major/awaiting-human" = { color = "d93f0b", description = "Major bump: migration documented, CI green, reviewer-approved — a human merges" }
  }

  # Repos that carry the agent state-machine + merge-path labels as code — a repo can be managed in
  # repos.tf (auto-merge etc.) without them, so this list is separate from the repos.tf resources.
  # (openrouter-operator/agent-runtime/agent-coordinator currently have 0 issues → 0 existing labels, so
  # the first apply CREATEs them clean — nothing to import.)
  label_repos = ["sleep-tracking", "snore-recorder", "sleep-iac", "openrouter-operator", "agent-runtime", "agent-coordinator"]

  repo_labels = {
    for pair in setproduct(local.label_repos, keys(local.agent_labels)) :
    "${pair[0]}::${pair[1]}" => {
      repo        = pair[0]
      name        = pair[1]
      color       = local.agent_labels[pair[1]].color
      description = local.agent_labels[pair[1]].description
    }
  }
}

resource "github_issue_label" "agent" {
  for_each = local.repo_labels

  repository  = each.value.repo
  name        = each.value.name
  color       = each.value.color
  description = each.value.description
}
