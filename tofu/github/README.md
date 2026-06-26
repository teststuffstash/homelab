# tofu/github — branch protection as code (GitHub rulesets)

Separate OpenTofu root (own local state, like `tofu/cloudflare/`) that manages **branch protection**
for the org via **rulesets** — the "suspenders" of the agent platform: agents can push an `agent/…`
branch and open a PR, but **cannot reach a default branch** (homelab ADR-079/081, `docs/agents/`).

Two layers (per the chosen design):
- **Org structural** (`org_ruleset.tf`, `github_organization_ruleset`, all repos): require a PR, block
  force-push + default-branch deletion. **Org admins bypass** (you keep direct-to-master IaC); the
  **agents App is not in the bypass list**, so its `contents:write` still can't reach master.
- **Per-repo required checks** (`repo_rulesets.tf`, `github_repository_ruleset`): each agent-target
  repo requires its PR-triggered CI checks (+ up-to-date branch) before merge.

## Run it (OUTSIDE the jail)

Rulesets need **Administration: write** on the org, which the jail PAT deliberately lacks. Run this
root on a host authenticated as a `teststuffstash` owner — the same pattern as `tofu/cloudflare/`:

```sh
export GITHUB_TOKEN=$(gh auth token)            # as an org owner, or a token with org Administration
devbox run -- tofu -chdir=tofu/github init
devbox run -- tofu -chdir=tofu/github plan      # review
devbox run -- tofu -chdir=tofu/github apply
```

## Safe rollout (important)

`var.enforcement` defaults to **`evaluate`** (dry-run): GitHub records what *would* be blocked but
enforces nothing. Apply it, then in the org's **Settings → Rules → Insights** confirm that:
1. your own direct-to-master pushes show as **bypassed** (the admin bypass works), and
2. the agents App would be **blocked**.

Only then flip to active:
```sh
devbox run -- tofu -chdir=tofu/github apply -var enforcement=active
```
Applying `active` before verifying the admin bypass would block your own direct-to-master IaC pushes
on **every** repo. The `actor_id = 1 / OrganizationAdmin` bypass in `org_ruleset.tf` is the thing to
confirm in `evaluate` first.

## Adding repos / checks

`var.protected_repos` maps repo → required PR check contexts. ⚠ Only list checks that actually run on
`pull_request` — a required check that never reports leaves every PR un-mergeable. (e.g.
sleep-tracking's `build-image` runs on push only; its `ci` job runs on PRs.) The full-stack
confidence gate becomes a required check here once that workflow exists.

State is local + gitignored (`tofu/.gitignore`); `.terraform.lock.hcl` is committed (pinned provider).
