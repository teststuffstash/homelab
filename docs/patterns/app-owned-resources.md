# Pattern: app-owned platform resources — homelab as a platform

> To find **what** services exist (and their status), see the catalog [`../../SERVICES.md`](../../SERVICES.md).
> This doc is the **doctrine + how-to** for consuming them.
> Decisions: **ADR-074** (apps own their buckets/keys/DBs) · **ADR-076** (mechanism: Crossplane
> `provider-terraform`, live) · **ADR-169** (a stack declares buckets/keys/passwords on its
> AgentStack; the platform writes the Terraform).

> Observability (monitors, rules, dashboards, the read paths) has its own consumption contract:
> [`observability.md`](observability.md).

**Treat homelab like AWS or Civo.** The platform provides **capabilities** (an S3 store, a Postgres
operator, a secrets platform, an LLM-key minter) behind declarative seams; each app declares the
**instances** it needs — buckets, keys, grants, databases — **from its own repo**, as CRs reconciled
in-cluster. homelab creates no app resources and holds no app keys. App repos stay
**platform-agnostic**: what they contain is standard Kubernetes (a Helm chart, `Secret` refs, an S3
endpoint, a Postgres URL) — nothing homelab-specific beyond the CR manifests in `infra/`.

## Self-service today (declare a CR, get the resource)

