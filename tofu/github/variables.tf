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
    sleep-iac      = { required_checks = ["ci"] }
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

# The homelab-deploy App id — NOT sensitive (the key is). Drives two things when set: (1) a bypass actor
# on sleep-iac's required-approval ruleset (repo_rulesets.tf), so the mechanical deploy-bump PR auto-merges
# on CI-green without an LLM review; (2) the DEPLOY_APP_ID Actions secret (actions_secrets.tf) the
# sleep-tracking deploy workflow reads to mint a sleep-iac-scoped token. Empty until the App is
# bootstrapped (scripts/github-deploy-app-bootstrap.sh) — while empty, both are skipped, so the github root
# still applies cleanly before the App exists. Injected by scripts/github-tf.sh when the cred dir is present.
variable "deploy_app_id" {
  description = "homelab-deploy GitHub App id (drives the sleep-iac approval bypass + DEPLOY_APP_ID secret). Empty until bootstrapped; injected by scripts/github-tf.sh."
  type        = string
  default     = ""
}

# The homelab-deploy App private key. SENSITIVE — injected by scripts/github-tf.sh from the cred dir
# (durable copy: Infisical DEPLOY_GH_APP_PRIVATE_KEY). Published to the DEPLOY_APP_PRIVATE_KEY Actions
# secret, scoped to sleep-tracking ONLY (it grants contents+PR write on sleep-iac). Empty until bootstrapped.
variable "deploy_app_private_key" {
  description = "homelab-deploy GitHub App PEM private key. Set via TF_VAR_deploy_app_private_key (scripts/github-tf.sh)."
  type        = string
  sensitive   = true
  default     = ""
}
