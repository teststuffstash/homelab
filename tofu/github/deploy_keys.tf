# Deploy keys — repo-scoped push credentials, existence/scope as code (the minting doctrine).
# Only the PUBLIC half lives here; the private half is a wallet attachment materialized by
# scripts/wallet-files.sh into ~/.claude/<dir>/ (FU-001 cache convention).

# The Forgejo→GitHub CV publish key: the private teststuff repo's Forgejo action pushes the
# generated public CV content to rasmus-soot-cv over this key. Write-enabled but scoped to that
# one repo — a leak buys push access to a regenerable mirror and nothing else (why this is a
# deploy key and not a PAT). Private half: wallet entry `github-cv-deploy` / attachment
# `id_ed25519` → cache ~/.claude/homelab-cv-deploy/; the same key goes into the teststuff repo's
# Forgejo Actions secret (set via the Forgejo API, teststuff-side).
resource "github_repository_deploy_key" "rasmus_soot_cv_publish" {
  repository = github_repository.rasmus_soot_cv.name
  title      = "forgejo-teststuff-cv-publish"
  key        = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAnHF3fyi2E9QaX7TvLM0ZgxZmAPI+SwJW1txLNf7s9+ forgejo-teststuff-cv-publish"
  read_only  = false
}
