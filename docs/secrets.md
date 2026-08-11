# Secrets — how they're tiered, stored, and delivered

The decision is **ADR-062** (platform; supersedes the original SOPS plan in **ADR-061**). This is
the operational how-to. _(SOPS+age is **not used** anywhere — see "Why no SOPS" below.)_

> **One rule frames everything:** a secret lives at the lowest tier that can actually reach its
> consumer. The cluster can't decrypt the creds that *create* it, and an offline device can't be
> reached by an in-cluster operator — so there are three homes, not one.

## The three tiers

| Tier | What | Home | Reaches its consumer how |
|---|---|---|---|
| **0 — root / bootstrap** | creds that create the cluster or that the secret platform itself needs | **KeePass wallet** (out-of-repo) | a human / `tofu`, never the cluster |
| **1·2 — platform & app** | every in-cluster secret (DB creds, API keys, S3 keys, …) | **Infisical** (self-hosted) | **ESO** → a native `Secret` in the app's namespace |
| **(appliance)** | the offline `snore-recorder` device | **Infisical** (read once at provision) | written as plaintext `mode 600` files onto the device when you flash it |

**Tier 0 (KeePass).** `~/.claude/homelab-keepass/{homelab.kdbx,homelab.keyx}` — key-file-only so the
jail reads it unattended; copy both to a laptop to open in KeePassXC. Seed/refresh with
`bash scripts/keepass-init.sh`; load into a tofu session with `source scripts/keepass-env.sh` (exports
the `TF_VAR_*` the main root needs). Holds: Infisical encryption/auth keys + admin creds, the ArgoCD
git PAT, Postgres app passwords, the Grafana/HA creds — and, since 2026-07-12 (FU-001), **every
former `~/.claude/homelab-*` flat-file secret** (OPNsense/Proxmox/Matchbox/Cloudflare/Garage/
Forgejo/AWS/droplet/GitHub-App creds; multi-line key/cert material as entry *attachments*, e.g.
`keepassxc-cli attachment-export … matchbox-grpc client.key <out>` — note `--stdout` mangles binary
attachments like the `.p12`, export to a file). The wallet + Infisical are the **only stores**
(FU-001 complete 2026-07-13); the legacy flat files were parked in `~/.claude/.fu001-retired/` —
don't add new ones.
**This is the only ring you decrypt by hand.**

**Tier 1·2 (Infisical → ESO).** Infisical (`infisical.teststuff.net`, on CloudNativePG, ADR-046) is the
store; **External Secrets Operator** pulls from it via the `infisical` `ClusterSecretStore` and writes a
normal k8s `Secret`. ArgoCD only ever syncs the *`ExternalSecret`* manifest — values never touch git.

