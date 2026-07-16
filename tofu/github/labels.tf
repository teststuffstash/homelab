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
    "major" = { color = "b60205", description = "MAJOR dependency bump — human-gated, coordinator-owned (not the review reflex)" }
    # C10 (TICK-LOG meta-2): a human direction reversal (language/architecture) invalidates open agent
    # PRs + queued scopes — carrying items are EXCLUDED from coordinator-scan's actionable set and
    # reported for a human sweep (re-scope / close PR + delete branch). Created imperatively via gh
    # 2026-07-09 on the six agent repos; declared here so provisioning owns it from the next apply.
    "direction-change"     = { color = "b60205", description = "Human reversed direction — sweep (re-scope/close+delete-branch) before any dispatch (C10)" }
    "major/awaiting-human" = { color = "d93f0b", description = "Major bump: migration documented, CI green, reviewer-approved — a human merges" }
    # Automation circuit breaker (born 2026-07-12: a review-reflex predicate bug re-dispatched the
    # reviewer every tick — 12 duplicate approvals on oracle-fleet#13). Tripped by the reflex breakers
    # (docs/agents/merge-path.md) or applied by any human/agent that spots an anomaly; ALL agent
    # automation skips an item carrying it until a human removes it. Pre-created via gh on the
    # label_repos 2026-07-12 — import before apply (see header).
    "agent/error" = { color = "b60205", description = "Automation anomaly — circuit breaker; agents skip this item until a human clears it" }
  }

  # Repos that carry the agent state-machine + merge-path labels as code — a repo can be managed in
  # repos.tf (auto-merge etc.) without them, so this list is separate from the repos.tf resources.
  #
  # ⚠ SHRINKING (FU-068, 2026-07-16): five repos are now CLAIM-owned (AgentStack `labels:` →
  # authoritative IssueLabels): oracle-fleet, oracle-iac, agent-runtime, agent-coordinator,
  # openrouter-operator (+ allure-behavior-snippets, never listed here). Their entries are
  # REMOVED below — before the next apply, `tofu state rm` them so tofu FORGETS without
  # deleting (a destroy apply deletes the labels on GitHub and the claim fights it back):
  #   for r in oracle-fleet oracle-iac agent-runtime agent-coordinator openrouter-operator; do
  #     devbox run github-tofu state list | grep "github_issue_label.agent\[\\\"$r::" \
  #       | while read -r res; do devbox run github-tofu state rm "$res"; done
  #   done
  #   devbox run github-tofu state list | grep 'github_issue_label.track' \
  #     | while read -r res; do devbox run github-tofu state rm "$res"; done
  # Delete this file entirely when the list below empties (sleep repos + homelab remain).
  label_repos = ["sleep-tracking", "snore-recorder", "sleep-iac", "homelab"]

  # Track-lane labels are per-STACK, not global (oracle-fleet specs/TRACKS.md): exclusive
  # directory ownership per coordinator track — meaningless on repos outside the stack, so scoped.
  # Pre-created by hand on both oracle repos 2026-07-08 — import before apply (see header):
  # (via the wrapper — bare `tofu` misses the TF_VAR_*/admin-token assembly of scripts/github-tf.sh):
  #   for r in oracle-fleet oracle-iac; do for l in chassis ingest server deploy; do
  #     devbox run github-tofu import "github_issue_label.agent[\"${r}::track/${l}\"]" "${r}:track/${l}"
  #   (braces matter: in zsh, unbraced `$r:track` parses `:t` as a csh modifier and eats it)
  #   done; done
  # track/* lane labels moved to the oracle AgentStack claim's labels.extra (FU-068, 2026-07-16)
  # — both carrying repos are claim-owned now. Empty (not deleted) so the merge below stays
  # shaped; goes away with this whole file when label_repos empties. State-rm note above covers
  # the github_issue_label.agent["<repo>::track/*"] resources too.
  track_labels      = {}
  track_label_repos = []

  repo_labels = merge(
    {
      for pair in setproduct(local.label_repos, keys(local.agent_labels)) :
      "${pair[0]}::${pair[1]}" => {
        repo        = pair[0]
        name        = pair[1]
        color       = local.agent_labels[pair[1]].color
        description = local.agent_labels[pair[1]].description
      }
    },
    {
      for pair in setproduct(local.track_label_repos, keys(local.track_labels)) :
      "${pair[0]}::${pair[1]}" => {
        repo        = pair[0]
        name        = pair[1]
        color       = local.track_labels[pair[1]].color
        description = local.track_labels[pair[1]].description
      }
    }
  )
}

resource "github_issue_label" "agent" {
  for_each = local.repo_labels

  repository  = each.value.repo
  name        = each.value.name
  color       = each.value.color
  description = each.value.description
}
