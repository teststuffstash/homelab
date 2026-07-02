# GitHub org setup — the manual "required clicks"

Inventory of the **`teststuffstash` GitHub org** setup that **can't be (fully) automated** — the
click-only bits GitHub has no API for, plus the apps/tokens/settings the homelab depends on. Keep
this current; it's the map for recreating the org or onboarding a new repo. The *runner* bootstrap
flow (App create → install → secrets) lives in [`github-runner-bootstrap.md`](github-runner-bootstrap.md);
this is the broader catalog.

> **No secret values here** — this file is in the public homelab repo. App IDs / installation IDs
> are not secrets; PAT/key *values* live only in KeePass/Infisical (see [`secrets.md`](secrets.md)).

## 1. The org

- **`teststuffstash`** — owns the platform repos (`homelab`, `sleep-tracking`, `snore-recorder`,
  `openrouter-operator`, …). Personal repos live under `RasmusSoot`.
- **Click-only:** creating the org; adding owners. (GitHub has no org-create API.)

## 2. GitHub Apps installed on the org

| App | Purpose | Permissions | Repo access | IDs |
|---|---|---|---|---|
| **homelab-arc-…** | the in-cluster **Actions Runner Controller** registers the org-level `homelab-ephemeral` scale set as this App | Org → *Self-hosted runners: R/W*; Metadata: read | **All repositories** + **Allow public repositories** | install `142353606` |
| **homelab-runner-registrar** | the Proxmox **CI-runner VM** (ADR-082) mints its own Actions registration tokens at boot | Org → *Self-hosted runners: R/W* | (as installed) | App `4141567`, install `142515626` |
| **homelab-agents** | mints the worker + coordinator git tokens (clone/push/PR, label issues, merge) — `homelab-agents[bot]`, the PR **author** | Repo → Contents: R/W, Pull requests: R/W, Issues: R/W; Metadata: read | the agent repos | App `4150968`, install `142724430` — `scripts/github-agents-app-bootstrap.sh` |
| **homelab-reviewer** | the review bot's identity — `homelab-reviewer[bot]` submits `--approve`/`--request-changes` on the worker's PR. **Distinct App on purpose**: GitHub blocks self-approval, so the reviewer must not be the PR author | Repo → Contents: **R/W** (required so the approval *counts* — GitHub only counts reviews from a repo writer; contents:read ⇒ authorAssociation NONE, ignored), Pull requests: R/W; Metadata: read (no manual merge — auto-merge does that) | the agent repos | `scripts/github-reviewer-app-bootstrap.sh` → `agents/coordinator/reviewer-git.yaml` |

**Click-only (per the runner bootstrap doc):** *creating* an App (driven to a single Create via the
App-manifest REST flow), **Installing** it on the org, generating its **private key**. The private
keys live out-of-repo (KeePass/Infisical / `~/.claude/homelab-runner-app/`).

**Also click-only: an App installation's repository selection** (Settings → Installed GitHub Apps →
Configure → Repository access). Tempting to codify — `tofu`'s `github_app_installation_repositories`
exists — but it mutates via `PUT /user/installations/{id}/repositories/{repo_id}`, a **user-to-server**
endpoint that requires a **user OAuth access token from the App's authorization flow** (the install's
repo scope is controlled by the org owner who installed it, not by the App). A **fine-grained PAT is
refused** there (`403 Resource not accessible by personal access token`), and `tofu/github/` is
deliberately fine-grained-PAT-only — so this stays a click. Install each agent App as **"Only select
repositories"** and pick the agent repos (tried the tofu route 2026-07-01; removed).

> If the two runner Apps can be merged into one, do it — both only need org self-hosted-runners R/W.

## 3. Tokens / PATs (none of the values live in git)

| Token | Type | Scope / can-do | Can't-do (the gaps that bite) | Where |
|---|---|---|---|---|
| **jail `GH_TOKEN`** | fine-grained PAT | push **code + workflows** to selected repos | **create repos** (org admin); **read Actions runs** (some endpoints 403); **read runner-groups** (403) | env + embedded in git remotes ⚠️ (move to a credential helper — see follow-ups) |
| **ghcr push** | **classic** PAT | `write:packages` → push images to ghcr | fine-grained PATs *cannot* touch ghcr | used at image-build time (CI) |
| **ghcr pull** | classic PAT | `read:packages` | — | Infisical `SLEEP_GHCR_PULL_TOKEN` → ESO → pod |

**Click-only:** minting the **ghcr classic PAT** (GitHub has no API to create classic PATs).

## 4. Org Actions settings (Settings → Actions)

These are pure UI toggles — the source of several "queued forever / 403" mysteries:

