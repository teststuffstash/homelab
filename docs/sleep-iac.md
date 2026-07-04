# sleep-iac — extracting the sleep stack into its own IaC repo (plan)

_Planning record, 2026-07-02 (rev. 2026-07-03: Grafana dashboard migration + platform-precreated
namespaces; rev. 2026-07-04: **sleep-iac is public** — no ArgoCD repo credential). Executes
**FU-025** (deploy-versioning + repo-structure rework); doctrine in
[`patterns/app-owned-resources.md`](patterns/app-owned-resources.md) §"Direction"._

> **Status (2026-07-04): LIVE through step 4.** The public `sleep-iac` repo is seeded (CI green), the
> `sleep` AppProject + precreated namespaces are applied, and the root `sleep` Application is flipped
> to `sleep-iac//apps` — all three child apps Synced/Healthy on `project: sleep`, Workspaces adopted
> (no prune/recreate). **Remaining:** step 5's app-repo cleanup (empty `sleep-tracking/infra/` +
> `snore-recorder/infra/` to a README pointer; update `agent-session.sh` to apply `agent/` from
> sleep-iac; drop the unused `repo-sleep-tracking-github` credential), the standalone Grafana
> dashboard→GitOps slice, and coordinator step-7a automation. FU-025 stays open until those land.

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