| Resource | Declare in your repo | Reconciler | The secret lands |
|---|---|---|---|
| **Garage bucket / key / grant, generated password** | a `repos[].provision` entry on your stack's AgentStack ([below](#buckets-keys-and-passwords-reposprovision-adr-169)) — never a `Workspace` of your own (ADR-169) | the AgentStack Composition renders a `Workspace` from fixed Terraform; `provider-terraform` reconciles it | connection `Secret` in your namespace; optionally **published to Infisical** (allowlisted key names) |
| **OpenRouter API key** (budget-capped) | `infra/openrouter-key.yaml` — `OpenRouterKey` CR (`budgetUSD`, `resetInterval`; `ephemeral` for per-session breakers) | [`openrouter-operator`](https://github.com/teststuffstash/openrouter-operator) | `<project>-openrouter` Secret in your namespace |
| **Postgres** (HA) | a `postgresql.cnpg.io/v1` `Cluster` CR in your namespace | CloudNativePG (ADR-046) | the operator's `<cluster>-app` secret (or supply your own) |
| **Grafana shared dashboard** (a login-less URL for ONE of your dashboards — a stack jail's browser, a kiosk) | `infra/<dashboard>-share.yaml` — a `DashboardPublic` CR (provider-grafana), recipe + the no-Loki rule in [`observability.md`](observability.md) §2 | `provider-grafana` (admin cred ESO-injected platform-side; `ClusterProviderConfig` `grafana`) | no secret — the URL's token is `status.atProvider.accessToken` |
| **Any secret** | an `ExternalSecret` against the `infisical` `ClusterSecretStore` | ESO (ADR-062, [`../secrets.md`](../secrets.md)) | a native `Secret` in your namespace |

The stack-authored `Workspace` manifests still live in `sleep-iac`, `oracle-iac` and `circles-iac`
are LEGACY: they move under `repos[].provision` by adoption ([`../stack-workspace-migration.md`](../stack-workspace-migration.md))
and no new one is written.

## Buckets, keys and passwords: `repos[].provision` (ADR-169)

A stack used to get a bucket by writing a provider-terraform `Workspace`, i.e. Terraform that ran with
the platform's Garage admin token, its Infisical writer and a provider pod that can read every Secret.
Now it states WHAT it needs on its AgentStack and the Composition
(`argocd/resources/agentstack/composition.yaml`) writes the Terraform. Each entry renders one
`Workspace` named `<repo>.<name>`; every output is a key of the connection Secret in ns `<repo>`.

```yaml
repos:
  - name: oracle-fleet
    provision:
      - name: cache                       # Workspace oracle-fleet.cache, Secret `cache` (or secretName)
        buckets:
          - { alias: oracle-fleet-cache, maxSizeMi: 2048, output: bucket }   # website: true to serve it
        readBuckets:                      # a bucket of your own alias space you READ but do not create
          - { alias: ert-snapshots }
        keys:
          - name: rw                      # outputs rw_access_key_id / rw_secret_access_key
            grants:
              - { bucket: oracle-fleet-cache, access: rw }   # rw | ro | wo
              - { bucket: ert-snapshots, access: ro }
        externalGrants:                   # bucket-owner-grants-consumer, by key ID
          - { bucket: oracle-fleet-cache, accessKeyId: GK…, access: ro }
        passwords:
          - { name: token, length: 40 }   # rotate: generation: "2"; never replace: stable: true
        infisical:                        # the homelab project; only names on your stack's list in the Composition
          publish:
            - { name: ORACLE_…, password: token }   # or keyId: / keySecret: <key name>
```

The bounds, held per stack in the Composition's `$provisionTenancy` (a platform PR changes them):
bucket aliases inside the stack's prefixes (`oracle-`, `circles-`, `sleep-`) or its named legacy
aliases; Secrets only into the stack's namespaces; Infisical writes only to listed key names;
`adopt` only of the stack's own legacy Workspaces. An entry outside them fails the AgentStack render
with the reason (nothing existing changes; the XR parks until the claim is fixed). Removing a WHOLE
entry **orphans** what it made (management policies carry no Delete): the bucket, its keys and
passwords stay, and the keys stay valid until an operator deletes them. Removing one bucket, key,
grant or password from an entry that stays is an ordinary apply, and Terraform **destroys** it —
that is how a key is revoked or a grant withdrawn. `stable: true` protects a password only while
its line is there. (Garage refuses to delete a bucket that holds objects, per its admin API; not
tried here.) `kubectl explain agentstacks.spec.repos.provision --recursive` documents every field.

`adopt: {workspace, mode}` takes over a legacy Workspace's Terraform state (the migration; `tfName`
and the output overrides exist only so an entry can match a legacy module exactly).
`scripts/provision-adopt-check.py --live <legacy> <repo>.<name>` compares the two modules, and
`mode: observe` proves it live: the Workspace plans against the state and turns Ready only on an
empty plan. Gate: `devbox run -- bash scripts/agentstack-provision-test.sh`.

## Not yet self-service (FU-039 — the platform gap)

- **Git repos + branch protection + labels** — `tofu/github/`, applied outside the jail with an
  admin PAT. A new repo is a homelab-side step today.
- **HTTPS names / DNS** — only a NEW top-level name for a non-delegated stack needs the OPNsense
  path from homelab; a delegated stack adds names as HTTPRoutes in its own `-iac` (ADR-092), and
  public ingress is a claim (PublicRoute, ADR-101).
- **ArgoCD Application / AppProject + namespace** — a PR to homelab's `argocd/` today.

Until those close, "provision it yourself" sometimes means "open a small homelab PR" — fine, but
name it for what it is: a platform gap, not the model.

## Direction — the stack-IaC layer (FU-025)

The target shape is **three layers**, so app repos know *nothing* about homelab:

```
app repo (sleep-tracking, snore-recorder)      code + chart. Publishes image + OCI chart to ghcr.
        ▼   version bump = a PR here ↓          Standard k8s all the way; no homelab knowledge.
stack-iac repo (sleep-iac — LIVE, extracted)     the ArgoCD AppProject + app-of-apps for one stack:
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

- **Every bucket claim states its size cap** (ADR-089 quota-as-contract): `maxSizeMi` on each
  `repos[].provision` bucket (a required field). The SUM ownership + the check live in
  [`storage-ledger.md`](../storage-ledger.md) (`devbox run storage-ledger`); a granted cap is a
  real promise. Over-cap
  writes fail at the S3 API with a quota error — legible, at the consumer. (`max_objects` is
  also available for object-count-shaped risks.)
- **Scope keys tightly, per access method.** A device that only `put_object`s gets a **write-only**
  key; a client that must list to sync needs **read+write**. Isolation is by-bucket regardless
  (Garage has no prefix IAM — ADR-031).
- **Cross-app sharing = bucket-owner-grants-consumer.** The owning repo declares the grant
  (`externalGrants`), referencing the consumer's access key **by ID** (not secret). Example:
  snore-recorder grants the sleep-tracking ingester read on `sleep-snore`.
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
2. Add a `repos[].provision` entry for the repo's buckets/keys/passwords to the stack's AgentStack
   ([above](#buckets-keys-and-passwords-reposprovision-adr-169)); a new stack first gets its bounds
   in the Composition (platform PR). Add an `OpenRouterKey` if agents will work the repo.
3. Consume the generated Secrets (`ExternalSecret` / the operator-written Secret) in your chart —
   standard `envFrom`/`secretRef`, nothing homelab-specific.
4. Add the platform-knowledge block to the app's `CLAUDE.md` (copy from sleep-tracking).

## History

The **interim** path (ADR-075, retired): apps ran their own `infra/` tofu via a `kubectl
port-forward` to the Garage admin API (`apply.sh`), keys landing in local gitignored state. ADR-076
replaced it — if you find references to `apply.sh`/local key state, they're stale.
