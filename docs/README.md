# Homelab documentation

Service- and operations-level docs for the homelab. Infrastructure-as-code lives elsewhere
in the repo (`tofu/`, `ansible/`, `esphome/`, `homeassistant/`); these pages describe how the
running services fit together, how to operate them, and their risks.

## Operations & design

| Doc | Summary |
|---|---|
| [adr.md](adr.md) | **Architecture Decision Record** — what was considered (e.g. Ceph vs Longhorn) and what was chosen, with rationale. Start here for *why*. |
| [agents/](agents/README.md) | **Agent platform** (design/scaffolding) — in-cluster MCP capability + ephemeral sandbox harness; trust model, identity/secrets, testing doctrine, the worked sleep-tracker fix flow |
| [runbook.md](runbook.md) | Day-to-day operational recipes — devbox, OPNsense-as-code, DHCP/DNS, storage, CNPG, HA, UniFi, Cloudflare, ESPHome — and the gotchas behind them |
| [follow-ups.md](follow-ups.md) | **The FU tracker** — every loose end / deferred item as a stable `FU-NNN` id (conventions in its header) |
| [provisioning.md](provisioning.md) | Matchbox PXE pipeline + the bare-metal Talos node onboarding recipe |
| [secrets.md](secrets.md) | Secrets platform how-to — KeePass Tier-0 → Infisical → ESO; bootstrap order, day-2 recipes (ADR-062) |
| [ci.md](ci.md) | CI / forges two-tier model (GitHub ARC vs Forgejo act_runner), the `devbox run` seam, nix-in-CI |
| [garage.md](garage.md) | Garage S3 platform reference — deploy, layout bootstrap, LAN-only access model |
| [patterns/app-owned-resources.md](patterns/app-owned-resources.md) | How an app provisions its own buckets/keys/DBs from its own repo (ADR-074/076) |
| [slsa.md](slsa.md) | Self-hosted supply-chain (SLSA) plan — parked; Phase-1 cosign/SBOM = FU-016 |
| [sleep-iac.md](sleep-iac.md) | Blueprint: extract the sleep stack into its own IaC repo (FU-025) — AppProject tenancy, what moves, prune-safe migration |
| [cloudflare.md](cloudflare.md) | Remote-access design + build (Cloudflare Tunnel + app-security mTLS, **live**) + scoped-token RBAC |
| [github-setup.md](github-setup.md) | **GitHub org manual "required clicks"** — apps installed, tokens/PATs + their gaps, runner-group + fork-PR + public-repo toggles; the click-only bootstrap checklist |
| [github-runner-bootstrap.md](github-runner-bootstrap.md) | ARC self-hosted runner bootstrap (App → install → secrets → scaleset); the `runs-on: homelab-ephemeral` path |
| [network-physical.md](network-physical.md) | Cabling / switch layout (distinct from the logical IP view) |
| [power-measurements.md](power-measurements.md) | Node max-power (stress) + perf/watt benchmarks |
| [../machines/README.md](../machines/README.md) | Machine inventory + perf/watt table (generated from `machines/machines.yaml`) |

## Services

| Service | Doc | Summary |
|---|---|---|
| Office plants (irrigation) | [office-plants/](office-plants/README.md) | PricelessToolkit Droplet (ESP32) auto-waters 4 plants; thresholds & per-plant run-times in Home Assistant |

## Conventions

- One directory per service under `docs/`, each with a `README.md` written from a service
  perspective (what's deployed, how to configure, how to maintain, dependencies, risks, next steps).
- Diagrams as **Mermaid** (renders on GitHub) — prefer C4 context/container levels.
- Images go in the service's `images/` subdir, compressed (~1280 px, target <300 KB).
