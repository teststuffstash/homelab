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

# The homelab-merge App id — not sensitive (the private key is). Exposed to the agent repos' workflows as
# the org Actions secret MERGE_GH_APP_ID (actions_secrets.tf), for the FU-041 updater's App-token mint.
# Provided by scripts/github-tf.sh from the cred dir (~/.claude/homelab-github-merge/app-id) — no default,
# so a bare `tofu apply` (without the wrapper) fails loudly rather than minting a secret with an empty id.
variable "merge_gh_app_id" {
  description = "homelab-merge GitHub App id. Set via TF_VAR_merge_gh_app_id (scripts/github-tf.sh injects it)."
  type        = string
}

# The homelab-merge App private key. SENSITIVE — sourced from the cred-dir PEM by scripts/github-tf.sh
# (durable copy: Infisical MERGE_GH_APP_PRIVATE_KEY); never in tfvars/git. See actions_secrets.tf's header
# for the secrets-in-state tradeoff. No default → apply fails loudly if it isn't provided.
variable "merge_gh_app_private_key" {
  description = "homelab-merge GitHub App PEM private key. Set via TF_VAR_merge_gh_app_private_key (scripts/github-tf.sh)."
  type        = string
  sensitive   = true
}
