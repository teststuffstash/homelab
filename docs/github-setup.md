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

> **Permissions are DECLARED in [`docs/github-apps.yaml`](github-apps.yaml) (FU-098) — that file
> is the source of truth and the change flow** (PR it first with a `why` per permission → the
> github-exporter `GithubAppPermissionDrift` alert rings until the UI click + install approval
> land → clears). `scripts/github-apps.sh` is the outside-jail deep verify (report to /tmp); the always-current view is SERVED at
> the github-exporter `/apps` page (in-cluster `github-exporter.monitoring.svc:9504/apps`; humans port-forward). `devbox run github-apps-lint` (in ci) proves every mint
> site's request ⊆ the declaration. Creation is ONE script — `scripts/github-app-bootstrap.sh
> <slug> manifest|catch|convert` — whose manifest is built FROM the yaml (the six per-App
> scripts keep only their secrets/verify plumbing; their creation subcommands are retired stubs).

**The per-App detail lives in the yaml itself** (readable, whys inline) and the served `/apps` page (declared-vs-live, per poll) — no committed generated table.

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

> FU-017: if the two runner Apps can be merged into one, do it — both only need org self-hosted-runners R/W.

## 3. Tokens / PATs (none of the values live in git)

| Token | Type | Scope / can-do | Can't-do (the gaps that bite) | Where |
|---|---|---|---|---|
| **jail `GH_TOKEN`** | fine-grained PAT | push **code + workflows** to selected repos | **create repos** (org admin); **read Actions runs** (some endpoints 403); **read runner-groups** (403) | env + a credential helper (shipped 2026-07-15; clones use plain URLs) |
| **ghcr push** | **classic** PAT | `write:packages` → push images to ghcr | fine-grained PATs *cannot* touch ghcr | used at image-build time (CI) |
| **ghcr pull** | classic PAT | `read:packages` | — | Infisical `SLEEP_GHCR_PULL_TOKEN` → ESO → pod |
| **github-exporter** | fine-grained PAT | org **Administration: read** (the enhanced-billing usage endpoint — *not* "Plan", that's the pre-enhanced permission) + repo **Actions: read** / Metadata: read / **Issues: read** (FU-108 queue-liveness counts) on **All repositories** → the in-cluster GitHub poller (`argocd/resources/github-exporter/`): workflow-run conclusions + billing usage → Prometheus (alerts replace GitHub's failure emails) | expires (≤1y) — the `GithubExporterStale` alert is the rotation reminder. Deliberately a PAT, not an App: the billing endpoint wants an org-admin user token, which App installation tokens don't get | Infisical `GITHUB_EXPORTER_TOKEN` → ESO → `monitoring/github-exporter-token`; mint/rotate via `scripts/github-exporter-pat-bootstrap.sh` |

**Click-only:** minting the **ghcr classic PAT** (GitHub has no API to create classic PATs) and
the **github-exporter fine-grained PAT** (same — the bootstrap script drives the clicks).

## 4. Org Actions settings (Settings → Actions)

These are pure UI toggles — the source of several "queued forever / 403" mysteries:

- **Runner groups → Default → Repository access = All repositories**, **and** **"Allow public
  repositories" = ON.** The public toggle is *separate*; without it a **public** repo's jobs sit
  **queued with no runner pod** (this bit `openrouter-operator`). See the runner-bootstrap doc's note.
- **General → Fork pull request workflows from outside collaborators = "Require approval for all
  outside collaborators".** Because the self-hosted runners are inside the cluster, this stops a
  **fork PR** from running untrusted code on a homelab node without an explicit click.
- **Actions enabled** per repo (usually on by default; the bootstrap `access` step asserts it).
- **Org Actions secrets** — the only workflow-visible secrets the platform needs, `visibility = all` so
  every agent repo's workflow reads them. Used by the **updater** workflow (docs/agents/merge-path.md)
  (`update-pr-branch.yml`), which mints a **homelab-merge** App token so its branch-update push
  re-triggers CI (a bare `GITHUB_TOKEN` push would not):

  | secret | value |
  |---|---|
  | `MERGE_GH_APP_ID` | the `homelab-merge` App id — not sensitive (`~/.claude/homelab-github-merge/app-id`) |
  | `MERGE_GH_APP_PRIVATE_KEY` | the App private key — **durable source is Infisical** `MERGE_GH_APP_PRIVATE_KEY` (pushed by `github-app-bootstrap.sh homelab-merge`); local copy at `~/.claude/homelab-github-merge/private-key.pem` |

  **Managed as code** in [`tofu/github/actions_secrets.tf`](../tofu/github/actions_secrets.tf) (same root
  as the rulesets/repos/labels), and applied via **one wrapper** that loads the org admin token + both
  values — no growing checklist of `export`s:
  ```sh
  devbox run github-tofu plan     # then: devbox run github-tofu apply   (OUTSIDE the jail)
  ```
  `scripts/github-tf.sh` sources `TF_VAR_merge_gh_app_{id,private_key}` from the merge cred dir and
  `GITHUB_TOKEN` from the dedicated org-admin wallet (`~/Documents/homelab-admin.kdbx`, entry
  `github-homelab-admin`, keyfile `~/Documents/homelab-admin.keyx` — override via `GH_ADMIN_KP_DB`/`GH_ADMIN_KP_KEY`/`GH_ADMIN_KP_ENTRY`).
  This is the one spot the merge App key is
  deliberately *copied* out of Infisical into GitHub (Actions can't read Infisical). ⚠ The github
  provider stores the value in this root's **state** (local + gitignored) — a second at-rest copy of a
  Tier secret, kept minimal by using the dedicated least-privilege App; see the file header.

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
  too, but **not tofu's** — `labels.tf` was retired 2026-08-04 (FU-068); they are claim-owned
  (AgentStack `labels:` → IssueLabels, [`docs/agents/agentstack.md`](agents/agentstack.md)). The admin
  PAT still needs **Issues: R/W** for other repo state and **Organization → Secrets: R/W** for the
  `MERGE_GH_APP_*` org Actions secrets (`actions_secrets.tf`) — see the scope list in
  [`tofu/github/README.md`](../tofu/github/README.md).
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
   Infisical (`scripts/github-app-bootstrap.sh homelab-agents`, `scripts/github-app-bootstrap.sh homelab-reviewer`).
   Install each as **"Only select repositories"** and pick the agent repos — the install's repo scope
   is click-only (fine-grained PATs 403 on the `/user/installations` API; see §2).
8. **Branch protection** is code in [`tofu/github/`](../tofu/github/) (org ruleset targets `~ALL`, so
   future repos are auto-covered). For the agentic gate: add the repo to `var.protected_repos` (with its
   PR `ci` check) and a per-repo `pull_request` approval rule in `repo_rulesets.tf`, then
   `tofu -chdir=tofu/github apply` outside the jail. Per-repo **auto-merge + auto-delete-branch** and the
   agent **labels** are claim-owned (AgentStack `labels:` → IssueLabels; `labels.tf` retired
   2026-08-04, FU-068).
9. Per package pulled by an **offline device**: flip its **visibility → Public** (private by default,
   even under a public repo).

## Parallel non-GitHub "clicks" (cross-ref)

Not GitHub, but same class of unavoidable manual step: the **OpenRouter provisioning key** (Settings
→ Provisioning Keys → create) feeding the Crossplane key-minting (see `docs/agents/` + the OpenRouter
key Workspace). Tracked here so the full "manual bootstrap" surface is in one place.

## ghcr — the one rule: pushes happen ONLY in Actions

**Decided 2026-07-24 (ADR-095; found via the corpus pipeline):** no in-cluster workload ever
holds a GitHub registry credential. Structural reasons: fine-grained PATs cannot carry the
packages scope at all, so an in-cluster pusher needs a broad classic PAT (`write:packages` = every
package in the org) parked in a workload namespace with manual rotation — while every Actions
workflow gets `GITHUB_TOKEN` with repo-scoped `packages: write` free, auto-rotated. The split:

- **In-cluster** (Argo steps, jobs): build artifacts **into Garage** by reference (OCI archives,
  charts, whatever) — never talk to ghcr.
- **Actions** (ARC runner = LAN to Garage): thin *release* workflows fetch the artifact, verify
  its digest, and promote to ghcr with `GITHUB_TOKEN`. First instance:
  oracle-fleet `.github/workflows/release-corpus.yaml`.

**Garage-read secrets for release workflows** (repo Actions secrets, e.g. oracle-fleet
`ERT_S3_READER_*`): set imperatively from the cluster-minted key — the value's source of truth is
the Crossplane Workspace connection secret, NOT KeePass/tofu (codifying the value into
`tofu/github` would give it a second home; this crosses the cluster↔GitHub barrier by design).
Set/rotate (repo admin, e.g. from the host):

```sh
kubectl get secret ert-snapshots-s3 -n oracle-fleet -o jsonpath='{.data.reader_access_key_id}' \
  | base64 -d | gh secret set ERT_S3_READER_ACCESS_KEY_ID -R teststuffstash/oracle-fleet
# …and the same for reader_secret_access_key → ERT_S3_READER_SECRET_ACCESS_KEY
```

The jail PAT deliberately lacks the Secrets permission (verified 403 again 2026-08-04, on both
`actions/secrets` and `actions/secrets/public-key` — the write path) — setting these is an operator
action, once per stack that grows a release or specs-publish workflow.

⚠ **Pick the right key of the pair.** A Crossplane connection secret carries BOTH
`reader_*` and `writer_*` credentials. oracle-fleet's `ERT_S3_READER_*` reads, so it takes the
reader pair; a **specs-publish** workflow uploads, so it takes `writer_access_key_id` /
`writer_secret_access_key`. The reader pair authenticates fine and then 403s on PUT.

⚠ **The failure mode is silence.** `specs-publish.sh` soft-skips when the credentials are absent
(`no S3 credentials in env — skipping`), so a stack whose secrets were never set has **green CI and
an empty site**. `devbox run stack-lint <stack>`'s **WEB-03** probes the *served* site rather than
the secrets (which the lint cannot read either) exactly to catch that; WEB-01/02 cover the homelab
wildcard half. `devbox run new-stack` prints the whole three-part sequence as step G.
