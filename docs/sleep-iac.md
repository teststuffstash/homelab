# sleep-iac — extracting the sleep stack into its own IaC repo (plan)

_Planning record, 2026-07-02. Executes **FU-025** (deploy-versioning + repo-structure rework);
doctrine in [`patterns/app-owned-resources.md`](patterns/app-owned-resources.md) §"Direction".
Not started — this doc is the blueprint for the session that builds it._

## Goal

Three layers, so app repos know nothing about homelab and a deploy is a reviewable PR:

- **App repos** (sleep-tracking, snore-recorder): code + chart only. Publish an image + OCI chart
  to ghcr on a `v*` tag. Standard Kubernetes; zero homelab knowledge.
- **`sleep-iac`** (new): the stack's deployment truth — ArgoCD child Applications + values +
  version pins **+ the apps' infra CRs** (Garage Workspaces, ExternalSecrets, OpenRouterKeys,
  agent git-token). Own CI gates; **a deploy = a version-bump PR here** (Renovate FU-014 and the
  coordinator's step-7a automation both plug in at this seam).
- **homelab**: the platform — operators, SERVICES.md, the `sleep` **AppProject** (tenancy
  boundary), one root Application pointing at sleep-iac, and the repo credential.

## Current state (what moves)

| Today | Moves to |
|---|---|
| homelab `argocd/sleep/{sleep-tracking,snore-recorder,sleep-ingester}.yaml` | `sleep-iac/apps/` |
| homelab `argocd/sleep/values/sleep-ingester.yaml` | `sleep-iac/values/` |
| `sleep-tracking/infra/` (garage-workspace, externalsecret, openrouter-key, `agent/*`) | `sleep-iac/sleep-tracking/` |
| `snore-recorder/infra/` (garage-workspace) | `sleep-iac/snore-recorder/` |
| root `sleep` Application source = homelab `argocd/sleep` (tofu/argocd.tf) | repoURL → sleep-iac |

Notable: today the child Applications for the infra CRs point **directly at the app repos'
`infra/`** (that's the residual homelab knowledge in the app repos). After the move they point at
sleep-iac paths, and the app repos' `infra/` dirs empty down to a README pointer.

## Target sleep-iac layout

```
sleep-iac/
  apps/                      # child Applications (the app-of-apps content)
    sleep-tracking.yaml      #   wave 0 — infra CRs, source = THIS repo, path sleep-tracking/
    sleep-ingester.yaml      #   wave 1 — OCI chart ghcr.io/teststuffstash/charts@<pin>,
    snore-recorder.yaml      #            $values ref → THIS repo (not homelab!)
  values/sleep-ingester.yaml # image tag + chart config (the version pins live here)
  sleep-tracking/            # the CRs formerly in sleep-tracking/infra/
  snore-recorder/            # the CRs formerly in snore-recorder/infra/
  devbox.json                # ci seam: yamllint + kubeconform + helm-template-with-pinned-values
  .github/workflows/ci.yaml  # thin: devbox run ci; runs-on homelab-ephemeral
  renovate.json              # watches the ghcr chart/image pins (FU-014)
```

## The AppProject (platform-owned, stays in homelab)

`project: sleep` on every child Application replaces today's `default`. Definition next to the
root apps (tofu/argocd.tf or `argocd/platform/`):

- **sourceRepos:** the sleep-iac repo + `ghcr.io/teststuffstash/charts` (OCI). Nothing else — the
  app repos stop being ArgoCD sources entirely.
- **destinations:** namespaces `sleep-tracking`, `snore-recorder` (in-cluster only).
- **clusterResourceWhitelist:** `Namespace` (for `CreateNamespace=true`) **and the Crossplane
  `Workspace` GVK — it is cluster-scoped** (`kubectl get workspace`, no `-n`). Everything else
  namespaced-only. This is the tenancy boundary that makes homelab behave like a real platform.

## Migration sequence (prune-safe, zero-downtime)

Resource ownership follows the **Application name**, not the source repo — keep the names
(`sleep-tracking`, `snore-recorder`, `sleep-ingester`) and nothing gets pruned/recreated when the
sources flip. The Workspaces additionally carry `deletionPolicy: Orphan` (belt + suspenders for
the data buckets).

1. **Create the repo as code** — add `sleep-iac` to `tofu/github/repos.tf` + `protected_repos`
   (required check: `ci`) + the agent labels; apply outside the jail (admin PAT). Install the
   `homelab-agents` + `homelab-reviewer` Apps on it (click-only repo picker, `docs/github-setup.md`).
2. **Seed content** — copy the five manifests + values + both `infra/` dirs into the layout above;
   rewrite the three child Applications: `project: sleep`, sources → sleep-iac paths, and
   sleep-ingester's `$values` ref → sleep-iac.
3. **Platform side (homelab PR)** — add the `sleep` AppProject; seed the ArgoCD repo credential
   for sleep-iac (KeePass → tofu, same as `repo-sleep-tracking-github` — which becomes removable);
   flip the root `sleep` Application's `repoURL`/`path` to sleep-iac.
4. **Apply + verify** — `tofu apply` (targeted: `helm_release.argocd_apps` + the new secret);
   all three child apps Synced/Healthy, **no prune events**, Workspaces still `Synced/Ready`
   (adopted, not recreated), a manual ingester CronJob run green.
5. **Clean up** — delete homelab `argocd/sleep/`; empty both app repos' `infra/` to a README
   pointer ("deployment + infra CRs live in sleep-iac"); update `argocd/README.md`, the pattern
   doc ("today argocd/sleep plays the role" note), SERVICES.md ArgoCD row if worded around it.
6. **Wire the gates** — Renovate on sleep-iac (chart `targetRevision` + image `tag` pins → bump
   PRs); the reviewer/auto-merge gate applies as on the app repos. Later the full-stack k3d gate
   (ADR-082) becomes a required check here — that's the "deploy verify" of agent P2.

## Decisions to record when built

- **New ADR: three-layer repo topology** (app → stack-iac → platform), refining ADR-004/ADR-074 —
  the app still *owns* its resources, but the declarations live in the stack's iac repo, not the
  app repo (the app repo stays a pure artifact producer).
- Coordinator step 7a flips from "flag and stop" to: worker/Renovate opens the version-bump PR in
  sleep-iac → gates → auto-merge → ArgoCD syncs (`agents/coordinator/README.md`).
- FU-025 closes; the repo-creation part of **FU-039** gets its first data point (was the
  tofu/github seam painful enough to want a Crossplane GitHub provider?).

## Risks / gotchas

- **Don't rename Applications** (ownership/prune) and don't run step 3 before step 2 is merged —
  the root app would sync an empty repo and prune the stack. Order: content first, flip second.
- **AppProject too tight fails quietly-ish**: a blocked resource shows as a sync error on the
  child app — expect one iteration on the whitelist (the Workspace GVK, ESO kinds are namespaced
  and fine).
- sleep-iac is private (it's deployment config, not code) → the repo credential is required
  before the flip; verify with a manual hard-refresh of the root app.
- The `$values` multi-source ref must move off homelab in the same step as the child app —
  otherwise sleep-ingester still reads values from homelab and the extraction is cosmetic.
