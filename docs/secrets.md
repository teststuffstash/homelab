# Secrets — how they're tiered, stored, and delivered

The decision is **ADR-062** (platform) + **ADR-061** (the original out-of-repo/SOPS call it
refines). This is the operational how-to.

> **One rule frames everything:** a secret lives at the lowest tier that can actually reach its
> consumer. The cluster can't decrypt the creds that *create* it, and an offline device can't be
> reached by an in-cluster operator — so there are three homes, not one.

## The three tiers

| Tier | What | Home | Reaches its consumer how |
|---|---|---|---|
| **0 — root / bootstrap** | creds that create the cluster or that the secret platform itself needs | **KeePass wallet** (out-of-repo) | a human / `tofu`, never the cluster |
| **1·2 — platform & app** | every in-cluster secret (DB creds, API keys, S3 keys, …) | **Infisical** (self-hosted) | **ESO** → a native `Secret` in the app's namespace |
| **(appliance)** | the offline `snore-recorder` device | **SOPS + age** (`sops-nix`) | decrypted on-device at boot |

**Tier 0 (KeePass).** `~/.claude/homelab-keepass/{homelab.kdbx,homelab.keyx}` — key-file-only so the
jail reads it unattended; copy both to a laptop to open in KeePassXC. Seed/refresh with
`bash scripts/keepass-init.sh`; load into a tofu session with `source scripts/keepass-env.sh` (exports
the `TF_VAR_*` the main root needs). Holds: Infisical encryption/auth keys + admin creds, the ArgoCD
git PAT, Postgres app passwords, the Grafana/HA creds. **This is the only ring you decrypt by hand.**

**Tier 1·2 (Infisical → ESO).** Infisical (`infisical.teststuff.net`, on CloudNativePG, ADR-046) is the
store; **External Secrets Operator** pulls from it via the `infisical` `ClusterSecretStore` and writes a
normal k8s `Secret`. ArgoCD only ever syncs the *`ExternalSecret`* manifest — values never touch git.

**Appliance (SOPS).** Kept **only** for the bedside Pi (`snore-recorder`), which syncs over flaky Wi-Fi
and would sit `NotReady` as a cluster node — ESO can't serve it. Everything else moved off SOPS.

## Bootstrap order (why it's `tofu`, not ArgoCD)

Anything the secret platform needs can't be delivered by the secret platform. So `tofu` seeds the
irreducible minimum and ArgoCD/Infisical take over:

```
KeePass ──tofu/argocd.tf──► ArgoCD + Infisical bootstrap secrets (encryption/auth keys, DB creds, git PAT)
   │                            └─ chart autoBootstrap → super admin (creds in KeePass), org "homelab"
   ▼                                   └─ emits a non-expiring instance-admin TOKEN (in-cluster secret)
tofu/infisical/ (Infisical TF provider, token-auth) ──► project "homelab" + "eso-reader" UA identity
   ▼                                                        └─ writes infisical-machine-identity → ESO
ESO ClusterSecretStore "infisical" = Ready ──► ExternalSecrets resolve for every app
```

## Day-2: add a secret an app can consume

1. **Put the value in Infisical** (homelab project, `prod` env, `/` path by default):
   ```sh
   devbox run infisical-secret MY_API_KEY=s3cr3t
   ```
2. **Pull it into the app's namespace** with an `ExternalSecret` (copy
   `argocd/resources/extras/demo-externalsecret.yaml`):
   ```yaml
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata: { name: my-app, namespace: my-app }
   spec:
     secretStoreRef: { name: infisical, kind: ClusterSecretStore }
     target: { name: my-app }
     data:
       - secretKey: MY_API_KEY
         remoteRef: { key: MY_API_KEY }
   ```
   Commit it (ArgoCD applies it); ESO writes Secret `my-app/my-app`. The `secrets-demo/demo-ping`
   canary proves the whole chain is healthy.

## Useful commands

| Command | Does |
|---|---|
| `bash scripts/keepass-init.sh` | create/seed the Tier-0 wallet (idempotent) |
| `source scripts/keepass-env.sh` | export `TF_VAR_*` from the wallet for `tofu` |
| `devbox run infisical-secret K=V` | set a secret in the homelab project (`INFISICAL_ENV`/`INFISICAL_PATH` to override) |
| `devbox run infisical-harden` | re-assert signups off (idempotent) |
| `bash tofu/infisical/apply.sh apply` | reconcile the Infisical project + ESO identity |

## Boundaries

- **Repos are public** — never commit a value. Tofu state in `tofu/infisical/` is local + gitignored
  (it holds the ESO client secret); the provider lock is committed.
- The Infisical→ESO path is **read-only** (`eso-reader` has project `viewer`). Writes go through
  `infisical-secret` / the UI as an admin.
- Rotation: re-run the relevant `tofu`/`infisical-secret`; ESO re-syncs consumers on its refresh.
