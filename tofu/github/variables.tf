variable "org" {
  description = "GitHub organization that owns the repos."
  type        = string
  default     = "teststuffstash"
}

# Rollout. ⚠ "evaluate" (dry-run) AND its Insights are GitHub Enterprise-only — on Team the API accepts
# evaluate but the ruleset is inert and uninspectable (looks protected, isn't). On Team the only
# meaningful values are "active" and "disabled"; there is no observe-first mode. Default is "active":
# protection is this root's whole purpose, so a bare `apply` must KEEP it on — never silently disable
# it by omitting a flag. The admin bypass is verified live (a direct owner push shows "Bypassed rule
# violations"). For a deliberate rollback: `apply -var enforcement=disabled`.
variable "enforcement" {
  description = "Ruleset enforcement: active or disabled (evaluate is Enterprise-only — inert on Team)."
  type        = string
  default     = "active"
  validation {
    condition     = contains(["evaluate", "active", "disabled"], var.enforcement)
    error_message = "enforcement must be one of: evaluate, active, disabled (evaluate needs Enterprise)."
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
