# ArgoCD GitOps layer

The platform's GitOps seam. ArgoCD is installed + seeded by **`tofu/argocd.tf`**; from
there it reconciles this directory from git. Decision background: `docs/secrets.md`.

## How it bootstraps (and why this order)

> **Anything ArgoCD needs in order to run cannot be managed by ArgoCD.** So `tofu` installs
> ArgoCD, seeds Infisical's un-bootstrappable secrets + the git credential, and applies the
> root app-of-apps. Everything below that line is git-driven.

```
tofu/argocd.tf ──installs──► ArgoCD  +  seeds: infisical-secrets, infisical-db, infisical-pg-app,
       │                     repo-homelab-github, repo-oracle-iac-github (full set: `tofu/argocd.tf`)
       └──applies──► FOUR root Applications (platform, sleep, oracle, circles — circles bootstrap 2026-08-03:
`argocd/platform/circles-{project,namespaces}.yaml`) (helm: argocd-apps), source = GitHub (FU-007: Forgejo later)
                          │
          "platform" ─► argocd/platform/*.yaml  (child Applications, ordered by sync-wave)
             Sync waves -1→6 — authoritative list = the `argocd.argoproj.io/sync-wave`
             annotations in `argocd/platform/*.yaml`.
             agent-fixer = an ApplicationSet with four generators (homelab `agents/fixer/*`,
             sleep-iac `*/agent`, oracle-iac `*/agent`, circles-iac `*/agent`)
          "sleep" ──► github.com/teststuffstash/sleep-iac//apps  (the sleep stack, EXTRACTED to its
                      own public IaC repo — app infra Workspaces/ESO + the OCI-chart ingester, each
                      project: sleep. ADR-084. The `sleep` AppProject + its namespaces live here in
                      argocd/platform/{sleep-project,sleep-namespaces}.yaml.)
          "oracle" ─► github.com/teststuffstash/oracle-iac//apps  (the oracle stack, sleep-shaped
                      from day one — docs/oracle-iac.md. PRIVATE repo → read via the
                      repo-oracle-iac-github credential. AppProject + namespace in
                      argocd/platform/oracle-{project,namespaces}.yaml.)
```

## Secret flow

| Secret | Who creates it | Where |
|---|---|---|
| `infisical-secrets` (ENCRYPTION_KEY, AUTH_SECRET) | tofu ← KeePass | not in git |
| `infisical-db` (DB_CONNECTION_URI), `infisical-pg-app` | tofu ← KeePass | not in git |
| `repo-homelab-github` (ArgoCD git cred for the homelab repo — seeded when it was private; the repo is public now, the cred is harmless) | tofu ← KeePass | not in git |
| `repo-oracle-iac-github` (ArgoCD git cred for the private oracle-iac repo) | tofu ← KeePass | not in git |
| `repo-ghcr-charts-oci` (ArgoCD OCI/helm cred for the PRIVATE oracle-fleet-ingester chart; classic read:packages PAT) | tofu ← KeePass | not in git |
| `infisical-machine-identity` (ESO→Infisical auth) | `tofu/infisical/` (Infisical TF provider) | not in git |
| every app secret after that | Infisical → ESO → namespace Secret | — |

(The table is deliberately PARTIAL — the full seeded set incl. `repo-forgejo-oci` and the
Infisical bootstrap cred is `tofu/argocd.tf`, the authority the diagram already defers to.)

The CNPG cluster's app password is **supplied** (the `infisical-pg-app` basic-auth secret),
not generated, so tofu can build a matching `DB_CONNECTION_URI` deterministically.

## Apply / observe

```bash
source scripts/keepass-env.sh                          # TF_VAR_* from the wallet
devbox run -- tofu -chdir=tofu apply -target=helm_release.argocd \
  -target=kubernetes_secret.argocd_repo_github \
  -target=kubernetes_namespace.infisical \
  -target=kubernetes_secret.infisical_secrets \
  -target=kubernetes_secret.infisical_db \
  -target=kubernetes_secret.infisical_pg_app \
  -target=kubernetes_service.argocd_lb                 # ArgoCD + seeds first
devbox run -- tofu -chdir=tofu apply -target=helm_release.argocd_apps   # then hand off to git
KUBECONFIG=tofu/kubeconfig devbox run -- kubectl -n argocd get applications -w
```

ArgoCD admin password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d` → store in KeePass.

## Forgejo cutover (later — NOT done yet; FU-007)

We bootstrap against **GitHub** so there's no Forgejo/Postgres dependency on ArgoCD's own
git source. To honor the offline principle later, mirror the repo into Forgejo and flip the
source:

1. Configure a pull-mirror of `teststuffstash/homelab` on `forgejo.teststuff.net`.
2. Deliver a Forgejo read credential to ArgoCD via an `ExternalSecret` (now that ESO works).
3. Change `var.argocd_repo_url` (and the `repoURL` in the child apps) to the Forgejo URL,
   `tofu apply`, let ArgoCD re-sync from Forgejo. After that ArgoCD survives GitHub/WAN down.
