# Loki tenancy and the scoped read door

**This doc owns per-tenant log access** — why Loki's own tenancy flag is only half the mechanism,
why the tenant is a namespace, what the components are, and the ordered rollout. The decision
record is [ADR-118](adr.md); the manifests are
[`argocd/resources/loki/`](../argocd/resources/loki/) (`loki-rbac-proxy.yaml`,
`loki-tenant-grants.yaml`, `alloy-config.yaml`, `loki-config.yaml`). Service status and endpoint:
[`SERVICES.md`](../SERVICES.md).

## The problem, stated exactly

Loki runs `auth_enabled: false`, which means one implicit tenant (`fake`). Alloy's pod discovery
carries no namespace filter and nothing guards ns `loki` at the network layer — there is no
NetworkPolicy anywhere in this repo, and no `CiliumClusterwideNetworkPolicy` at all. So
**reachability is authorisation**: anything that can open a socket to `loki.loki.svc:3100` reads
every namespace's logs.

Concretely that is other stacks' worker stdout (raw model output), `agent-coordinator`,
`agent-egress`, CNPG/Infisical/ArgoCD/cilium, and every node's `/dev/kmsg` via the kmsg-reader
DaemonSet. There is no middle state, which is why a stack jail has had **no** log access rather
than scoped access — the only alternative on offer was all of it.

Two consequences worth naming, because both look like bugs later:

- A stack's own agents cannot read their own logs either. On an `enforce: true` stack the composed
  worker CNP has a `monitoring` leg and no `loki` leg, so the path does not 403 — it **hangs**, the
  FU-020 signature.
- [`agents/coordinator/agent-read-rbac.yaml`](../agents/coordinator/agent-read-rbac.yaml)'s
  homelab#541 carve-out says kernel-log truth is platform-shipped because *"any session with LogQL
  access reads kernel-log lines with NO new RBAC, NO talosctl."* That is the only occurrence of
  "LogQL" in the platform. No script, env var, egress leg or runbook recipe provided it — the
  carve-out's value proposition was unreachable by the lane it was written for. This doc is what
  makes that sentence true.

## `auth_enabled: true` is the data model, not the enforcement

The flag's name is misleading and the misreading is expensive, so: **it does not make Loki
authenticate anything.** It makes Loki *require and trust* `X-Scope-OrgID`, and upstream's design
expects an authenticating reverse proxy in front. Flip the flag and hand a caller direct reach, and
it sets `X-Scope-OrgID: platform` and reads the platform's logs. Same blast radius, one header away.

So the end state is tenancy **plus** exactly one trusted hop that derives the header's legitimacy
from an authenticated identity. They are two halves of one mechanism.

What tenancy buys the hop is worth stating, because it is the argument for doing the data model at
all rather than only the gate: with tenancy the hop **authorizes one header value**. Without it, the
hop must parse and rewrite LogQL — a security-critical parser, kept correct forever against label
matchers, line filters, subqueries and `absent_over_time`, where one bug is full disclosure and the
chunks are co-mingled in storage regardless. Header check versus parser is the whole difference.

Two wins that are not access control, and that justify the flip on their own:

- **Per-tenant ingest limits.** homelab#811 was one emitter at 48.7 GiB/day — 98% of ingest — which
  filled the Garage bucket in six days. A per-tenant rate limit contains that to its own tenant.
- **Per-tenant retention.** Today `retention_period` is one global number (720h) with a global
  `max_query_lookback` (168h) under it.

## Why tenant == namespace

The read door authorizes with kube-rbac-proxy's SubjectAccessReview rewrite, and its splitting
behaviour decides this. Verified against the v0.22.1 source (`pkg/proxy/proxy.go`
`GetRequestAttributes`, `pkg/filters/auth.go`) rather than the docs, because three properties are
load-bearing and none are obvious:

| property | behaviour |
|---|---|
| multi-value | collected **per header occurrence**, not per delimiter — one SAR per occurrence |
| combination | **AND** — the filter loops the attributes and 403s on the first non-allow |
| missing header | **fail-closed** — `len(allAttrs) == 0` → HTTP 400, never a pass-through |

Loki's multi-tenant read syntax is `X-Scope-OrgID: a|b|c`, which is **one** value. It would
authorize against a namespace literally named `a|b|c`, which nothing grants. Sending repeated header
lines gives clean per-tenant SARs, but Go joins repeated headers as `a, b` on the wire, which is not
Loki's syntax either.

So a caller queries **one tenant per request**, and the tenant that costs nothing to derive is the
namespace: Alloy stamps it with `loki.process` + `stage.tenant { label = "namespace" }`, reading the
`namespace` label the pod relabel already sets — no mapping table anywhere, and nothing to update
when a stack gains a namespace.

⚠ **It must be that component, not a relabel rule**, and the first cut got this wrong: setting
`__tenant_id__` in `discovery.relabel` silently did nothing, because `__`-prefixed labels are TARGET
metadata and are dropped before entries reach `loki.write`. Alloy's own metric read
`loki_write_sent_entries_total{tenant=""}` and the upstream docs say it outright — *"If no
`tenant_id` is provided, the component assumes that the Loki instance at `endpoint` is running in
single-tenant mode and no `X-Scope-OrgID` header is sent."* Caught by probing a running pod before
the flip; shipped together, Loki would have rejected every push and cluster-wide ingest would have
stopped.

The rejected alternative was tenant == stack, which matches the platform's ownership unit
(`docs/agents/platform-and-stacks.md` §Why per-stack) and would let one query span a stack. It needs
a namespace→stack map inside Alloy's config — a **second reader** of the AgentStack claims, beside
`coordinator-scan.sh`'s `stacks_json()`, and a silent mis-tenanting whenever a namespace does not
match its stack's name. Paying that to avoid three queries instead of one is the wrong trade at this
size. Revisit if a consumer appears that genuinely needs cross-namespace LogQL in a single query.

