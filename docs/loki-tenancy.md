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
  makes that sentence reachable — **but not yet true for a stack jail**, and the gap is a
  consequence of tenant == namespace: `kmsg-reader` is a DaemonSet in namespace `loki`, so kernel
  lines land in tenant **`loki`** (verified 2026-08-27: 11 kmsg streams under that tenant, zero
  under any other). Granting a jail that tenant would hand it the log store's own namespace, so no
  jail has it, and "any session with LogQL access reads kernel-log lines" still does not hold for
  the sessions the carve-out was written for. **FU-194** carries the fix.

## `auth_enabled: true` is the data model, not the enforcement

The flag's name is misleading and the misreading is expensive, so: **it does not make Loki
authenticate anything.** It makes Loki *require and trust* `X-Scope-OrgID`, and upstream's design
expects an authenticating reverse proxy in front. Flip the flag and hand a caller direct reach, and
it sets `X-Scope-OrgID: platform` and reads the platform's logs. Same blast radius, one header away.

So the end state is tenancy **plus** exactly one trusted hop that derives the header's legitimacy
from an authenticated identity. They are two halves of one mechanism.

The same sentence has a **write-side** consequence that is easy to miss and expensive to miss: if
the header must be present, then *every writer* must send one or its pushes 401. There are **two**,
and only one of them lives in `argocd/resources/loki/`:

| writer | tenant | how |
|---|---|---|
| Alloy DaemonSet | the pod's namespace | `stage.tenant` per entry (`alloy-config.yaml`) |
| OTel collector (the A0 telemetry rail) | static `monitoring` | exporter header (`otel-collector/otel-config.yaml`) |

