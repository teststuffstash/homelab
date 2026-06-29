# tofu/github — branch protection as code (GitHub rulesets)

Separate OpenTofu root (own local state, like `tofu/cloudflare/`) that manages **branch protection**
for the org via **rulesets** — the "suspenders" of the agent platform: agents can push an `agent/…`
branch and open a PR, but **cannot reach a default branch** (homelab ADR-079/081, `docs/agents/`).

Two layers (per the chosen design):
- **Org structural** (`org_ruleset.tf`, `github_organization_ruleset`, all repos): require a PR, block
  force-push + default-branch deletion. **Org admins bypass** (you keep direct-to-master IaC); the
  **agents App is not in the bypass list**, so its `contents:write` still can't reach master.
- **Per-repo required checks** (`repo_rulesets.tf`, `github_repository_ruleset`): each agent-target
  repo requires its PR-triggered CI checks (+ up-to-date branch) before merge. **Org admins bypass
  here too** (same `OrganizationAdmin` actor as the org ruleset) — without it a required check, which
  only reports on a PR, blocks even the owner's direct-to-master since a bare push has no check run.
  The agents App is still not a bypass actor, so its PRs must go green.

## Plan requirement (GitHub Team)

⚠ **Rulesets on _private_ repos — and _org-level_ rulesets at all — require a paid plan.** On the
free plan an org ruleset `POST` returns `404` and a private-repo ruleset `POST` returns
`403 Upgrade to GitHub Pro or make this repository public`. `teststuffstash` is therefore on
**GitHub Team** (org owner: Settings → Billing → Upgrade). With Team this root applies unchanged;
nothing here needs editing for the plan.

## Run it (OUTSIDE the jail)

Rulesets need **Administration: write** at two levels: **Organization** (for the org ruleset) and
**Repository** (for the per-repo rulesets). The jail PAT deliberately lacks both.

**Use a fine-grained PAT, not `gh auth token`.** `gh auth token` only carries `read:org`, so the
org-ruleset endpoint returns `404` (GitHub hides unauthorized endpoints as 404, not 403). The obvious
fix — `gh auth refresh -s admin:org` — grants org-admin across **every** org you belong to (classic
scopes are global). A **fine-grained PAT is scoped to one resource owner**, so it can touch only this
org. Mint one (github.com → Settings → Developer settings → Fine-grained tokens) as a `teststuffstash`
owner:

- **Resource owner:** `teststuffstash`  ← the single-org scoping; the token can reach nothing else
- **Repository access:** All repositories (or just the agent-target repos)
- **Organization permissions → Administration: Read and write**  ← unblocks the org ruleset
- **Repository permissions → Administration: Read and write**  ← for the per-repo rulesets

If the org enforces PAT approval the token sits "pending"; approve it yourself as owner. Then:

```sh
export GITHUB_TOKEN=github_pat_xxxxx            # the fine-grained token (NOT gh auth token)
devbox run -- tofu -chdir=tofu/github init
devbox run -- tofu -chdir=tofu/github plan      # review
devbox run -- tofu -chdir=tofu/github apply
```

## Safe rollout (important — no dry-run on Team)

⚠ **`evaluate` mode AND ruleset Insights are both GitHub Enterprise-only.** The API accepts
`enforcement="evaluate"` on Team, but the ruleset is then **inert and uninspectable** — it looks
protected and isn't. On Team the only meaningful values are **`active`** and **`disabled`**; there is
no dry-run to observe first.

**`enforcement` defaults to `active`** — protection is this root's whole purpose, so a bare `apply`
keeps it on; you never need a flag to stay protected, and you can't disable it by forgetting one.
`disabled` is a deliberate, explicit rollback. The admin bypass is already verified live (a direct
owner push returns `remote: Bypassed rule violations …` and succeeds), on both the org structural
ruleset and the per-repo required-checks ruleset.

```sh
# normal apply — stays active (no flag needed)
devbox run -- tofu -chdir=tofu/github apply

# re-confirm YOUR bypass any time (non-destructive): rules applying to you on a default branch.
# Empty [] = you bypass (good). A pull_request rule object = you are blocked (bypass broken).
gh api repos/teststuffstash/agent-runtime/rules/branches/master

# deliberate rollback (turns protection OFF on every repo — explicit only):
devbox run -- tofu -chdir=tofu/github apply -var enforcement=disabled
```

The bypass is evaluated on the **pushing identity**, not the token's scopes: your pushes (PAT or local
git, both authored as the org owner) bypass; the **agents App** pushes as a Bot that is *not* in
`bypass_actors`, so its `contents:write` still can't reach a default branch. That asymmetry is the
whole point.

## Adding repos / checks

`var.protected_repos` maps repo → required PR check contexts. ⚠ Only list checks that actually run on
`pull_request` — a required check that never reports leaves every PR un-mergeable. (e.g.
sleep-tracking's `build-image` runs on push only; its `ci` job runs on PRs.) The full-stack
confidence gate becomes a required check here once that workflow exists.

State is local + gitignored (`tofu/.gitignore`); `.terraform.lock.hcl` is committed (pinned provider).