## The components

| piece | what it does |
|---|---|
| `alloy-config.yaml` | `loki.process` + `stage.tenant { label = "namespace" }` between the source and the write — the tenant is stamped per ENTRY, not per discovery target (see the warning above) |
| `loki-config.yaml` | `auth_enabled: true`; per-tenant ruler rule directories |
| `loki-rbac-proxy.yaml` | kube-rbac-proxy: TokenReview → SubjectAccessReview (namespace rewritten from `X-Scope-OrgID`) → proxy to Loki. `--allow-paths` restricted to the READ surface |
| `loki-tenant-grants.yaml` | one RoleBinding per (consumer, tenant) — the entire access-control surface |
| `grafana-loki-datasource.yaml` | the operator's all-tenant datasource, header-pinned |

**The caller self-asserts the tenant and is then authorized for it.** Assert one you have no
RoleBinding for and the answer is 403, not that tenant's logs — the property plain `auth_enabled:
true` lacks. And because the authorized string and the string Loki reads are the same, there is no
authorized-for-X-queried-Y gap.

`--allow-paths` is not hygiene: without it the door proxies Loki's push endpoint too, and a
tenant-scoped *reader* could **write** log lines — forging evidence in the store an incident is
later reconstructed from.

## Rollout

Ordered so the irreversible step is verified rather than leapt, and so no step leaves a gate that
looks real and is not.

| # | change | what it verifies before the next step |
|---|---|---|
| 1 | Alloy `stage.tenant`; the proxy, its RBAC, the grants — **ClusterIP only, no VIP** | `loki_write_*{tenant="<namespace>"}` on a running Alloy — verified AT THE SENDER, because a single-tenant Loki overrides the header to `fake` and can never confirm it. Ingest unchanged; nothing is served, so nothing can regress |
| 2 | `auth_enabled: true`; per-tenant ruler dirs; Grafana datasource header | Grafana Explore still returns logs; `LokiPodLogVolumeHigh` still evaluates; Alloy pushes are accepted (a rejected push is the failure mode to watch — Alloy retries, so a short outage loses nothing) |
| 3 | the LoadBalancer VIP + the jail's usage note | the oracle workbench SA reads `oracle-fleet` and is **refused** `platform` |

**Step 1 must not be exposed.** Until step 2 flips the flag, Loki ignores `X-Scope-OrgID` entirely
and would return every tenant's logs to a caller this proxy authorized for one. That is the one
configuration in this design that is worse than doing nothing, because it looks like a gate.

**Rollback** is per step and cheap: revert the ConfigMap and restart. Alloy buffers and retries, so
a Loki restart costs latency, not lines.

**Existing chunks stay under tenant `fake`.** They are readable by naming it, and with a 168h
`max_query_lookback` the old tenant stops mattering within a week — a cutover that completes itself.

## Tightening — what this deliberately does not do

Loki keeps its ordinary ClusterIP for in-cluster writes (Alloy) and reads (Grafana). **In-cluster
reach is exactly as it was**, so nothing existing can regress — and the door is therefore
**bypassable from inside the cluster by construction**. That is an accepted limitation while the
consumer set is one stack jail's SA, not a defect to file.

Closing it, when in-cluster agents are wired, is three moves that must land together:

1. bind Loki to `127.0.0.1` (and move the probes off the pod IP, which they currently use);
2. route Alloy's **writes** through a write-side gate — otherwise ingest becomes unauthenticated
   while reads look gated, which is the worst of both;
3. point the Grafana datasource at the proxy.

Doing these piecemeal is how a half-move ships. Until then the honest description of this component
is *"a scoped door for callers outside the cluster"*, not *"Loki is locked down"*.

## The supply-chain trade, recorded

kube-rbac-proxy is **not** a kubernetes-sigs project. It self-describes as alpha (*"flags,
configuration, behavior and design may change significantly in following releases"*), its security
updates are *"best effort"*, and its `sig-auth-acceptance` rework has not been touched since
2025-10-01. kubebuilder removed it from default scaffolding on exactly those grounds — GCR hosting,
*"yet to be part of the Kubernetes ecosystem umbrella"*, and unwillingness to promote third-party
artefacts.

Adopted anyway, as a considered trade rather than a default choice:

- authorization becomes **declarative RBAC** rather than code — auditable with `kubectl auth can-i`,
  and renderable per-namespace by the AgentStack Composition when a second stack wants it;
- the release cadence is real (v0.22.1, 2026-07-09) and Red Hat maintains an active fork;
- the SAR-rewrite feature this design rests on **survives** the acceptance rework — it is promoted
  to a first-class `pkg/authorization/rewrite` package on that branch, not deprecated;
- the failure mode is *"jail log reads stop"*, never a cluster fault.

The alternatives lost for reasons that are properties of this cluster, not of them: Traefik
ForwardAuth means a second ingress controller beside Cilium Gateway API and OPNsense HAProxy;
Gateway API `ext_authz` is not first-class in Cilium's implementation (raw `CiliumEnvoyConfig`);
oauth2-proxy is OIDC and needs the IdP that is still PLANNED (ADR-055), and the callers here are
ServiceAccounts, not humans; a mesh is ruled out standing (*"NOT a service mesh… Native; no
Istio"*). Extending the egress proxy with a bespoke endpoint was the near miss — it already
TokenReviews callers for `/loop-git-token` — but it is bespoke because it also **injects a
credential**, which a read gate never does.