The collector was found during step 2 by grepping for the push endpoint rather than by reading the
loki directory; it forwards OTLP from claude-code roles across stacks, so it has no namespace to
derive a tenant from and takes a static one — the collector's own namespace, which keeps the
invariant that every tenant is a real namespace and therefore has a possible RoleBinding. Had it
been missed, the flip would have taken the agent telemetry log rail down while Alloy kept working,
which is the hardest shape of this failure to attribute.

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
The mutating-admission route to tenant == stack (a webhook stamping pods with their stack's tenant)
is use case 1 of the UNDECIDED admission-controller seat — tracked by **FU-191**.

## The components

| piece | what it does |
|---|---|
| `alloy-config.yaml` | `loki.process` + `stage.tenant { label = "namespace" }` between the source and the write — the tenant is stamped per ENTRY, not per discovery target (see the warning above) |
| `loki-config.yaml` | `auth_enabled: true`; `querier.multi_tenant_queries_enabled` for the operator's datasource. **No ruler** — see §The belt could not stay in the ruler |
| `loki-rbac-proxy.yaml` | kube-rbac-proxy: TokenReview → SubjectAccessReview (namespace rewritten from `X-Scope-OrgID`) → proxy to Loki. `--allow-paths` restricted to the READ surface |
| `loki-tenant-grants.yaml` | one RoleBinding per (consumer, tenant) — the entire access-control surface |
| `grafana-loki-datasource.yaml` | the operator's all-tenant datasource — an ENUMERATED tenant list, because Loki has no wildcard. §What tenancy costs the operator |
| `otel-collector/otel-config.yaml` | the *second* Loki writer (the A0 telemetry rail) — static `X-Scope-OrgID: monitoring`, since OTLP records carry no namespace to derive from |

**The caller self-asserts the tenant and is then authorized for it.** Assert one you have no
RoleBinding for and the answer is 403, not that tenant's logs — the property plain `auth_enabled:
true` lacks. And because the authorized string and the string Loki reads are the same, there is no
authorized-for-X-queried-Y gap.

`--allow-paths` is not hygiene: without it the door proxies Loki's push endpoint too, and a
tenant-scoped *reader* could **write** log lines — forging evidence in the store an incident is
later reconstructed from.

## The belt could not stay in the ruler

This design originally planned "per-tenant ruler dirs" for homelab#811's `LokiPodLogVolumeHigh`.
That plan was wrong, and it is worth recording why, because the reasoning generalises to anything
that enumerates tenants.

Loki's ruler with `storage.type: local` reads rules from **`/etc/loki/rules/<tenant>/`**, and a rule
in directory `X` evaluates over tenant `X` **only**. Under `auth_enabled: false` there was one
directory — `fake` — and one mount. Under tenant == namespace there are as many directories as there
are namespaces (**33** when step 2 landed), each needing its own mount of the same ConfigMap. Worse
than the bulk: the mount list is static, so a namespace created afterwards gets no rule directory,
and its logs are watched by nothing. No error, no gap signal — the belt is simply green.

That is a strictly worse failure than the one #811 asked for a belt against, because #811's whole
lesson was that *nothing watched log volume*. Rebuilding the guard in a form a new namespace escapes
silently reproduces the original defect on a delay.

The belt moved to an ordinary `PrometheusRule` instead
([`prometheusrule.yaml`](../argocd/resources/loki/prometheusrule.yaml),
`LokiNamespaceLogVolumeHigh`), which is better than the original plan rather than a concession to
it:

- `loki_distributor_bytes_received_total` **already carries a `tenant` label** — pinned `fake` before
  the flip, per-namespace after it, with no configuration anywhere. A new namespace is covered the
  moment it logs, because its series appears on its own.
- the expr became **promtool-testable**. LogQL is not, so the per-pod rule was the one strap in this
  belt verified by eyeball; it is now pinned in `loki-ingest.promtool-test` alongside the other two.
- it removes the ruler from the design entirely — config stanza, ConfigMap and mount all gone.
- it sits in the same file as the two aggregate straps it is meant to be read with.

**What it costs is granularity: pod → namespace.** Re-measured live on 2026-08-27 rather than
inherited from the #811 write-up, the loudest healthy *whole namespace* is `argocd` at 2.0 KB/s
(then `garage` 1.5, `forgejo` 0.6). The unchanged 25 KB/s threshold therefore keeps ~12x headroom
over the loudest legitimate namespace and sits ~24x under the #811 flood (590 KB/s) — it still
discriminates at the coarser grain. What it can no longer see is one chatty pod inside an already
busy namespace, which is accepted: pod attribution is one Grafana query away and the alert carries
it.

## What tenancy costs the operator

Two regressions land with step 2. Neither is a defect to file; both are properties of tenant ==
namespace that the original design did not state, and an operator who meets them without warning
will read them as breakage.

**There is no all-namespace query any more.** Loki has no wildcard tenant — the multi-tenant read
syntax is `X-Scope-OrgID: a|b|c` and nothing accepts `*`. So the pre-tenancy habit of
`{namespace=~".+"}` across the cluster has no equivalent, and an "everything" view must **enumerate
its tenants**. Grafana's datasource therefore carries a committed list that is a snapshot: a
namespace added later is invisible in Grafana until someone edits the file, with the regeneration
one-liner in that file's header. This is deliberately *not* the failure that moved the #811 belt out
of the ruler — a stale list is felt the instant an operator looks for a namespace and finds nothing,
whereas a lapsed alert is invisible by construction. Making it self-maintaining is **FU-192**.

**Grafana's Live tail stops working** on that datasource: upstream returns HTTP 400 from
`GET /loki/api/v1/tail` when more than one tenant is named. Search, Explore and dashboards are
unaffected. A single-tenant datasource would tail fine, which is the shape to reach for if tailing
turns out to matter.

One more thing that changes quietly, and is the reason step 2 does not silently double as a limits
change: **`limits_config` is per tenant.** With one tenant, `ingestion_rate_mb: 8` was an effective
whole-cluster ceiling; from the flip every namespace gets its own 8 MB/s and the aggregate ceiling
rises ~32x. The number is left at 8 on purpose — that is no per-tenant regression, and sizing a real
per-tenant limit needs the per-namespace baselines the flip itself produces. Until FU-192 does that,
ADR-118's "per-tenant ingest limits" win is **not yet banked**: the #811 containment is still the
alert belt plus the Garage bucket cap.

## Rollout

Ordered so the irreversible step is verified rather than leapt, and so no step leaves a gate that
looks real and is not.

| # | change | what it verifies before the next step |
|---|---|---|
| 1 | Alloy `stage.tenant`; the proxy, its RBAC, the grants — **ClusterIP only, no VIP** | `loki_write_*{tenant="<namespace>"}` on a running Alloy — verified AT THE SENDER, because a single-tenant Loki overrides the header to `fake` and can never confirm it. Ingest unchanged; nothing is served, so nothing can regress |
| 2 | `auth_enabled: true`; the #811 belt moved to a PrometheusRule; **both** writers' headers; Grafana's enumerated datasource | Grafana Explore still returns logs; `LokiNamespaceLogVolumeHigh` evaluates per namespace; **both** Alloy and the OTel collector are accepted (a rejected push is the failure mode to watch — both retry, so a short outage loses nothing) |
| 3 | the LoadBalancer VIP (`192.168.40.32`) + the jail's usage note | the oracle workbench SA reads `oracle-fleet` and is **refused** `platform` |

**Step 3 acceptance PASSED 2026-08-27**, probed with a real `oracle-workbench` token against the
running proxy — every signature, not just the happy path: `oracle-fleet` and `oracle-agents` **200**;
`platform-agents`, `agent-coordinator` and **`fake`** all **403**; no header **400**; no token
**401**; `POST /loki/api/v1/push` **404**, so the write surface is genuinely unproxied. `fake` being
refused is the one worth naming — it holds every namespace's pre-flip logs, so it is deliberately
granted to nobody.

**Step 2 verified live 2026-08-27 17:17–17:20Z** (PR#1010), at the points the failure modes
actually live rather than by a green sync: the running pod resolves `auth_enabled: true` +
`multi_tenant_queries_enabled: true` with no ruler mount; the distributor counts bytes under
**per-namespace tenants** and no `fake`; **both** writers are accepted with zero rejections
(`loki_api_v1_push` 203×204, `otlp_v1_logs` 7×204) and `loki_discarded_samples_total` is empty; a
multi-tenant read returns logs across namespaces; a request with **no** header is **401**; Grafana's
sidecar reloaded the datasource (200 OK). Note the WAL replays pre-flip streams as `user=fake` right
after the roll — that is history being flushed, not the flip failing.

**Step 1 must not be exposed.** Until step 2 flips the flag, Loki ignores `X-Scope-OrgID` entirely
and would return every tenant's logs to a caller this proxy authorized for one. That is the one
configuration in this design that is worse than doing nothing, because it looks like a gate.

**Rollback** is per step and cheap: revert the ConfigMap and restart. Alloy buffers and retries, so
a Loki restart costs latency, not lines.

**Existing chunks stay under tenant `fake`.** They are readable by naming it, and with a 168h
`max_query_lookback` the old tenant stops mattering within a week — a cutover that completes itself.

## How a stack jail reads its logs

The door is `https://192.168.40.32:8443`, serving Loki's **read** API only. A stack jail already
holds what it needs: `stack-jail-init.sh` writes a 72h `<stack>-workbench` ServiceAccount token into
`~/.kube/config`, and that SA is the identity the grants are written for.

```sh
TOKEN=$(kubectl config view --raw -o jsonpath='{.users[0].user.token}')

curl -sk -H "Authorization: Bearer $TOKEN" -H "X-Scope-OrgID: oracle-fleet" \
  --get 'https://192.168.40.32:8443/loki/api/v1/query_range' \
  --data-urlencode 'query={namespace="oracle-fleet"}' \
  --data-urlencode 'start='"$(date -u -d '1 hour ago' +%s)" \
  --data-urlencode 'limit=100'
```

Four things decide whether a call works, and each has a distinct failure signature:

| you get | it means |
|---|---|
| `401` | no bearer token, or the token expired — mint a new session (the token is 72h) |
| `403` | you asserted a tenant you have no RoleBinding for. This is the gate working |
| `400` | no `X-Scope-OrgID` at all — the **proxy** fail-closes (`len(allAttrs) == 0`) before Loki is reached |
| a hang | not this door — an `enforce: true` stack's own CNP has no `loki` leg (the FU-020 signature) |
| `404` on `/loki/api/v1/push` | the write surface is not proxied at all (`--allow-paths`), so a reader cannot forge log lines |

**One tenant per request**, and the tenant is a namespace. `a|b|c` reaches Loki's multi-tenant read
syntax but not this door: the proxy splits per header *occurrence*, so it would authorize against a
namespace literally named `a|b|c` (§Why tenant == namespace). Query the three oracle tenants as
three calls.

`curl -k` is required: the proxy serves a self-signed cert regenerated at each restart, so there is
nothing stable to pin (FU-193). The token is TokenReviewed server-side, so this weakens
confidentiality against a LAN MITM, not authentication.

**Pre-flip history is under tenant `fake`** and is readable by asserting it — but only if a grant
exists for a namespace of that name, and none does, deliberately: `fake` holds *every* namespace's
logs from before 2026-08-27, so granting it would hand a jail the whole cluster. It ages out of the
168h query window around 2026-09-03.

**Kernel logs are NOT reachable this way**, despite homelab#541 saying they are. `kmsg-reader` runs
in namespace `loki`, so `/dev/kmsg` lines are tenant `loki` — the log store's own namespace, which
no jail is granted and none should be. See §The problem, stated exactly and **FU-194**.

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
