# Platform services — catalog

**The canonical list of services the homelab cluster offers to applications.** If you're an agent in
another project asking "do I have X? how do I reach it?" — **grep this file.** It is the source of
truth.

> **Rules for agents**
> - **This repo, not the cluster, is the source of truth** (boot-from-git). Discover services by
>   grepping here — do **not** `kubectl` around the live cluster to find out what exists.
> - **`LIVE` means it exists and you may use it. `PLANNED` means it does NOT exist yet** — do not
>   write code or plans that assume a `PLANNED` service is available. If you need one, it has to be
>   built first (that's a homelab change, not an app change).
> - Service endpoints are **LAN-only** unless noted. Apps run on the home LAN (or in-cluster).
> - How to *consume* a service (provision a bucket/db/etc.) → the linked recipe, usually
>   [`docs/patterns/app-owned-resources.md`](docs/patterns/app-owned-resources.md).

## Catalog

| Service | Status | What | Reach (LAN / in-cluster) | Consume / decisions |
|---|---|---|---|---|
| **Garage (S3)** | 🟢 LIVE | S3-compatible object store | `https://s3.teststuff.net` (region `garage`, path-style) · `garage.garage.svc:3900` | app-owned buckets → [pattern](docs/patterns/app-owned-resources.md), [`docs/garage.md`]; ADR-031/073/074/075 |
| **Longhorn** | 🟢 LIVE | Replicated block storage, four tiers (ADR-089): `longhorn` (default, **std** small-disk 2-replica — new-volume ceiling ≈10Gi until the pool grows), `longhorn-bulk` (**bulk** 2-replica on the big disks — the ≈150Gi ceiling is ALLOCATED to Garage data since 2026-07-13; new bulk grants need pool growth), `longhorn-fast` (Optane scratch, replica=1, ≈4Gi), `longhorn-scratch` (per-ride throwaway, replica=1 on the bulk disks — the docker-ride dind block PVCs, FU-081; transient ≤20Gi×2) | StorageClasses `longhorn`, `longhorn-bulk`, `longhorn-fast`, `longhorn-scratch` | PVCs, capped per namespace by the AgentStack claim's `storage` block; ADR-030/089 |
| **Home Assistant** | 🟢 LIVE | Home automation + state/metrics API | `192.168.40.10:8123` · `homeassistant.teststuff.net` · remote `ha.teststuff.net` (mTLS) | ADR-040; `docs/cloudflare.md` |
| **Grafana** | 🟢 LIVE | Dashboards | `192.168.40.11` · `grafana.teststuff.net` | ADR-042 |
| **Prometheus** | 🟢 LIVE | Metrics TSDB (scrapes **only** Home Assistant) | `192.168.40.13:9090` · `prometheus.teststuff.net` | ADR-042 — not a general metrics sink |
| **Alertmanager** | 🟢 LIVE | Alerting | `192.168.40.14:9093` · `alertmanager.teststuff.net` | ADR-042 |
| **Loki + Alloy (logs)** | 🟢 LIVE | Log aggregation — Alloy DaemonSet → Loki on Garage S3, **7-day** retention | in-cluster `loki.loki.svc:3100` · query in **Grafana** (Explore → Loki datasource) | ADR-083 (raw manifests); `argocd/resources/loki/` — covers all pods incl. ephemeral/deleted |
| **Forgejo** | 🟢 LIVE | Self-hosted Git | `forgejo.teststuff.net` (HTTPS + SSH :22) · `192.168.40.15:3000` | no ADR; `tofu/forgejo.tf` (CNPG-backed); cutover plan FU-007 |
| **UniFi Network App** | 🟢 LIVE | Network controller | `192.168.40.12` (8443/8080/3478/10001) · `ubiquiti.teststuff.net` | ADR-043 |
| **Cilium** | 🟢 LIVE | CNI · BGP · LB-IPAM (VIPs from `192.168.40.0/24`) | in-cluster | — |
| **Per-stack subdomain delegation** | 🔴 PLANNED | Cilium Gateway API — a stack gets `*.<stack>.teststuff.net` delegated to its own in-cluster Gateway; add hostnames as **HTTPRoutes in your `-iac` repo** (no homelab change). **Opt-in** per stack. | `cilium` GatewayClass in-cluster · HAProxy wildcard-cert frontend → the stack's gateway VIP | ADR-092 (code landed, **rollout pending**); homelab `stack_gateways` in `ansible/group_vars/opnsense.yml`, `argocd/platform/gateway*.yaml` |
| **metrics-server** | 🟢 LIVE | `kubectl top` / HPA | in-cluster | — |
| **ArgoCD** | 🟢 LIVE | GitOps CD (reconciles `argocd/` from GitHub) | `argocd.teststuff.net` · in-cluster | ADR-005; `argocd/README.md` |
| **Postgres (CloudNativePG)** | 🟢 LIVE | Relational DB — per-app HA `Cluster` CRs | in-cluster `<cluster>-rw.<ns>.svc:5432` | ADR-046; declare a CNPG `Cluster` in your namespace |
| **Infisical** | 🟢 LIVE | Secrets manager (the source ESO reads) | `infisical.teststuff.net` · in-cluster | ADR-062; `devbox run infisical-secret`, [`docs/secrets.md`](docs/secrets.md) |
| **External Secrets Operator** | 🟢 LIVE | Syncs Infisical → native k8s Secrets | in-cluster (`ClusterSecretStore` `infisical`) | ADR-062; [`docs/secrets.md`](docs/secrets.md) |
| **Crossplane (+ provider-terraform)** | 🟢 LIVE | Reconciles app-owned resources (Garage buckets/keys) from `Workspace` CRs | in-cluster | ADR-076; [`docs/patterns/app-owned-resources.md`](docs/patterns/app-owned-resources.md) |
| **CI runner — ephemeral** | 🟢 LIVE | Self-hosted GitHub Actions runners (ARC, ephemeral laptop tier) | org scaleset · in-cluster (`arc-systems`/`arc-runners`) | `runs-on: homelab-ephemeral`; a **public** repo needs runner-group "Allow public repositories" → [`docs/github-setup.md`](docs/github-setup.md), [`docs/github-runner-bootstrap.md`](docs/github-runner-bootstrap.md) |
| **CI runner — Proxmox VM** | 🟢 LIVE | Real-kernel runner for image builds (arm64 emulation, k3d/Docker) | `ci-runner-01` @ 192.168.2.55 | `runs-on: [self-hosted, proxmox-vm]`; ADR-082 — builds needing Docker/binfmt |
| **OpenRouter keys (operator)** | 🟢 LIVE | Mints per-project, budget-capped OpenRouter API keys → writes them to a Secret | in-cluster (`openrouter-operator`, kopf) | declare an `OpenRouterKey` CR ([repo](https://github.com/teststuffstash/openrouter-operator)); replaces the cloudopsworks TF provider (issue #20) — see app-owned-resources.md |
| **Nix cache (pull-through)** | 🟢 LIVE | nginx mirror of `cache.nixos.org` on a Longhorn PVC — speeds agent-sandbox `devbox install` | in-cluster `nixcache.nix-cache.svc`; BGP VIP `192.168.40.23` (kata rides, FU-073e) | agent-base entrypoint sets it as a nix substituter (`NIX_CACHE_URL` overrides — the launcher passes the VIP in docker mode); `argocd/resources/nix-cache/` |
| **Registry mirrors (pull-through)** | 🟢 LIVE | `registry:3` proxy caches of docker.io + ghcr.io — LAN-speed image pulls for docker-mode agent rides, k3d/kind CI gates, VMs | `http://192.168.40.20` (docker.io) · `http://192.168.40.21` (ghcr) — BGP VIPs, kata-reachable; HTTP → list under `insecure-registries` | dockerd: `registry-mirrors` (Hub only); k3d/kind gate scripts read `REGISTRY_MIRROR_DOCKER_IO`/`REGISTRY_MIRROR_GHCR` env (set by docker-mode pods); ADR-091, `argocd/resources/registry-cache/` |
| **AgentStack (XRD)** | 🟢 LIVE | Agents framework as a platform API — one claim per stack renders its fixer infra (budget key, git token, worker egress netpol, proxy RBAC) | in-cluster: `kubectl get agentstacks` · `kubectl explain agentstacks.spec` · usage doc `kubectl get cm -n crossplane-system agentstack-docs -o jsonpath='{.data.USAGE\.md}'` | declare `kind: AgentStack` in your `-iac` repo; [`docs/agents/agentstack.md`](docs/agents/agentstack.md); FU-048/ADR-085 |
| **OTel collector (OTLP sink)** | 🟢 LIVE | OTLP metrics+logs → Prometheus + Loki (the claude-code agent roles' telemetry rail) | in-cluster `otel-collector.monitoring.svc:4317` (grpc) / `:4318` (http) | `argocd/resources/otel-collector/`; [`docs/agents/observability-and-retro.md`](docs/agents/observability-and-retro.md) §A0 |
| **Agent transcripts** | 🟢 LIVE | Every agent session persisted to S3 (`<project>/<task>/<role>-r<n>-<ts>/` + manifest) + a browse UI (LAN-only — transcripts carry repo content) | bucket `agent-transcripts` (Garage) · `https://transcripts.local.teststuff.net` | [`docs/agents/observability-and-retro.md`](docs/agents/observability-and-retro.md) §A1/§A2; `agents/coordinator/{garage-workspace,transcripts-viewer,transcripts-sync}.yaml` |
| **OIDC IDP** | 🔴 PLANNED | Auth for "Others" | — not deployed | ADR-055 |

## Consuming a LIVE service

- **Object storage (Garage):** your app **owns its buckets** — declare them in your repo's `infra/`
  and consume the key. Full recipe: [`docs/patterns/app-owned-resources.md`](docs/patterns/app-owned-resources.md).
  Reach data at `https://s3.teststuff.net` (region `garage`, path-style) with your key.
- **Storage (Longhorn):** request a PVC with `storageClassName: longhorn` (small, replicated),
  `longhorn-bulk` (large volumes: S3 data, backups, datasets) or `longhorn-fast` (Optane scratch).
  **Your cap comes from your stack's AgentStack claim** (`spec.repos[].storage`, ADR-089) — an
  over-cap PVC fails at creation with a quota error; ask for a bigger grant via the claim, checked
  against the advertised tier ceilings above. Buckets: state `max_size` on every `garage_bucket`.
- **Secrets (Infisical → ESO):** put the value in Infisical (`devbox run infisical-secret K=V`) and
  pull it into your namespace with an `ExternalSecret` against the `infisical` `ClusterSecretStore`.
  Full recipe: [`docs/secrets.md`](docs/secrets.md). Never commit secret values (repos are public).
- **Database (Postgres/CNPG):** declare a `postgresql.cnpg.io/v1` `Cluster` in your namespace; consume
  the operator-generated `<cluster>-app` secret (or supply your own). Example: `argocd/resources/postgres/`.
- **Dashboards (Grafana):** for "me"-facing views. For non-technical "Others", see ADR-072 (gated on
  the PLANNED IDP).

## ⚠️ Depending on a PLANNED service

If your app needs the **OIDC IDP**: it **isn't there** yet (ADR-055). Don't wire auth against it; either
get it built first (a homelab change) or re-scope to what's LIVE. _(Postgres and ArgoCD used to be here
and are now 🟢 LIVE — the sleep-tracking ingester's Postgres steps are unblocked.)_

## Maintenance

Update this file **as part of deploying or removing a service** — flip the status, add the endpoint
and the consume-recipe link. A new `helm_release`/Service in `tofu/` that isn't reflected here is a
bug in this catalog. (Live cross-check, when you really need it: `kubectl get svc -A -l bgp=advertise`
for the advertised VIPs — but the catalog, not that output, is what apps read.)
