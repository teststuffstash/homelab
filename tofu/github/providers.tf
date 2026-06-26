# GitHub auth = GITHUB_TOKEN env var, set to a token with **Administration: write** on the org/repos
# (rulesets need org admin). The jail PAT deliberately lacks this — run this root OUTSIDE the jail,
# the same way tofu/cloudflare/ runs with the scoped CF token. Never put the token in tfvars/git.
#     export GITHUB_TOKEN=$(cat ~/.config/github-admin-token)   # or `gh auth token` as an owner
provider "github" {
  owner = var.org
}
