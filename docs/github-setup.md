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

**Click-only (per the runner bootstrap doc):** *creating* an App (driven to a single Create via the
App-manifest REST flow), **Installing** it on the org, generating its **private key**. The private
keys live out-of-repo (KeePass/Infisical / `~/.claude/homelab-runner-app/`).

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
- **Branch protection on `master`** — *not yet set; needed for the agentic auto-merge model*
  (required status checks + the reviewer approval before merge; ADR-079). Click-only / API via the
  branch-protection endpoint.
- **Default runner** — repos using homelab CI set `runs-on: homelab-ephemeral`; the rest use
  `ubuntu-latest`.

## 6. The click-only checklist (recreating from scratch)

1. Create the **org**; add owners.
2. Create + **install** the **ARC App** (manifest flow) → its key → `secrets` step.
3. Mint the **ghcr classic PAT** (`write:packages`).
4. Create + install the **runner-registrar App** (ADR-082) → private key → Infisical.
5. Runner group **Default**: All repositories **+ Allow public repositories**.
6. **Fork-PR approval** = require approval for outside collaborators.
7. Per new repo: confirm Actions on; add to nothing else (org-level App + group cover it); set
   branch protection when the repo joins the auto-merge flow.

## Parallel non-GitHub "clicks" (cross-ref)

Not GitHub, but same class of unavoidable manual step: the **OpenRouter provisioning key** (Settings
→ Provisioning Keys → create) feeding the Crossplane key-minting (see `docs/agents/` + the OpenRouter
key Workspace). Tracked here so the full "manual bootstrap" surface is in one place.