- **Runner groups → Default → Repository access = All repositories**, **and** **"Allow public
  repositories" = ON.** The public toggle is *separate*; without it a **public** repo's jobs sit
  **queued with no runner pod** (this bit `openrouter-operator`). See the runner-bootstrap doc's note.
- **General → Fork pull request workflows from outside collaborators = "Require approval for all
  outside collaborators".** Because the self-hosted runners are inside the cluster, this stops a
  **fork PR** from running untrusted code on a homelab node without an explicit click.
- **Actions enabled** per repo (usually on by default; the bootstrap `access` step asserts it).

## 5. Per-repo settings

- **Actions enabled** (above).
- **Branch protection on `master`** — **managed as code in [`tofu/github/`](../tofu/github/)** (rulesets
  via the `integrations/github` provider; separate root/state like `tofu/cloudflare/`). Org structural
  (`org_ruleset.tf`: `default-branch-protection`, `~ALL` repos, PR required + block force-push/deletion,
  OrganizationAdmin bypass) + per-repo required checks (`repo_rulesets.tf`, driven by
  `var.protected_repos`). New repos are covered by the `~ALL` org ruleset automatically. To change it,
  edit the tofu and `tofu -chdir=tofu/github apply` **outside the jail** with a fine-grained admin PAT
  (see that README) — never via `gh api`, which drifts and is reverted on the next apply. The org
  ruleset intentionally sets `required_approving_review_count = 0`; the reviewer-approval gate for the
  agentic auto-merge model is a **per-repo** `pull_request` rule in `repo_rulesets.tf` (ADR-079).
- **Allow auto-merge + Automatically delete head branches** — the repos are now **fully managed** in
  [`tofu/github/repos.tf`](../tofu/github/repos.tf) (`github_repository`, every writable attribute
  declared, adopted via `import` blocks). Auto-merge completes the PR once the ruleset's requirements
  (approval + CI) are met; auto-delete cleans up the worker's branch. The agent state labels are code
  too, in [`tofu/github/labels.tf`](../tofu/github/labels.tf). The admin PAT needs **Issues: R/W** for
  the labels (they're under Issues, not Administration).
- **Default runner** — repos using homelab CI set `runs-on: homelab-ephemeral`; the rest use
  `ubuntu-latest`.
- **Package visibility** — a ghcr package is **private by default**, inheriting nothing from a public
  repo. A package pulled by an in-cluster pod uses a `read:packages` PAT (ESO), so it can stay private;
  but one pulled by an **offline/roaming device** (e.g. the `snore-recorder` Pi, anonymous `docker
  compose pull`) must be **Public**, else the pull 401s `unauthorized`. Click-only: *Packages → `<pkg>`
  → Package settings → Danger Zone → Change visibility → Public*. There's no API on the jail PAT for it
  (`403`). `snore-recorder` is public for this reason; the ansible role's `registry_token` path is the
  keep-private alternative.

## 6. The click-only checklist (recreating from scratch)

1. Create the **org**; add owners.
2. Create + **install** the **ARC App** (manifest flow) → its key → `secrets` step.
3. Mint the **ghcr classic PAT** (`write:packages`).
4. Create + install the **runner-registrar App** (ADR-082) → private key → Infisical.
5. Runner group **Default**: All repositories **+ Allow public repositories**.
6. **Fork-PR approval** = require approval for outside collaborators.
7. Create + install the **homelab-agents** and **homelab-reviewer** Apps (manifest flow) → keys →
   Infisical (`scripts/github-agents-app-bootstrap.sh`, `scripts/github-reviewer-app-bootstrap.sh`).
   Install each as **"Only select repositories"** and pick the agent repos — the install's repo scope
   is click-only (fine-grained PATs 403 on the `/user/installations` API; see §2).
8. **Branch protection** is code in [`tofu/github/`](../tofu/github/) (org ruleset targets `~ALL`, so
   future repos are auto-covered). For the agentic gate: add the repo to `var.protected_repos` (with its
   PR `ci` check) and a per-repo `pull_request` approval rule in `repo_rulesets.tf`, then
   `tofu -chdir=tofu/github apply` outside the jail. Per-repo **auto-merge + auto-delete-branch** and the
   agent **labels** are now code too (`repos.tf` import blocks, `labels.tf`) — same apply.
9. Per package pulled by an **offline device**: flip its **visibility → Public** (private by default,
   even under a public repo).

## Parallel non-GitHub "clicks" (cross-ref)

Not GitHub, but same class of unavoidable manual step: the **OpenRouter provisioning key** (Settings
→ Provisioning Keys → create) feeding the Crossplane key-minting (see `docs/agents/` + the OpenRouter
key Workspace). Tracked here so the full "manual bootstrap" surface is in one place.
