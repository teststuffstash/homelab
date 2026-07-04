# Pattern: app-owned platform resources — homelab as a platform

> To find **what** services exist (and their status), see the catalog [`../../SERVICES.md`](../../SERVICES.md).
> This doc is the **doctrine + how-to** for consuming them.
> Decisions: **ADR-074** (apps own their buckets/keys/DBs) · **ADR-076** (mechanism: Crossplane
> `provider-terraform`, live).

**Treat homelab like AWS or Civo.** The platform provides **capabilities** (an S3 store, a Postgres
operator, a secrets platform, an LLM-key minter) behind declarative seams; each app declares the
**instances** it needs — buckets, keys, grants, databases — **from its own repo**, as CRs reconciled
in-cluster. homelab creates no app resources and holds no app keys. App repos stay
**platform-agnostic**: what they contain is standard Kubernetes (a Helm chart, `Secret` refs, an S3
endpoint, a Postgres URL) — nothing homelab-specific beyond the CR manifests in `infra/`.

## Self-service today (declare a CR, get the resource)

| Resource | Declare in your repo | Reconciler | The secret lands |
|---|---|---|---|
| **Garage bucket / key / grant** | `infra/garage-workspace.yaml` — Crossplane `Workspace` wrapping the `jkossis/garage` module | `provider-terraform` (admin cred ESO-injected platform-side) | connection `Secret` + **published to Infisical** by the Workspace itself (the `crossplane-tf-writer` identity) |
| **OpenRouter API key** (budget-capped) | `infra/openrouter-key.yaml` — `OpenRouterKey` CR (`budgetUSD`, `resetInterval`; `ephemeral` for per-session breakers) | [`openrouter-operator`](https://github.com/teststuffstash/openrouter-operator) | `<project>-openrouter` Secret in your namespace |
| **Postgres** (HA) | a `postgresql.cnpg.io/v1` `Cluster` CR in your namespace | CloudNativePG (ADR-046) | the operator's `<cluster>-app` secret (or supply your own) |
| **Any secret** | an `ExternalSecret` against the `infisical` `ClusterSecretStore` | ESO (ADR-062, [`../secrets.md`](../secrets.md)) | a native `Secret` in your namespace |

Worked examples: `snore-recorder/infra/` (bucket created fresh + write-only key + cross-app grant),
`sleep-tracking/infra/` (pre-existing buckets **adopted** via config-driven `import` +
`deletionPolicy: Orphan` — never recreate resources that hold data).

## Not yet self-service (FU-039 — the platform gap)

- **Git repos + branch protection + labels** — `tofu/github/`, applied outside the jail with an
  admin PAT. A new repo is a homelab-side step today.
- **HTTPS names / DNS** (`<name>.teststuff.net`) — the OPNsense ansible path (`/opnsense-as-code`),
  run from the homelab repo.
- **ArgoCD Application / AppProject + namespace** — a PR to homelab's `argocd/` today.

Until those close, "provision it yourself" sometimes means "open a small homelab PR" — fine, but
name it for what it is: a platform gap, not the model.

## Direction — the stack-IaC layer (FU-025)

The target shape is **three layers**, so app repos know *nothing* about homelab:

```
app repo (sleep-tracking, snore-recorder)      code + chart. Publishes image + OCI chart to ghcr.
        ▼   version bump = a PR here ↓          Standard k8s all the way; no homelab knowledge.
stack-iac repo (sleep-iac — to be created)     the ArgoCD AppProject + app-of-apps for one stack:
        ▼                                       Application manifests + values + the apps' infra CRs
                                                + pinned versions. Own CI gates; a deploy is a
                                                version-bump PR here (Renovate/agent P2 territory).
homelab (this repo)                            the platform: cluster, operators, SERVICES.md, and
                                                ONE root Application per stack pointing at its iac repo.
```

The sleep stack was **extracted** into its own public `sleep-iac` repo (FU-025) — homelab's root
`sleep` Application now points at `sleep-iac//apps`, not the old in-repo `argocd/sleep/`. That fixed
the drifty release→deploy path (a deploy is a version-bump PR in sleep-iac) and gave the coordinator
a clean automated-deploy seam. The `sleep` AppProject (`argocd/platform/sleep-project.yaml`) is the
tenancy boundary: the iac repo can only deploy into its own (platform-precreated) namespaces.

## Conventions

- **Scope keys tightly, per access method.** A device that only `put_object`s gets a **write-only**
  key; a client that must list to sync needs **read+write**. Isolation is by-bucket regardless
  (Garage has no prefix IAM — ADR-031).
- **Cross-app sharing = bucket-owner-grants-consumer.** The owning repo declares the grant,
  referencing the consumer's access key **by ID** (not secret). Example: snore-recorder grants the
  sleep-tracking ingester read on `sleep-snore`.
- **Reading data ≠ provisioning.** Data goes through the **S3 API** (`https://s3.teststuff.net`,
  region `garage`, path-style) with a normal key. The admin API (`:3903`) is the platform's
  provisioning seam only — never move data through it.
- **Platform knowledge stays out of app repos.** Each app `CLAUDE.md` carries a short "platform
  knowledge" block: grep this repo's `SERVICES.md` from the jail (never cache catalog state in app
  docs — it rots); in an agent worker pod the **issue is the context channel**
  ([`../agents/README.md`](../agents/README.md)). The only pinned facts are app config: the S3
  endpoint coordinates + the app's own bucket names.

## Adding a new app — checklist

1. Create the repo (homelab-side today: `tofu/github/` — FU-039) and, if it deploys in-cluster,
   its ArgoCD Application (today: `argocd/`; target: the stack's iac repo).
2. Copy `infra/` from snore-recorder (fresh resources) or sleep-tracking (adopting existing data);
   set bucket/key names, add an `OpenRouterKey` if agents will work the repo.
3. Consume the generated Secrets (`ExternalSecret` / the operator-written Secret) in your chart —
   standard `envFrom`/`secretRef`, nothing homelab-specific.
4. Add the platform-knowledge block to the app's `CLAUDE.md` (copy from sleep-tracking).

## History

The **interim** path (ADR-075, retired): apps ran their own `infra/` tofu via a `kubectl
port-forward` to the Garage admin API (`apply.sh`), keys landing in local gitignored state. ADR-076
replaced it — if you find references to `apply.sh`/local key state, they're stale.
