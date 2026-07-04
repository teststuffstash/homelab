# sleep-iac — extracting the sleep stack into its own IaC repo (plan)

_Planning record, 2026-07-02 (rev. 2026-07-03: Grafana dashboard migration + platform-precreated
namespaces; rev. 2026-07-04: **sleep-iac is public** — no ArgoCD repo credential). Executes
**FU-025** (deploy-versioning + repo-structure rework); doctrine in
[`patterns/app-owned-resources.md`](patterns/app-owned-resources.md) §"Direction"._

> **Status (2026-07-04): LIVE — steps 1–5 done + dashboard migrated.** The public `sleep-iac` repo is
> seeded (CI green); the `sleep` AppProject + precreated namespaces are applied; the root `sleep`
> Application is flipped to `sleep-iac//apps` (all three children Synced/Healthy on `project: sleep`,
> Workspaces adopted, no prune). Cleanup done: `argocd/sleep/` deleted; both app repos' `infra/`
> emptied to README pointers (pure artifact producers); `agent-session.sh`/bootstrap refs repointed to
> `sleep-iac`; the unused `repo-sleep-tracking-github` credential removed; the **Sleep Overview
> dashboard moved to GitOps** (`sleep-tracking/` kustomize `configMapGenerator`; tofu CM +
> `tofu/dashboards/sleep-overview.json` removed; Grafana provisions it from the sleep-tracking ns).
> **Remaining (FU-025 stays open):** coordinator step-7a automation (flag-and-stop → version-bump PR in
> sleep-iac) and enabling Renovate on the repo (FU-014). Op note: the Grafana k8s-sidecar
> (`UNIQUE_FILENAMES=false`) only writes on CM watch events, so removing one of two same-key dashboard
> CMs needs a MODIFY event / grafana restart on the survivor to rewrite the file.

## Goal

Three layers, so app repos know nothing about homelab and a deploy is a reviewable PR:

- **App repos** (sleep-tracking, snore-recorder): code + chart only. Publish an image + OCI chart
  to ghcr on a `v*` tag. Standard Kubernetes; zero homelab knowledge.