**Appliance (offline device).** The bedside Pi (`snore-recorder`) syncs over flaky Wi-Fi and would
sit `NotReady` as a cluster node, so ESO can't serve it. Instead its secrets are **read from Infisical
once at provision time** and written as plaintext `mode 600` files on the SD card
(`/var/lib/snore-secrets/{s3.env,wifi.env}`, via the snore-recorder repo's `devbox run provision-secrets`).
Infisical stays the source of truth; the device just holds a local copy.

**Why no SOPS.** SOPS+age (the ADR-061 plan) was dropped. In-cluster, ArgoCD would need a decrypt
plugin and you lose rotation/audit (Infisical/ESO win). On the offline device, `sops-nix` gave **no real
at-rest protection** — the age private key has to live on the same card as the ciphertext, so a stolen
card yields both; it was pure ceremony for a single hand-provisioned box. Net: KeePass for Tier-0,
Infisical/ESO for the rest, plaintext-from-Infisical for the device.

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

## Minting doctrine — a token's scope is config, not a secret

The three tiers above govern where secret **values** live. Creation is governed separately, and
the rule is CONTEXT.md principle #1 applied to credentials: **a credential's *value* is data
(wallet/Infisical); its *existence and scope* are config, minted as code from a tofu root**
(`tofu/cloudflare-token/`, `tofu/github/`, …) so the credential inventory is recreatable and
`plan`-reviewable like everything else. Dashboards and web UIs are **read-only surfaces**
(ADR-001: "web UIs are for viewing") — an existing dashboard-born token is legacy to retire at
its next review (see the 2026-06 "Read all resources" token below), not a precedent.

Hand-creation is a **closed two-item list**, and nothing else:

1. **The Tier-0 mint-root itself** — the credential that mints credentials (the Cloudflare
   admin token — [`cloudflare.md`](cloudflare.md) §Token matrix — and the KeePass wallet). The root of a trust chain is manual by construction;
   its creation/renewal steps are recorded here and in the mint root's README.
2. **Third-party consoles** we don't operate (registrar NS/DS at zone.ee, …) — principle 1(a)
   governs systems *we* run; where git can't reach, the click is recorded as a numbered manual
   step in the owning doc so recovery (principle 1(b)) survives it.

Scope shape follows the framing rule at the top: **one consumer, one token, at its consumer's
tier** — an in-cluster poller gets its own tiny Infisical-delivered token, never a broad
jail/wallet credential, even when one token *could* technically serve both.

## Boundaries

- **Repos are public** — never commit a value. Tofu state in `tofu/infisical/` is local + gitignored
  (it holds the ESO client secret); the provider lock is committed.
- The Infisical→ESO path is **read-only** — by design (`eso-reader` has project `viewer`) **and** by
  capability (the ESO Infisical provider is read-only; `ClusterSecretStore` reports `ReadOnly`, so ESO
  `PushSecret` to Infisical does not work). Writes happen three ways: `devbox run infisical-secret` /
  the UI (ad-hoc, as admin), or a **Crossplane Workspace** publishing via the Infisical TF provider
  (the `crossplane-tf-writer` identity — how app-generated keys land in Infisical, ADR-076).
- Rotation: re-run the relevant `tofu`/`infisical-secret`; ESO re-syncs consumers on its refresh.

## Credential expiry is telemetry, not documentation (design direction 2026-08-08, FU-156)

A tracker line saying "renew token X before December" is the wrong system — it relies on a human
reading it in time, and the operator mints everything with ≤1-year TTLs on purpose, so the
inventory of fuses only grows. The certificate half of this problem is ALREADY solved here the
right way (blackbox `probe_ssl_earliest_cert_expiry` — nobody documents cert expiry dates), and
credentials get the same shape:

- **One gauge**: `credential_expiry_timestamp_seconds{provider, credential}` + one alert rule
  (warning at <30d, escalating <7d), **labeled `triage: none`** — the responder can do NOTHING
  about admin credentials (the remedy is host-side by construction: admin wallet, a host-only
  apply — or the dashboard for the Tier-0 mint-root alone, §Minting doctrine), and the
  condition is deterministic, so an LLM triage session would be
  pure waste. The alert routes to the HUMAN surface (Home Assistant) with its annotation
  naming the renewal runbook (which mint root + the re-store checklist) — the
  `GithubVendorOutage` precedent: machine-unactionable, human-informational. No
  per-credential tracker lines, ever.
- **Live-polled where the provider allows**: Cloudflare `GET /user/tokens` lists every token with
  `expires_on` — needs a tiny `User: API Tokens: Read`-scoped token (user-scoped, so it is NOT
  covered by `homelab-observability-read`; mint it beside it). GitHub fine-grained PATs are
  listable org-side for org-granted ones.
- **Declared where not**: file-shaped credentials (client `.p12`s, App private keys with known
  rotation policy) get their expiry read from the artifact itself (`openssl`) or from the mint
  code (tofu `expires_on`) — rendered into the exporter's config, never hand-copied.
- **Renewal ≠ rotation bookkeeping**: the alert names the credential; the runbook is the minting
  root's own apply (`devbox run cloudflare-token-tofu apply`, `github-tofu`, …) + the printed
  re-store checklist. Retirement counts as resolution — a superseded credential (e.g. the broad
  2026-06 "Read all resources" token once `homelab-observability-read` exists) is DELETED at its
  review, not renewed on autopilot.

Token inventory + expiries: [`cloudflare.md`](cloudflare.md) §Token matrix — the ONE table (a
dated copy lived here and had already drifted from it; collapsed 2026-08-11). The one fact that
is THIS doc's: the mint credential itself ("Create Additional Tokens", → 2027-01-09) renews
manually in the admin wallet — root of trust.
