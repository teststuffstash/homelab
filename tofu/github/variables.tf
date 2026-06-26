variable "org" {
  description = "GitHub organization that owns the repos."
  type        = string
  default     = "teststuffstash"
}

# Rollout safety: start in "evaluate" (dry-run — GitHub records what WOULD be blocked but enforces
# nothing), confirm in the org ruleset Insights that humans still pass and only the agent is caught,
# THEN flip to "active". Applying "active" before the admin bypass is verified would block your own
# direct-to-master IaC pushes on every repo.
variable "enforcement" {
  description = "Ruleset enforcement: evaluate (dry-run), active, or disabled."
  type        = string
  default     = "evaluate"
  validation {
    condition     = contains(["evaluate", "active", "disabled"], var.enforcement)
    error_message = "enforcement must be one of: evaluate, active, disabled."
  }
}

# Per-repo required status checks. Key = repo, value = the PR-triggered check (job) names that must
# pass before merge. ⚠ Only list checks that actually run on `pull_request` — a required check that
# never reports leaves every PR un-mergeable. (e.g. sleep-tracking's build-image runs on push only,
# so it can't be required; its `ci` job does run on PRs.) Add repos here as they grow PR CI + the
# full-stack confidence gate.
variable "protected_repos" {
  description = "Map of repo => required PR status-check contexts."
  type = map(object({
    required_checks = list(string)
  }))
  default = {
    sleep-tracking = { required_checks = ["ci"] }
    # snore-recorder = { required_checks = ["ci"] }   # enable once its PR `ci` check is confirmed
    # agent-runtime  = { required_checks = [...] }     # needs a pull_request-triggered check first
  }
}
