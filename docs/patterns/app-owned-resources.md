# Pattern: app-owned platform resources

> To find **what** services exist (and their status), see the catalog [`../../SERVICES.md`](../../SERVICES.md).
> This doc is **how** to consume the storage ones.
>
> Decision: **ADR-074** (apps own their buckets/keys/DBs). Mechanism: **ADR-075** (app-repo tofu now,
> Crossplane later). This doc is the reusable **how-to** for adding a new app that needs Garage
> storage. Garage platform reference: [`garage.md`](../garage.md).

The platform provides a **capability** (the Garage store) plus a thin **admin seam**. Each app
declares the **instances** it needs — buckets, keys, permission grants — from **its own repo**, and
consumes the generated key as a secret in its own namespace. homelab creates no app buckets and holds
no app keys.

## The seam the platform exposes

- **Admin API** on `garage-0:3903` — **ClusterIP-only**, never on the LAN/VIP.
- **Admin token** stashed at `~/.claude/homelab-garage/admin-token` (set from `tofu -chdir=tofu
  output -raw garage_admin_token`). This is the credential app provisioning uses.
- Apps reach the admin API via a short-lived `kubectl port-forward` (not by exposing it).

## What an app repo carries

An `infra/` directory with tofu + a wrapper (copy from `sleep-tracking` or `snore-recorder`):

- `versions.tf` — `registry.terraform.io/jkossis/garage` provider (Terraform registry; pinned +
  checksummed in `.terraform.lock.hcl`). `provider "garage" {}` reads `GARAGE_ENDPOINT`/`GARAGE_TOKEN`.
- `garage.tf` — `garage_bucket`, `garage_key`, `garage_bucket_permission` resources.
- `outputs.tf` — the access key id + secret as **sensitive** outputs.
- `apply.sh` — port-forwards `pod/garage-0:3903`, exports `GARAGE_ENDPOINT=http://127.0.0.1:13903`
  and `GARAGE_TOKEN` from the stash, then runs tofu. `devbox run buckets-plan|buckets-apply`.
- devbox: `opentofu`, `kubectl` (+ `awscli2` to inspect data).

State is **local + gitignored** — it holds the keys. Never commit keys (repos are public; SOPS+age
before public, ADR-061).

## Conventions

- **Scope keys tightly, per access method.** A device that only `put_object`s (boto3) gets a
  **write-only** key (`snore-recorder`). A client that must list the remote to sync (FolderSync) needs
  **read+write** (`sleep-band-writer`). Isolation is by-bucket regardless.
- **Cross-app sharing = bucket-owner-grants-consumer.** The bucket's owning repo declares the grant,
  referencing the consumer's access key **by ID** via a variable (the ID isn't secret). Example:
  `snore-recorder` grants the `sleep-tracking` ingester read on `sleep-snore`
  (`var.ingester_access_key_id`).
- **Reading data ≠ provisioning.** To read a bucket, use the **S3 API** (`https://s3.teststuff.net`,
  region `garage`, path-style) with a read-capable key. The admin port-forward is only for managing
  buckets/keys. Don't move data through it.
- **One CLAUDE.md block per app** stating the Garage ground-truth (endpoints, region, path-style) so
  fresh sessions don't second-guess whether the platform is real. See the app CLAUDE.md files.

## Adding a new app — checklist

1. Copy `infra/` from `snore-recorder` (or `sleep-tracking`); set the bucket alias + key name(s).
2. `devbox run buckets-plan` → review → `devbox run buckets-apply`.
3. Wire the key into the app (env/Secret). For cross-app reads, add the grant in the **owning** repo.
4. Add the Garage ground-truth block to the app's `CLAUDE.md`.

## Steady state — Crossplane (ADR-076, LIVE)

The control plane landed: apps now declare their Garage resources as a Crossplane **`Workspace`** CR
(`provider-terraform` wrapping the same `jkossis/garage` module) in their **own repo**, synced by an
ArgoCD `Application` from the homelab repo. The provider reconciles in-cluster (admin token injected via
ESO), so the manual `apply.sh` port-forward goes away. The generated key lands in a connection `Secret`
and is published to **Infisical** (source of truth); in-cluster consumers read it via an `ExternalSecret`,
**offline devices via sops-nix** (sourced from Infisical — ESO can't reach them). Worked example:
`snore-recorder` (`infra/garage-workspace.yaml` + homelab `argocd/platform/snore-recorder.yaml`).
