output "org_ruleset_id" {
  description = "Numeric id of the org structural ruleset."
  value       = github_organization_ruleset.default_branch.ruleset_id
}

output "repo_ruleset_ids" {
  description = "Per-repo required-checks ruleset ids."
  value       = { for k, r in github_repository_ruleset.required_checks : k => r.ruleset_id }
}

output "enforcement" {
  description = "Current enforcement mode (flip var.enforcement to active once verified)."
  value       = var.enforcement
}