- **`sleep-iac`** (new): the stack's deployment truth — ArgoCD child Applications + values +
  version pins **+ the apps' infra CRs** (Garage Workspaces, ExternalSecrets, OpenRouterKeys,
  agent git-token). Own CI gates; **a deploy = a version-bump PR here** (Renovate FU-014 and the
  coordinator's step-7a automation both plug in at this seam).
- **homelab**: the platform — operators, SERVICES.md, the `sleep` **AppProject** (tenancy
  boundary), and one root Application pointing at sleep-iac. **sleep-iac is public** (it's
  deployment config with no secret material — the CRs carry Garage *key ids* and Infisical
  *references*, never secret values), so ArgoCD reads it anonymously: no repo credential.

## Current state (what moves)

| Today | Moves to |
|---|---|
| homelab `argocd/sleep/{sleep-tracking,snore-recorder,sleep-ingester}.yaml` | `sleep-iac/apps/` |
| homelab `argocd/sleep/values/sleep-ingester.yaml` | `sleep-iac/values/` |
| `sleep-tracking/infra/` (garage-workspace, externalsecret, openrouter-key, `agent/*`) | `sleep-iac/sleep-tracking/` |
| `snore-recorder/infra/` (garage-workspace) | `sleep-iac/snore-recorder/` |
| homelab `tofu/monitoring.tf` `sleep_dashboard` CM (`tofu/dashboards/sleep-overview.json`) | `sleep-iac/sleep-tracking/` — a `grafana_dashboard`-labelled CM in the **sleep-tracking** namespace (see §"Grafana dashboard migration") |
| root `sleep` Application source = homelab `argocd/sleep` (tofu/argocd.tf) | repoURL → sleep-iac |

Notable: today the child Applications for the infra CRs point **directly at the app repos'
`infra/`** (that's the residual homelab knowledge in the app repos). After the move they point at
sleep-iac paths, and the app repos' `infra/` dirs empty down to a README pointer.

The **sleep dashboard is the one piece not in today's ArgoCD sleep stack** — it's a homelab/tofu
ConfigMap in the `monitoring` namespace, so a fix means `tofu apply`, not a PR. Moving it into the
GitOps'd stack is what actually gives dashboard fixes an auto-deploy path (§"Grafana dashboard
migration"). This slice is **independent of the repo extraction** — the dashboard CM can move into
the sleep stack (via today's `sleep-tracking/infra/` app-repo path) before sleep-iac exists, then
ride along into `sleep-iac/sleep-tracking/` with the rest.

## Target sleep-iac layout

```
sleep-iac/
  apps/                      # child Applications (the app-of-apps content)
    sleep-tracking.yaml      #   wave 0 — infra CRs, source = THIS repo, path sleep-tracking/
    sleep-ingester.yaml      #   wave 1 — OCI chart ghcr.io/teststuffstash/charts@<pin>,
    snore-recorder.yaml      #            $values ref → THIS repo (not homelab!)
  values/sleep-ingester.yaml # image tag + chart config (the version pins live here)
  sleep-tracking/            # the CRs formerly in sleep-tracking/infra/
    dashboard-sleep-overview.yaml  #   grafana_dashboard-labelled CM (was tofu/monitoring.tf)
    sleep-overview.json            #   the dashboard body (was tofu/dashboards/)
  snore-recorder/            # the CRs formerly in snore-recorder/infra/
  devbox.json                # ci seam: yamllint + kubeconform + helm-template-with-pinned-values
  .github/workflows/ci.yaml  # thin: devbox run ci; runs-on homelab-ephemeral
  renovate.json              # watches the ghcr chart/image pins (FU-014)
```

## Grafana dashboard migration

Today the Sleep Overview dashboard is a homelab-owned `kubernetes_config_map "sleep_dashboard"`
(`tofu/monitoring.tf`) in the **monitoring** namespace, body from `tofu/dashboards/sleep-overview.json`.
It is *not* part of the ArgoCD sleep stack, so a fix means a `tofu apply` against the platform — which
is exactly why an old, buggy dashboard lingers instead of shipping like app code.

**The move works because the Grafana dashboard sidecar discovers dashboards by label across ALL
namespaces** (`monitoring.tf`: `sidecar.dashboards.searchNamespace = "ALL"`, `label = grafana_dashboard`).
So the dashboard ConfigMap does **not** have to live next to Grafana:

- **Moves to GitOps:** the dashboard CM (labelled `grafana_dashboard: "1"`) + its JSON body → the
  **`sleep-tracking` namespace**, deployed by ArgoCD from `sleep-iac/sleep-tracking/`. The sidecar
  auto-discovers it. A dashboard fix becomes a PR ArgoCD syncs — no `tofu apply`.
- **Stays in homelab (platform-owned):** the frser SQLite **datasource** (`sleep-notes`), the
  **`sleep-sqlite-sync` sidecar** (pulls `sleep-db/sleep.sqlite` from Garage), and the
  **`sleep-db-reader` ExternalSecret** are baked into the Grafana Helm release + the `monitoring`
  namespace. They're Grafana-deployment infra — rarely change, not per-fix — so they stay in
  `tofu/monitoring.tf`.

Only the **dashboard body** (the part that actually gets edited) leaves tofu; the plumbing stays.
**Contract between the two layers:** the dashboard's panels must keep targeting datasource **uid
`sleep-notes`** — that uid is the stable platform interface the GitOps dashboard depends on.

This slice is prune-safe and **standalone** (doesn't need sleep-iac to exist yet — it can land via
today's `sleep-tracking/infra/` app-repo path, then move into `sleep-iac/sleep-tracking/` later):
add the GitOps CM, confirm Grafana renders the dashboard (it carries the same dashboard `uid`, so the
transient overlap with the tofu copy is cosmetic — one provisioning source wins, identical render,
no downtime; it's a read-only view over sleep.sqlite), **then** delete `sleep_dashboard` +
`tofu/dashboards/sleep-overview.json` from homelab and `tofu apply`.

## The AppProject (platform-owned, stays in homelab)

**Sleep is its own ArgoCD `AppProject` (`sleep`)** — the tenancy boundary — replacing `default`.
Every child Application sets `project: sleep`. Defined platform-side next to the root apps
(tofu/argocd.tf or `argocd/platform/`):

- **sourceRepos:** the sleep-iac repo + `ghcr.io/teststuffstash/charts` (OCI). Nothing else — the
  app repos stop being ArgoCD sources entirely.
- **destinations:** allowlist exactly the namespaces the stack requires — `sleep-tracking` and
  `snore-recorder`, in-cluster only. The dashboard CM lands in `sleep-tracking` (§"Grafana dashboard
  migration"), so the project needs **no** destination in `monitoring` — the tenant never writes to
  the platform's monitoring namespace.
- **Namespaces are platform-precreated, not tenant-created.** homelab owns namespace lifecycle (a
  `kubernetes_namespace` per required ns in tofu, or an `argocd/platform/` app) and the AppProject
  only *allowlists* them as destinations; child Applications run with `CreateNamespace=false`. This
  lets us **drop `Namespace` from `clusterResourceWhitelist`** — the sleep project then cannot spawn
  arbitrary namespaces (tighter than `CreateNamespace=true`), which is the whole point of a tenancy
  boundary. Precreate the required set up front so a first sync doesn't fail on a missing ns.
- **clusterResourceWhitelist:** just the Crossplane `Workspace` GVK — it is cluster-scoped
  (`kubectl get workspace`, no `-n`). Everything else namespaced-only. (With precreated namespaces,
  `Namespace` is intentionally *not* whitelisted here — see above.) This is what makes homelab behave
  like a real platform.

## Migration sequence (prune-safe, zero-downtime)

Resource ownership follows the **Application name**, not the source repo — keep the names
(`sleep-tracking`, `snore-recorder`, `sleep-ingester`) and nothing gets pruned/recreated when the
sources flip. The Workspaces additionally carry `deletionPolicy: Orphan` (belt + suspenders for
the data buckets).

1. **Create the repo as code** — add `sleep-iac` to `tofu/github/repos.tf` + `protected_repos`
   (required check: `ci`) + the agent labels; apply outside the jail (admin PAT). Install the
   `homelab-agents` + `homelab-reviewer` Apps on it (click-only repo picker, `docs/github-setup.md`).
2. **Seed content** — copy the five manifests + values + both `infra/` dirs into the layout above,
   **plus the dashboard CM + `sleep-overview.json`** into `sleep-tracking/` (§"Grafana dashboard
   migration"); rewrite the three child Applications: `project: sleep`, sources → sleep-iac paths,
   and sleep-ingester's `$values` ref → sleep-iac.
3. **Platform side (homelab PR)** — add the `sleep` AppProject; **precreate the `sleep-tracking` +
   `snore-recorder` namespaces** (platform-owned, `CreateNamespace=false` on the children); flip the
   root `sleep` Application's `repoURL`/`path` to sleep-iac. **No repo credential** — sleep-iac is
   public, ArgoCD reads it anonymously. (The now-unused `repo-sleep-tracking-github` credential
   becomes removable: after the extraction ArgoCD no longer reads the private app repos.)
4. **Apply + verify** — `tofu apply` (targeted: `helm_release.argocd_apps`);
   all three child apps Synced/Healthy, **no prune events**, Workspaces still `Synced/Ready`
   (adopted, not recreated), a manual ingester CronJob run green, and **Grafana renders Sleep
   Overview from the GitOps CM** (still bound to datasource uid `sleep-notes`).
5. **Clean up** — delete homelab `argocd/sleep/`; **delete the tofu `sleep_dashboard` CM +
   `tofu/dashboards/sleep-overview.json` and `tofu apply`** (leave the datasource + sqlite-sync
   sidecar + `sleep-db-reader` — platform-owned); empty both app repos' `infra/` to a README pointer
   ("deployment + infra CRs live in sleep-iac"); update `argocd/README.md`, the pattern doc ("today
   argocd/sleep plays the role" note), SERVICES.md ArgoCD row if worded around it.
6. **Wire the gates** — Renovate on sleep-iac (chart `targetRevision` + image `tag` pins → bump
   PRs); the reviewer/auto-merge gate applies as on the app repos. Later the full-stack k3d gate
   (ADR-082) becomes a required check here — that's the "deploy verify" of agent P2.

## Deploy pipeline (build → PR → sync)

**Built 2026-07-04.** How a code change reaches the cluster, and why it carries almost no ceremony.

**Model — the chart is the deployable unit; sleep-iac pins one number.** The `deploy` workflow in
the app repo builds the image **and** packages the chart at **one version** — CalVer + git sha,
`2026.<m>.<d>-g<sha>` (commit date, reproducible; the `-g` prefix dodges SemVer's "no all-numeric
prerelease" rule) — with `chart version == appVersion == image tag`. The chart's
`values.yaml` leaves `image.tag: ""`, and `templates/cronjob.yaml` defaults the tag to
`.Chart.AppVersion`, so **the deployed image is fully determined by the pinned chart version**.
sleep-iac therefore sets only `apps/sleep-ingester.yaml` `targetRevision` and never an image tag.
(OCI Helm requires a SemVer chart version — a bare git sha isn't legal — which is exactly why the
sha rides *inside* a CalVer as a prerelease.)

**Flow, from a PR merged to app-repo master:**

1. `deploy.yaml` (path-filtered: `src/ chart/ Dockerfile pyproject.toml uv.lock` — **docs-only pushes
   do nothing**) computes the version, builds+pushes `ghcr…/sleep-ingester:<ver>` and the chart
   `charts/sleep-ingester:<ver>`. One build on master is authoritative (squash-merge makes the master
   commit a new sha anyway, so there's nothing to "reuse" from PR CI).
2. `scripts/deploy-pin.sh` force-updates a **fixed branch** `deploy/sleep-ingester` in sleep-iac
   (reset onto master, bump the chart `targetRevision`) and upserts a PR. GitHub allows one open PR
   per head branch ⇒ **exactly one deploy PR per app**; a second build updates the same PR.
3. sleep-iac `ci` (render) + auto-merge land it; ArgoCD syncs → rollout. **Rollback / roll-forward =
   bump `targetRevision` to another published chart version** (a one-line revert of the PR).

**Concurrency / no-regression.** `deploy.yaml` sets `concurrency: { group: deploy-sleep-ingester,
cancel-in-progress: true }`, so the newest master commit wins (older runs cancel); master is linear,
so run-order == commit-order. `deploy-pin.sh` adds a **monotonic ancestor guard** (refuse to write a
pin whose current sha is not an ancestor of the new one — belt to cancel-in-progress; needs the
`fetch-depth: 0` checkout). ArgoCD is level-triggered, so back-to-back deploys just converge to the
latest; a skipped intermediate rollout is fine.

**Why not Renovate for this.** Git-sha versions don't order, so Renovate can't tell "newer" — the
app-repo build drives the bump PR instead. Renovate stays in its lane (app deps, platform charts).

**One-time setup (the only manual bits):**

- The **`homelab-deploy` GitHub App** — bootstrap with `scripts/github-deploy-app-bootstrap.sh`
  (sibling of the agents/reviewer/merge App scripts: `manifest`/`catch` → one Create click →
  `install` on **sleep-iac** → `secrets` → `devbox run github-tofu apply`). Minimal grant
  (`contents:write` + `pull_requests:write` on sleep-iac). The workflow mints a short-lived,
  sleep-iac-scoped token with `actions/create-github-app-token` — no static PAT. tofu then publishes
  `DEPLOY_APP_ID` + `DEPLOY_APP_PRIVATE_KEY` as org Actions secrets **scoped to sleep-tracking only**
  (`tofu/github/actions_secrets.tf`) — this key can deploy anything, so it's *not* readable by the
  whole org's CI plane.
  - *Owner question:* the App is org-owned (create needs an org owner once). To avoid the owner
    day-to-day, either delegate it to a non-owner "sleep admin" via **GitHub App managers**, or create
    it under a **machine-user account** (`OWNER_KIND=user`) — details in the script header. Create +
    first install-on-org-repo still need an owner once; ongoing use doesn't.
- The deploy PR is mechanical, so it's gated by **CI only, no review**: **sleep-iac has no
  `required-approval` ruleset** (`tofu/github`, `protected_repos["sleep-iac"].require_approval = false`)
  — only `required-checks` (`ci`). So once sleep-iac's `ci` is green on the tip, the `homelab-deploy`
  App merges the PR directly (`deploy-pin.sh` polls the commit's `ci` check-run, then `gh pr merge
  --squash`). **Why not a bypass:** GitHub's App (`Integration`) ruleset bypass does **not** waive the
  "required approvals" rule on a *merge* (only `OrganizationAdmin` does — verified live: the App's merge
  stayed `REVIEW_REQUIRED` despite the bypass). Dropping the approval requirement for sleep-iac — not
  bypassing it — is the correct fix, and matches "gate the bump with CI, not a review". GitHub auto-merge
  is likewise avoided (it doesn't fire deterministically); the workflow merges directly after CI.
- **ghcr retention can't be done in tofu** — GitHub has no retention API/resource for packages (unlike
  ECR lifecycle policies). It's a **scheduled cleanup workflow** instead:
  `sleep-tracking/.github/workflows/ghcr-cleanup.yaml` (monthly `snok/container-retention-policy`,
  keep-N-most-recent + a `cut-off`, `latest` skipped — tuned so the pinned tag is never pruned; run
  `workflow_dispatch` with `dry-run` first).

**Post-deploy health / auto-rollback** (watch ArgoCD app health, revert or dispatch a fixer on a
broken sync) is **FU-044** — deferred; harden app CI first so it's the safety net, not the control.

## Decisions to record when built

- **New ADR: three-layer repo topology** (app → stack-iac → platform), refining ADR-004/ADR-074 —
  the app still *owns* its resources, but the declarations live in the stack's iac repo, not the
  app repo (the app repo stays a pure artifact producer).
- Coordinator step 7a flips from "flag and stop" to: worker/Renovate opens the version-bump PR in
  sleep-iac → gates → auto-merge → ArgoCD syncs (`agents/coordinator/README.md`).
- **Dashboard body moves to GitOps** (`sleep-iac/sleep-tracking/`) while the datasource + sqlite-sync
  sidecar + reader secret stay platform-owned in `tofu/monitoring.tf`; datasource **uid `sleep-notes`**
  is the platform contract the GitOps dashboard binds to. Namespaces are **platform-precreated**, the
  `sleep` AppProject only allowlists them (`CreateNamespace=false`, no `Namespace` in the cluster
  whitelist).
- FU-025 closes; the repo-creation part of **FU-039** gets its first data point (was the
  tofu/github seam painful enough to want a Crossplane GitHub provider?).

## Risks / gotchas

- **Don't rename Applications** (ownership/prune) and don't run step 3 before step 2 is merged —
  the root app would sync an empty repo and prune the stack. Order: content first, flip second.
- **AppProject too tight fails quietly-ish**: a blocked resource shows as a sync error on the
  child app — expect one iteration on the whitelist (the Workspace GVK, ESO kinds are namespaced
  and fine).
- sleep-iac is **public** (deployment config with no secret values) → ArgoCD reads it with no repo
  credential. Nothing to seed before the flip; still verify the source with a manual hard-refresh of
  the root app after flipping `repoURL`.
- The `$values` multi-source ref must move off homelab in the same step as the child app —
  otherwise sleep-ingester still reads values from homelab and the extraction is cosmetic.
- **Dashboard datasource uid must not drift:** the GitOps dashboard binds to uid `sleep-notes`,
  provisioned by the Grafana Helm values in `tofu/monitoring.tf`. If that uid ever changes on the
  platform side, the dashboard's panels break — keep the two in lockstep. Add the GitOps CM before
  removing the tofu one (brief same-uid overlap is cosmetic; the reverse leaves a gap).
