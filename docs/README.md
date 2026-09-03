# Homelab documentation

Service- and operations-level docs for the homelab. Infrastructure-as-code lives elsewhere
in the repo (`tofu/`, `ansible/`, `esphome/`, `homeassistant/`); these pages describe how the
running services fit together, how to operate them, and their risks.

## Which record am I writing?

Several long-lived records live here and they are **not** interchangeable — the routing table in
[`../CLAUDE.md`](../CLAUDE.md) ("Where things get written down") is the authority. In short:
**decision** → `adr.md` · **design** → a doc here · **loose end** → `follow-ups.md` (≤10 lines,
detail goes in a doc) · **program** → `../ROADMAP.md` · **it broke** → `incidents/` ·
**unsettled investigation** → `spikes/` · **vocabulary** → `glossary.md` (a NEW name clears it
first) · **skill shortcoming** → `.claude/skills/GAPS.md` (ADR-105).

## Operations & design

| Doc | Summary |
|---|---|
| [adr.md](adr.md) | **Architecture Decision Record** — what was considered (e.g. Ceph vs Longhorn) and what was chosen, with rationale. Start here for *why*. |
| [glossary.md](glossary.md) | **Term → one meaning → owning doc** — the vocabulary index; collisions carry their ruled replacement, and a NEW name clears it first (FU-163) |
| [agents/](agents/README.md) | **Agent platform** — an interactive meta-coordinator in the jail + an autonomous per-stack loop in the cluster; roles, trust boundaries, testing doctrine, and the sub-doc index |
| [runbook.md](runbook.md) | Day-to-day operational recipes — devbox, OPNsense-as-code, DHCP/DNS, storage, CNPG, HA, UniFi, Cloudflare, ESPHome — and the gotchas behind them |
| [follow-ups.md](follow-ups.md) | **The FU tracker** — every loose end / deferred item as a stable `FU-NNN` id (conventions in its header) |
| [follow-ups-archive.md](follow-ups-archive.md) | Resolved-FU residue — rolling buffer (≈a month) of archived items, trimmed to the grep residue |
| [incidents/](incidents/README.md) | **Postmortems** — one file per incident: timeline, root cause, collateral, fixes, probe lesson. The FU carries only the residual work |
| [spikes/](spikes/) | Investigations with no decision yet — findings + what would settle it |
| [storage-ledger.md](storage-ledger.md) | Who owns the SUM of each storage tier's caps + tier eligibility rulings; Longhorn metering built 2026-08-04, quota armed 2026-08-07, Garage admin metrics + belts since #965 (2026-08-25); the pve thin-pool Data% is FU-093's remaining gap |
| [provisioning.md](provisioning.md) | Matchbox PXE pipeline + the bare-metal Talos node onboarding recipe |
| [secrets.md](secrets.md) | Secrets platform how-to — KeePass Tier-0 → Infisical → ESO; bootstrap order, day-2 recipes (ADR-062) |
| [ci.md](ci.md) | CI / forges two-tier model (GitHub ARC vs Forgejo act_runner), the `devbox run` seam, nix-in-CI |
| [dependency-upgrades.md](dependency-upgrades.md) | **homelab's own dependency lifecycle** — propose → review → test/lint → rollout → monitor, per dependency class; plus what Renovate has *measurably* done here (FU-097/FU-051) |
| [renovate.md](renovate.md) | The **org-wide Renovate policy** — threat model (Trivy-style compromise), cooldown/SHA-pinning/OSV, the automerge-vs-review split, coordinator × Renovate verbs |
| [garage.md](garage.md) | Garage S3 platform reference — deploy, layout bootstrap, LAN-only access model |
| [garage-bulk-migration.md](garage-bulk-migration.md) | Garage data → longhorn-bulk migration recipe — repeats for any STS volumeClaimTemplate change |
| [patterns/public-request-flow.md](patterns/public-request-flow.md) | **The public request map** (ADR-124) — one picture per app, rendered from the platform's stage map + the app's; contract rows, the seams register, the renderer |
| [patterns/app-owned-resources.md](patterns/app-owned-resources.md) | How an app provisions its own buckets/keys/DBs from its own repo (ADR-074/076) |
| [slsa.md](slsa.md) | Self-hosted supply-chain (SLSA) plan — parked; Phase-1 cosign/SBOM = FU-016 |
| [sleep-iac.md](sleep-iac.md) | The live three-layer sleep stack + deploy pipeline (ADR-084) — AppProject tenancy, what moves, prune-safe migration |
| [oracle-iac.md](oracle-iac.md) | The oracle stack — sleep-shaped three-layer topology; records only the deltas from the sleep reference design |
| [cloudflare.md](cloudflare.md) | The public edge: PublicRoute XRD (ADR-101, armed), zone classes, the token matrix + cf-api-proxy, spend belt — plus the original tunnel+mTLS remote-access leg |
| [github-setup.md](github-setup.md) | **GitHub org manual "required clicks"** — apps installed, tokens/PATs + their gaps, runner-group + fork-PR + public-repo toggles; the click-only bootstrap checklist |
| [github-runner-bootstrap.md](github-runner-bootstrap.md) | ARC self-hosted runner bootstrap (App → install → secrets → scaleset); the `runs-on: homelab-ephemeral` path |
| [tofu-state.md](tofu-state.md) | **Where each tofu root's state lives** — the encrypted-Garage backend ruling, the cone table, the migration runbook (FU-012) |
| [ip-plan.md](ip-plan.md) | **The address-plan authority** (ADR-088) — which range a new IP/VIP comes from |
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
- A doc section other docs/code reference gets a **stable §-code heading anchor** (`### M14. …`
  referenced as `§M14`) — never reused, never renamed; hot docs only, and the `§` sigil is what
  the lint checks. Convention + mechanism: `scripts/docs-graph-lint.sh` header, check #4
  (ADR-117, S5 #982).
- Images go in the service's `images/` subdir, compressed (~1280 px, target <300 KB).
