# Runbook — bootstrap the Tier-A GitHub runner (ARC) + ghcr

Brings the **self-hosted GitHub Actions runner** (Actions Runner Controller) live and wires the
**ghcr** pull credential, for the GitHub-canonical repos. Background + the two-tier model:
[`ci.md`](ci.md). This is the **privilege boundary** (same idea as `tofu/cloudflare-token/`): a few
steps need a GitHub **org owner** + a token GitHub will only mint in a browser; everything else is
scripted and re-runnable.

All scripted steps go through one helper (idempotent, safe to re-run):

```bash
devbox run github-runner-bootstrap <check|manifest|convert|secrets|access|verify>
# (= bash scripts/github-runner-bootstrap.sh <subcommand>)
```

> **What GitHub has no API for** (so these stay manual, once): creating the App (driven down to a
> single **Create** click via the App-manifest REST flow), **Installing** the App on the org, and
> minting the **ghcr PAT**. Everything after is `gh`/REST/`infisical` automation.

Defaults: `ORG=teststuffstash`, `REPOS="sleep-tracking snore-recorder"`, `SCALESET=homelab-ephemeral`,
creds cached in `~/.claude/homelab-github-arc/`. Override via env.

---

## 0. Preflight

```bash
devbox run github-runner-bootstrap check
```
Confirms `gh` is authed and prints exactly what's still missing. The App-create/Install steps need a
browser logged in as a **`teststuffstash` owner** — run those on your workstation; `secrets`/`verify`
are fine from the jail.

## 1. Create the GitHub App (1 click) — `manifest` → `convert`

```bash
devbox run github-runner-bootstrap manifest          # writes /tmp/gh-app-manifest.html
xdg-open /tmp/gh-app-manifest.html                   # macOS: open ...
```
The page auto-submits an App **manifest** (permissions baked in: *Organization → Self-hosted runners:
Read & write* + *Metadata: Read* — exactly what ARC needs for an org runner scale set). Click
**Create**. GitHub redirects to `http://localhost:8765/callback?code=XXXX` (the page won't load —
expected). Copy the `code` from the address bar:

```bash
devbox run github-runner-bootstrap convert XXXX      # POST /app-manifests/{code}/conversions
```
This saves the App **id**, **client id**, and **private key** to `~/.claude/homelab-github-arc/`
(`chmod 600`). The `code` is one-shot (~1h TTL) — if it expires, re-run `manifest`.

## 2. Install the App on the org (1 click)

`convert` prints the install URL:
```
https://github.com/organizations/teststuffstash/settings/apps/<slug>/installations
```
Open it, **Install**, and select the two repos (or *All repositories*). This is what creates the
installation whose id step 4 discovers.

## 3. Mint the ghcr pull PAT (1 click)

The cluster pulls the **private** `ghcr.io/teststuffstash/*` image, so it needs a read token. At
**github.com/settings/tokens**, create a **classic** PAT with **`read:packages`**. Fine-grained PATs
**cannot** access Packages/ghcr — GitHub Packages only supports classic PATs. Keep it; you'll pass it
as `GHCR_TOKEN` next. (CI *push* needs no token — the workflow's `GITHUB_TOKEN` with `packages: write`
covers it.)

## 4. Deliver all creds to Infisical — `secrets`

```bash
GHCR_TOKEN=ghp_xxx devbox run github-runner-bootstrap secrets
```
Discovers the installation id (`GET /orgs/teststuffstash/installations`) and pushes into Infisical
`homelab/prod` via `scripts/infisical-secret.sh`:

| Infisical key | Consumed by |
|---|---|
| `GHARC_APP_ID`, `GHARC_INSTALL_ID`, `GHARC_PRIVATE_KEY` | ESO → `arc-github-app` secret (arc-runners ns) → ARC chart `githubConfigSecret` |
| `SLEEP_GHCR_PULL_TOKEN` | ESO → `sleep-ingester-registry` dockerconfigjson (sleep-tracking ns) |

> The private key is a **multiline PEM** — the script stores it with the Infisical CLI's file-load
> syntax (`infisical secrets set GHARC_PRIVATE_KEY=@/abs/path/app.pem`) so the newlines survive
> byte-exact. Do **not** paste it as a plain inline value: that escapes the newlines to literal `\n`
> and ARC rejects it ("Key must be a PEM encoded PKCS1 or PKCS8 key"). To set it by hand:
> `devbox run infisical-secret GHARC_PRIVATE_KEY=@$HOME/.claude/homelab-github-arc/private-key.pem`

If `secrets` can't list installations (a fine-grained jail token may lack org-admin), re-run it
authed as an owner, or pass `INSTALL_ID=` explicitly (find it under the org App settings → Install).

## 5. Wire repo/org access — `access`

```bash
devbox run github-runner-bootstrap access
```
Enables Actions on each repo and reports the **runner-group** visibility. **This step is optional /
non-blocking** — ARC registers the scale set authenticating as the **GitHub App** (which holds the org
self-hosted-runners permission), and the **Default** runner group is available to all org repos by
default, so the runner works without it.

The runner-group *read* needs **`admin:org`** (a classic PAT) or a fine-grained token with the org
**Self-hosted runners** permission — **`read:org`/`repo`/`workflow` is NOT enough** (you'll get
`403: You must be an org admin or have the runners and runner groups fine-grained permission`). Only
act on it if you've *restricted* the Default group: Org → Settings → Actions → Runner groups (UI).

## 6. Deploy ARC (GitOps)

The manifests are already in git — ArgoCD's `platform` app-of-apps picks them up:
`argocd/platform/{arc-controller,github-runner-secrets,arc-runners}.yaml` +
`argocd/resources/github-runner/`. Just merge/push to `master`, or force it:

```bash
devbox run -- kubectl --kubeconfig tofu/kubeconfig -n argocd \
  annotate app platform argocd.argoproj.io/refresh=hard --overwrite
```

> **Chart version.** `arc-controller.yaml` and `arc-runners.yaml` pin `targetRevision: 0.14.2`
> (runner v2.334.0). Controller + scale-set versions **must match**; bump both together to the same
> current release (github.com/actions/actions-runner-controller/releases).

## 7. Verify

```bash
devbox run github-runner-bootstrap verify
```
Checks the controller pod (`arc-systems`), the `AutoscalingRunnerSet` + listener (`arc-runners`), the
ESO-rendered `arc-github-app` secret, and whether the runner is registered with the org. Then smoke-test:

```bash
gh workflow run -R teststuffstash/sleep-tracking ci.yaml --ref master
devbox run -- kubectl --kubeconfig tofu/kubeconfig -n arc-runners get pods -w   # a runner pod appears on a wk-metal node
```

## Rollback / rotate

- **Rotate the App key:** regenerate it in the App settings, re-run `secrets` (ESO repropagates within
  `refreshInterval`, 1h).
- **Tear down:** delete the three `argocd/platform/arc-*.yaml` + `github-runner-secrets.yaml` (ArgoCD
  prunes), uninstall the App from the org. The Forgejo Tier-B runner is unaffected.

## Notes

- The runner is **amd64** — it builds the amd64 sleep-ingester image but **not** snore-recorder's
  arm64 image (Talos kernel has no `binfmt_misc`); that one builds off-cluster (`devbox run
  build-image`). See [`ci.md`](ci.md).
- After the first ghcr build publishes, bump `image.tag` in `argocd/sleep/values/sleep-ingester.yaml`
  and retire the old `SLEEP_FORGEJO_REGISTRY_TOKEN` Infisical key.
