# CI / forges — the two-tier model

_How CI and source hosting are split in this homelab. Decided 2026-06-24 (replaces the earlier
"act_runner is the one CI seam" plan in `slsa.md`/`follow-ups.md`)._

We want **GitHub's reach** (public exposure + SaaS integrations: Renovate, CodeRabbit, Blacksmith,
Chainguard) **and** a **local-first fallback** (own runner, own git copy). Full GitHub↔Forgejo PR/
comment mirroring isn't mature, so instead of forcing one forge we run **two tiers**, picked per
project:

| | **Tier A — GitHub-canonical** | **Tier B — Forgejo-only** |
|---|---|---|
| Source of truth | GitHub (`teststuffstash/*`) | Forgejo (`forgejo.teststuff.net`) |
| CI runner | **ARC** (Actions Runner Controller), `runs-on: homelab-ephemeral` | **act_runner** (`runs-on: docker`) |
| Registry | **ghcr.io** | Forgejo registry |
| Local copy | Forgejo **pull-mirror** (read-only DR) | n/a (already local) |
| For | projects that want exposure / SaaS (sleep-tracking, snore-recorder) | fully-private, self-contained projects |

Both runners are **in-cluster, pinned to the ephemeral laptop tier** (`homelab.io/ephemeral`, DinD,
privileged ns) so CI noise/privilege stays off the service nodes.

## The one rule that makes this cheap: the `devbox run` seam

**Workflows stay thin — they call `devbox run <task>` and nothing else.** All build/test/scan logic
+ tool versions live in the repo's `devbox.json` (+ `scripts/`), not in CI YAML. Consequences:

- The same gate runs **locally and in CI**, identically (`devbox run ci`).
- Tier-A and Tier-B run the *same* logic under different forges — only `runs-on` + the registry differ.
- Swapping the runner later (ARC → **Blacksmith**/**Chainguard**) is a `runs-on`/host change with
  **zero logic change**.

Example (sleep-tracking): `devbox run ci` = ruff + ruff-format-check + pytest-cov; `devbox run
test-chart` = helm-unittest; `devbox run scan-secrets` = gitleaks. The workflow just lists those steps.

## Tier A — ARC (self-hosted GitHub runner)

- ArgoCD apps: `argocd/platform/arc-controller.yaml` (operator, `arc-systems`, stable tier) +
  `arc-runners.yaml` (the `homelab-ephemeral` scale set, `arc-runners` ns, ephemeral tier,
  scale-to-zero, `containerMode: dind`) + `github-runner-secrets.yaml` →
  `argocd/resources/github-runner/` (ns + the `arc-github-app` ESO `ExternalSecret`).
- Auth: a **GitHub App** on the org (permissions: Organization → Self-hosted runners: R/W, +
  Metadata: Read); creds in Infisical (`GHARC_APP_ID`/`GHARC_INSTALL_ID`/`GHARC_PRIVATE_KEY`) → ESO →
  `arc-github-app` secret → chart `githubConfigSecret`. Bootstrap is scripted:
  `scripts/github-runner-bootstrap.sh` (runbook: [`github-runner-bootstrap.md`](github-runner-bootstrap.md)).
- Registry pull: private ghcr packages need a `read:packages` token (`SLEEP_GHCR_PULL_TOKEN` in
  Infisical → ESO dockerconfigjson). CI **push** to ghcr needs no extra secret — the job's
  `GITHUB_TOKEN` with `packages: write` is enough.
- **amd64 only.** It builds the (amd64) sleep-ingester image fine; it **cannot** build
  snore-recorder's **arm64** image — the Talos node kernel has no `binfmt_misc`, so QEMU emulation
  fails. arm64 images build **off-cluster** via `devbox run build-image` on a binfmt-capable host.

Bring-up steps + open items: `docs/follow-ups.md` → "CI — GitHub-canonical tier".

## Tier B — act_runner (Forgejo-only)

`tofu/forgejo-runner.tf` — unchanged. Use it for a project that should never touch GitHub: host the
repo on Forgejo, push images to the Forgejo registry, run `.forgejo/workflows/` (same `devbox run`
seam). This is also where the self-hosted **SLSA** story continues (cosign + SBOM on a hosted,
not-a-laptop builder) — see `slsa.md`.
