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
| **Garage (S3)** | 🟢 LIVE | S3-compatible object store | `https://s3.teststuff.net` (region `garage`, path-style) · `garage.garage.svc:3900` | app-owned buckets → [pattern](docs/patterns/app-owned-resources.md), [`docs/garage.md`](docs/garage.md); ADR-031/073/074/075. `argocd/platform/garage.yaml` (migrated off tofu 2026-08-04); ⚠ no offsite backup — FU-137 |
| **Longhorn** | 🟢 LIVE | Replicated block storage, four tiers (ADR-089 + its 2026-08-07 addendum): `longhorn` (default, **std** 2-replica across THREE zones since wk-02 rejoined the tier — ≈80Gi of new 2-replica volumes available, up from ≈10Gi), `longhorn-bulk` (**bulk** 2-replica across wk-metal-01 + wk-metal-04 — 706G allocatable but ≈90% committed: Garage data 150Gi and the deliberately-oversized registry mirrors take most of it, so **a new bulk grant is a capacity decision, ask first**), `longhorn-fast` (Optane scratch, replica=1, ≈4Gi), `longhorn-scratch` (per-ride throwaway, replica=1 on the bulk disks — the docker-ride dind block PVCs, FU-081; transient ≤20Gi×3 per docker repo, now quota-capped) | StorageClasses `longhorn`, `longhorn-bulk`, `longhorn-fast`, `longhorn-scratch` | PVCs, capped per namespace by the AgentStack claim's `storage` block; ADR-030/089 |
| **Home Assistant** | 🟢 LIVE | Home automation + state/metrics API | `192.168.40.10:8123` · `homeassistant.teststuff.net` · remote `ha.teststuff.net` (mTLS) | ADR-040; `docs/cloudflare.md` |
| **Grafana** | 🟢 LIVE | Dashboards — a stack ships its own from its chart (`grafana_dashboard: "1"` ConfigMap in its namespace, `grafana_folder: <stack>` annotation for a folder) | `192.168.40.11` · `grafana.teststuff.net` | ADR-042 · **how a stack consumes Prometheus/Grafana/Alertmanager: [`docs/patterns/observability.md`](docs/patterns/observability.md)** |
| **Prometheus** | 🟢 LIVE | Metrics TSDB — the HA scrape job + every cluster ServiceMonitor/PodMonitor/PrometheusRule (selectors are cluster-wide) | `192.168.40.13:9090` · `prometheus.teststuff.net` | ADR-042 origin (HA-only then); `argocd/platform/kube-prometheus-stack.yaml` (+ `values/`) — migrated off tofu 2026-08-04, so **alert rules are an ordinary GitOps PR now** — every expr promtool-parsed in `ci` (`devbox run prometheus-rules-lint`, 2026-08-11) |
| **Alertmanager** | 🟢 LIVE | Alerting | `192.168.40.14:9093` · `alertmanager.teststuff.net` | ADR-042 |
| **Loki + Alloy (logs)** | 🟢 LIVE | Log aggregation — Alloy DaemonSet → Loki on Garage S3. Chunks are retained **30 days** (`retention_period: 720h`) but queries are capped at **7 days** (`max_query_lookback: 168h`) — the 7d figure is the query horizon, not retention. ⚠ **MULTI-TENANT since 2026-08-27** (ADR-118 step 2): **tenant == namespace**, and every request — read AND write — must carry `X-Scope-OrgID` or it is **401**. One tenant per request; `a\|b\|c` reads several at once but breaks Live tail. Pre-flip history is under tenant `fake` until ~2026-09-03 | in-cluster `loki.loki.svc:3100` **+ an `X-Scope-OrgID: <namespace>` header** · LAN/VPN scoped door `https://192.168.40.32:8443` (token + header, per-namespace RBAC) · query in **Grafana** (Explore → Loki datasource, header pre-set) | ADR-083 (raw manifests); `argocd/resources/loki/` — covers all pods incl. ephemeral/deleted. **Scoped reads for callers OUTSIDE the cluster are LIVE** at `https://192.168.40.32:8443` (ADR-118 step 3) — a kube-rbac-proxy door: bearer a ServiceAccount token, assert `X-Scope-OrgID: <namespace>`, get that namespace's logs or **403**. Read API only (a push is 404); self-signed cert, so `curl -k`. Recipe: [`docs/loki-tenancy.md`](docs/loki-tenancy.md) §How a stack jail reads its logs |
| **Forgejo** | 🟢 LIVE | Self-hosted Git | `forgejo.teststuff.net` (HTTPS + SSH :22) · `192.168.40.15:3000` | no ADR; `argocd/platform/forgejo.yaml` (CNPG-backed; migrated off tofu 2026-08-04); cutover plan FU-007 |
| **UniFi Network App** | 🟢 LIVE | Network controller | `192.168.40.12` (8443/8080/3478/10001) · `ubiquiti.teststuff.net` | ADR-043 |
| **Cilium** | 🟢 LIVE | CNI · BGP · LB-IPAM (VIPs from `192.168.40.0/24`) | in-cluster | — |
| **Per-stack subdomain delegation** | 🟢 LIVE | Cilium Gateway API — a stack gets `*.<stack>.teststuff.net` delegated to its own in-cluster Gateway; add hostnames as **HTTPRoutes in your `-iac` repo** (no homelab change). **Opt-in** per stack. Delegated, all three end-to-end: **oracle** (`3.22 ↔ 40.22` — `specs.oracle`/`mcp.oracle`) · **sleep** (`3.26 ↔ 40.26`, wired 2026-07-27 — `specs.sleep` routing since 2026-07-28) · **circles** (`3.28 ↔ 40.28`, homelab half 2026-08-04, circles-iac Gateway + `specs.circles` the same day — plus per-PR `specs-<n>.circles` preview routes). | `cilium` GatewayClass in-cluster · HAProxy wildcard-cert frontend → the stack's gateway VIP | ADR-092; homelab `stack_gateways` in `ansible/group_vars/opnsense.yml`, `argocd/platform/gateway*.yaml` + `*-gateway-refgrant.yaml` |
| **metrics-server** | 🟢 LIVE | `kubectl top` / HPA | in-cluster | `argocd/platform/metrics-server.yaml` (migrated off tofu 2026-08-04, the ArgoCD-lever canary) |
| **ArgoCD** | 🟢 LIVE | GitOps CD (reconciles `argocd/` from GitHub) | `argocd.teststuff.net` · in-cluster | ADR-005; `argocd/README.md` |
| **Postgres (CloudNativePG)** | 🟢 LIVE | Relational DB — per-app HA `Cluster` CRs | in-cluster `<cluster>-rw.<ns>.svc:5432` | ADR-046; consumer card [`docs/postgres.md`](docs/postgres.md) |
| **Infisical** | 🟢 LIVE | Secrets manager (the source ESO reads) | `infisical.teststuff.net` · in-cluster | ADR-062; `devbox run infisical-secret`, [`docs/secrets.md`](docs/secrets.md) |
| **External Secrets Operator** | 🟢 LIVE | Syncs Infisical → native k8s Secrets | in-cluster (`ClusterSecretStore` `infisical`) | ADR-062; [`docs/secrets.md`](docs/secrets.md) |
| **Crossplane (+ provider-terraform)** | 🟢 LIVE | Reconciles app-owned resources (Garage buckets/keys) from `Workspace` CRs | in-cluster | ADR-076; [`docs/patterns/app-owned-resources.md`](docs/patterns/app-owned-resources.md) |
| **CI runner — ephemeral** | 🟢 LIVE | Self-hosted GitHub Actions runners (ARC, ephemeral laptop tier) | org scaleset · in-cluster (`arc-systems`/`arc-runners`) | `runs-on: homelab-ephemeral`; a **public** repo needs runner-group "Allow public repositories" → [`docs/github-setup.md`](docs/github-setup.md), [`docs/github-runner-bootstrap.md`](docs/github-runner-bootstrap.md) |
| **CI runner — Proxmox VM** | 🟢 LIVE | Real-kernel runner for image builds (arm64 emulation, k3d/Docker) | `ci-runner-01` @ 192.168.2.55 | `runs-on: [self-hosted, proxmox-vm]`; ADR-082 — builds needing Docker/binfmt |
| **OpenRouter keys (operator)** | 🟢 LIVE | Mints per-project, budget-capped OpenRouter API keys → writes them to a Secret | in-cluster (`openrouter-operator`, kopf) | declare an `OpenRouterKey` CR ([repo](https://github.com/teststuffstash/openrouter-operator)); replaces the cloudopsworks TF provider (issue #20) — see app-owned-resources.md |
| **Nix cache (pull-through)** | 🟢 LIVE | nginx mirror of `cache.nixos.org` on a Longhorn PVC — speeds agent-sandbox `devbox install` | in-cluster `nixcache.nix-cache.svc`; BGP VIP `192.168.40.23` (kata rides, FU-073e) | agent-base entrypoint sets it as a nix substituter (`NIX_CACHE_URL` overrides — the launcher passes the VIP in docker mode); `argocd/resources/nix-cache/` |
| **Registry mirrors (pull-through)** | 🟢 LIVE | `registry:3` proxy caches of docker.io + ghcr.io + mcr.microsoft.com — LAN-speed image pulls for docker-mode agent rides, k3d/kind CI gates, VMs | `http://192.168.40.20` (docker.io) · `http://192.168.40.21` (ghcr) · `http://192.168.40.31` (mcr — the MS Playwright image et al., 2026-08-26) — BGP VIPs, kata-reachable; HTTP → list under `insecure-registries` | dockerd: `registry-mirrors` (Hub only); k3d/kind gate scripts read `REGISTRY_MIRROR_DOCKER_IO`/`REGISTRY_MIRROR_GHCR`/`REGISTRY_MIRROR_MCR` env (set by docker-mode pods); ADR-091, `argocd/resources/registry-cache/` |
| **Registry (first-party, push-mode)** | 🟢 LIVE | `registry:3` on Garage S3 — where first-party artifacts too big/hot for ghcr get PUSHED (the oracle `ert-corpus` class, 6.4GB/release). **Anonymous LAN pull, authenticated push** (htpasswd, non-GET/HEAD only); real LE cert so containerd needs zero insecure-registry config | `https://registry.teststuff.net` (HAProxy `3.33` ↔ LB `40.33`; plain HTTP on the VIP for in-cluster/kata) | ADR-121 (FU-196 v1); `argocd/resources/registry/`; push cred: Infisical `REGISTRY_PUSH_TOKEN` (user `releaser`) |
| **Devbox search proxy** | 🟢 LIVE | nginx cache of the Devbox package-search API (`search.devbox.sh`) — lets agent rides `devbox add` a NEW package **in-band** (WAN-free; the resolver returns store paths, so the LAN nix cache serves the binary) instead of writing an offline `placeholder-*` lock that boot-crashes the next round | BGP VIP `192.168.40.27` (kata-reachable) | rides set `DEVBOX_SEARCH_HOST=http://192.168.40.27` (launcher, agent-session.sh); `proxy_cache 6h` + `limit_req`; FU-118(b), `argocd/resources/devbox-search/` |
| **AgentStack (XRD)** | 🟢 LIVE | Agents framework as a platform API — one claim per stack renders its fixer infra (budget key, git token, worker egress netpol, proxy RBAC) | in-cluster: `kubectl get agentstacks` · `kubectl explain agentstacks.spec` · usage doc `kubectl get cm -n crossplane-system agentstack-docs -o jsonpath='{.data.USAGE\.md}'` | declare `kind: AgentStack` in your `-iac` repo; [`docs/agents/agentstack.md`](docs/agents/agentstack.md); FU-048/ADR-085 |
| **OpenRouter egress proxy / model router** | 🟢 LIVE | The agent fleet's ONLY OpenRouter path (ADR-081/087) + the ADR-096 router: `POST /route` (class/floors/strikes/cooldowns), `/report`, `/router-status`, loop-git token broker | in-cluster `openrouter-proxy.agent-egress.svc:8080` | `argocd/resources/openrouter-proxy/` · [`docs/agents/model-routing.md`](docs/agents/model-routing.md) |
| **OpenCode usage ingest** | 🟢 LIVE | Go-rail usage metering ingest — token-gated `POST /go-usage-report` for jail self-metering (ADR-108); anonymous POST → 403 (verified 2026-08-30) | `192.168.40.30:8081` (LAN → jail push; token-gated) | #438/ADR-108 |
| **OTel collector (OTLP sink)** | 🟢 LIVE | OTLP metrics+logs → Prometheus + Loki (the claude-code agent roles' telemetry rail) | in-cluster `otel-collector.monitoring.svc:4317` (grpc) / `:4318` (http) · LAN `192.168.40.29:4318` (jail telemetry door, 2026-08-08) | `argocd/resources/otel-collector/`; [`docs/agents/observability-and-retro.md`](docs/agents/observability-and-retro.md) §A0 |
| **Agent transcripts** | 🟢 LIVE | Every agent session persisted to S3 (`<project>/<task>/<role>-r<n>-<ts>/` + manifest) + a browse UI (LAN-only — transcripts carry repo content) | bucket `agent-transcripts` (Garage) · `https://transcripts.local.teststuff.net` | [`docs/agents/observability-and-retro.md`](docs/agents/observability-and-retro.md) §A1/§A2; `agents/coordinator/{garage-workspace,transcripts-viewer,transcripts-sync}.yaml` |
| **GitHub Apps page** | 🟢 LIVE | Declared-vs-live GitHub App permissions + install matrix, rendered per poll by the github-exporter (FU-098 — the change-flow companion: PR `docs/github-apps.yaml`, the `GithubAppPermissionDrift` alert rings until the grant lands) | **`https://apps.teststuff.net/apps`** (HTML; `/apps.md` raw) · in-cluster `github-exporter.monitoring.svc:9504` | declared source [`docs/github-apps.yaml`](docs/github-apps.yaml); `argocd/resources/github-exporter/` |
| **Argo Workflows + Events** | 🟢 LIVE | The platform **orchestration engine** (ADR-093, agent-loop-first) — CronWorkflows/WorkflowTemplates + event triggers (JetStream EventBus). The agent-loop reflexes run on it; a stack opts its namespace in (`argo.enabled`) to run its own DAGs. **Garage is the S3 artifact repository.** Metrics + DAG UI for free. | **`argo.teststuff.net`** (UI/API — HAProxy `3.24` ↔ LB `40.24`, server-auth LAN-trust; exposed 2026-07-21) · ns `argo` / `argo-events`; metrics → Prometheus | `argocd/platform/argo-{workflows,events}.yaml` · artifact repo `argocd/resources/argo-artifacts/` · ADR-093; the agent-loop reflexes in `agents/coordinator/{reflexes,review}-argo.yaml` |
| **OIDC IDP** | 🔴 PLANNED | Auth for "Others" | — not deployed | ADR-055 |

## Consuming a LIVE service

- **Object storage (Garage):** your app **owns its buckets** — declare them in your repo's `infra/`
  and consume the key. Full recipe: [`docs/patterns/app-owned-resources.md`](docs/patterns/app-owned-resources.md).
  Reach data at `https://s3.teststuff.net` (region `garage`, path-style) with your key.
- **Storage (Longhorn):** request a PVC with `storageClassName: longhorn` (small, replicated),
  `longhorn-bulk` (large volumes: S3 data, backups, datasets) or `longhorn-fast` (Optane SCRATCH: single-node replica-1, modest speed — intent is disk-write-heavy pods (CI builds), NEVER load-bearing data/metadata; FU-159 ruling 2026-08-11).
  **Your cap comes from your stack's AgentStack claim** (`spec.repos[].storage`, ADR-089) — an
  over-cap PVC fails at creation with a quota error; ask for a bigger grant via the claim, checked
  against the advertised tier ceilings above. Buckets: state `max_size` on every `garage_bucket`.
- **Secrets (Infisical → ESO):** put the value in Infisical (`devbox run infisical-secret K=V`) and
  pull it into your namespace with an `ExternalSecret` against the `infisical` `ClusterSecretStore`.
  Full recipe: [`docs/secrets.md`](docs/secrets.md). Never commit secret values (repos are public).
- **Orchestration (Argo Workflows):** opt your stack's namespace in with `argo.enabled: true` on its
  AgentStack claim (`spec.repos[].argo`, ADR-093) — the platform renders a `argo-workflow` SA +
  `workflowtaskresults` RBAC there. Then author your **WorkflowTemplates/CronWorkflows** (the DAG +
  step images are *your* policy) with `serviceAccountName: argo-workflow`; artifacts pass via Garage
  (S3 artifact repo, rendered per-namespace when a multi-step DAG needs it). Mechanism = platform,
  policy = stack (ADR-085). First consumer: oracle-fleet ingestion.
- **Database (Postgres/CNPG):** declare a `postgresql.cnpg.io/v1` `Cluster` in your namespace; consume
  the **CNPG-generated** `<cluster>-app` secret (minted by the CloudNativePG k8s operator, not a
  human). Consumer card: [`docs/postgres.md`](docs/postgres.md); example: `argocd/resources/postgres/`.
- **Dashboards (Grafana):** for "me"-facing views. For non-technical "Others", see ADR-072 (gated on
  the PLANNED IDP).

## ⚠️ Depending on a PLANNED service

If your app needs the **OIDC IDP**: it **isn't there** yet (ADR-055). Don't wire auth against it; either
get it built first (a homelab change) or re-scope to what's LIVE. _(Postgres and ArgoCD used to be here
and are now 🟢 LIVE — the sleep-tracking ingester's Postgres steps are unblocked.)_

## Maintenance

Update this file **as part of deploying or removing a service** — flip the status, add the endpoint
and the consume-recipe link. A new `helm_release`/Service in `tofu/` **or `argocd/`** that isn't reflected here is a
bug in this catalog. (Live cross-check, when you really need it: `kubectl get svc -A -l bgp=advertise`
for the advertised VIPs — but the catalog, not that output, is what apps read.)
