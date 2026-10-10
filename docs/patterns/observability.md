# Pattern: how a stack consumes Prometheus, Grafana and Alertmanager

> To find **what** services exist (and their status), see the catalog [`../../SERVICES.md`](../../SERVICES.md).
> This doc is the **consumption contract** for observability — the sibling of
> [`app-owned-resources.md`](app-owned-resources.md) (Garage/Postgres/keys). Written 2026-09-01
> from the oracle jail's handoff (the contract had only ever been learned by breaking it:
> oracle-fleet's spec cited a ServiceMonitor that never existed). Every "today" claim below is
> read from `argocd/platform/values/kube-prometheus-stack.yaml` and the Loki/exporter manifests —
> re-check them, never this page, before relying on a constant.

**The one-line rule: the platform runs the collectors, the routing and the datasources; a stack
ships its own monitors, rules and dashboards from its own chart, and they are picked up with no
homelab PR.** Selectors are cluster-wide by configuration
(`serviceMonitor/podMonitor/probe/ruleSelectorNilUsesHelmValues: false`), the dashboard sidecar
watches every namespace, and the responder routes an alert to the stack that owns its namespace.

## Ownership — platform vs stack

| Piece | Owner | Where |
|---|---|---|
| kube-prometheus-stack (Prometheus, Alertmanager, Grafana), the Loki datasource, exporters (blackbox, github, cloudflare, otel) | **platform** | `argocd/platform/kube-prometheus-stack.yaml` + `values/`, `argocd/resources/{loki,blackbox,…}` |
| the Alertmanager **routing tree + inhibition** (below) and the **responder** | **platform** | `values/kube-prometheus-stack.yaml` `alertmanager.config`; `agents/coordinator/responder-argo.yaml` |
| **datasource uids** — the stable interface dashboards bind to | **platform promise** | `prometheus` (the default; 12 platform dashboards bind it) · `loki` (sidecar-provisioned, header `X-Scope-OrgID` pre-set — tenant == namespace, ADR-118) · `sleep-data` (the frser SQLite datasource, sleep-only) · `oracle-feedback` (read-only Postgres on the oracle feedback sink, `oracle-pg-ro.oracle-fleet.svc`, `SELECT`-only role — added for oracle-fleet#713). A stack that needs a datasource of its own brings the platform two things: the connection facts, and a password its `-iac` Workspace PUBLISHES to Infisical (`crossplane-tf-writer`, ADR-076) — the platform adds the entry and an ExternalSecret, and nothing is ever copied between namespaces ([`../secrets.md`](../secrets.md) §Boundaries: the Infisical→ESO path is read-only). |
| `ServiceMonitor` / `PodMonitor` for the stack's workloads | **stack** — from its chart | in the stack's namespace |
| `PrometheusRule` for the stack's workloads | **stack** — from its chart, tested in the stack's CI | in the stack's namespace |
| dashboards | **stack** — `grafana_dashboard: "1"` ConfigMaps from its chart | in the stack's namespace |
| the SLO blackbox probe + burn-rate alerts | **platform-rendered from the claim** (`spec.slo`, FU-104) | the AgentStack claim in the stack's `-iac` |

## 1. Scrape — the stack ships its own monitors

A `ServiceMonitor`/`PodMonitor` in the stack's namespace is picked up as-is: no `release:` label
is required (the `*NilUsesHelmValues: false` settings replace the chart's default
label-selector). This is the sanctioned shape, and it follows the target-agnostic-chart rule
([`../agents/platform-and-stacks.md`](../agents/platform-and-stacks.md) §Composition axes): the
**app chart** carries the monitor behind a default-off `serviceMonitor.enabled`-style flag (an
ecosystem-standard CRD, so the chart still deploys where the operator is absent), and the
**`-iac` wrapper** flips it on. The AgentStack claim renders no monitors — only the `slo:` probe.

Conventions: keep the chart's `interval` at the default (30s; never below 15s — one operator
subscription's worth of TSDB), set `honorLabels: true` only when the app emits labels the
platform's relabeling would otherwise overwrite, and name the job after the app (the `job`
label is what dashboards and rules key on).

### Batch jobs push to the Pushgateway instead

A pod that lives for seconds (a CronWorkflow step, a nightly job) is rarely caught by a
scrape, so it **pushes** its gauges to the platform Pushgateway, and Prometheus scrapes the
gateway (`honorLabels: true`, so the pushed `job` and grouping labels survive):
`http://prometheus-pushgateway.monitoring.svc.cluster.local:9091`, in-cluster only. The
gateway persists to a Longhorn PVC and **serves the last push forever**: there is no TTL.
That shapes every rule below.

- **Fixed grouping key, PUT to replace.** `PUT /metrics/job/<job>/<key>/<value>` with a key
  that names the thing measured (a bucket, a pipeline), never the run. A per-run key is a group
  that never goes away: FU-182 is the platform's own per-ride groups piling up.
- **`job` starts with the stack's name** (`oracle_retention_ledger`). `agent_*` belongs to the
  platform. Nothing enforces this; see the integrity note below.
- **Byte-identical `# HELP`/`# TYPE` on every push.** Two groups with different HELP text for
  one metric make the gateway log on every scrape (homelab#811: 48.7 GiB/day of Loki ingest).
- **Push a freshness gauge in the group** (`<job>_generated_timestamp_seconds`) and alert on
  its age. The gateway re-serves the last value, so a job that stopped running still looks
  healthy without one.
- **Push every label combination, zeros included**, so "absent" means "not pushed" and is
  never confused with zero.
- **Measurements only.** Digests, run ids and other identities stay in the job's own record (an
  S3 object, a database row). Each would create a new series.
- **Write-only for the stack.** Read the numbers through Prometheus, never by GETting the
  gateway, and never let a dispatch, gating or routing decision depend on them (ADR-108).
- **Egress is the stack's.** The job's network policy needs a rule to `monitoring` /
  `app: prometheus-pushgateway` on 9091/TCP. Like any egress, it is declared in the stack's `-iac`.

**Integrity: the gateway has no auth.** Anything that can reach port 9091 can overwrite or delete
any group, including the platform's `agent_run*` groups, which `agents/goal-budget.sh` reads
as the goal-budget spend ledger. Treat pushed series as best-effort observability, and do not
push anything you would not want a neighbour to be able to overwrite.

## 2. Dashboards — a labelled ConfigMap, in your folder

The Grafana sidecar watches **every namespace** (`sidecar.dashboards.searchNamespace: ALL`) for
ConfigMaps labelled `grafana_dashboard: "1"`; the CM's data key is the dashboard JSON. Ship it
from the chart (sleep-tracking has since 2026-07-28; the `docs/sleep-iac.md` migration story is
the precedent). Two conventions:

- **Folder**: annotate the CM `grafana_folder: <stack>` and the dashboard lands in a Grafana
  folder of that name (`sidecar.dashboards.folderAnnotation`, live with this page); an
  un-annotated CM lands in General. Use the stack name, not the app's.
- **Datasources**: bind panels to the uids in the table above by uid, never by name, and never
  hard-code the datasource's URL. Those uids are the platform's promise; the sleep lesson
  (`docs/sleep-iac.md` §Contract between the two layers) is that a renamed datasource breaks
  every dashboard that named it. A dashboard `uid` of your own is required too (the sidecar
  dedups on it; two CMs with one uid silently fight — the `UNIQUE_FILENAMES` note in
  `docs/sleep-iac.md`).

Dashboards are **read-only from git**: an edit made in the Grafana UI is lost on the next sync.
Keeping the JSON beside the app's e2e tests (the 2026-09-01 oracle ruling: dashboards live in
the stack repo under e2e) is the intended shape.

## 3. Alert rules — the stack ships them; here is what the platform does with them

A `PrometheusRule` in the stack's namespace is loaded cluster-wide, exactly like the platform's
own. The routing tree it enters (`alertmanager.config.route`, live today):

| route | matcher | receiver | what it means for a stack alert |
|---|---|---|---|
| root | — (`group_by: [alertname]`, `repeat_interval: 3h`) | `ha-webhook` | every firing alert reaches the operator via Home Assistant (ADR-042) |
| child | `alertname = Watchdog` / `InfoInhibitor` | `null` | dropped |
| child, `continue: true` | `triage = "now"` | `agent-responder` | **the responder sees the acute alerts only** (ADR-148, 2026-10-04), grouped by alertname (one webhook per storm, FU-133) |
| — (a schedule, not a route) | `triage = "dig"`, standing or recurring, unexplained | the **deep dig** (`docs/agents/roles.md` §deep dig) | read off Alertmanager + Prometheus on a cron, grouped by onset and host — never a per-fire session |

The **responder** (`docs/agents/roles.md` §responder) opens ONE triage session per new
`now` fingerprint and files at most one **inert** issue — **on the repo of the stack that owns
the alert's `namespace`** (a claim lookup; `platform_machinery: "true"` or a platform namespace
routes to homelab instead). So a stack-shipped alert is answered in the stack's own board, by
its own loop: write the rule so a fixer could act on it from that repo. A `dig` alert is picked
up by the deep dig only once it has STOOD (≥ 6 h) or RECURRED (≥ 3 of the last 7 days) and no
open issue, declared window, follow-up or meta-state entry explains it; an unlabelled stack rule
reaches neither lane — the label is the stack's to declare.

Rule-author conventions the platform reads:

- **`severity: warning | critical`.** `severity: info` is **never delivered** — the stock
  `InfoInhibitor` holds it `suppressed` (proven live 2026-08-06, homelab#769). A rule that is
  deliberately dashboard-only must say so (`info_suppressed_ack: <why>`), or it is a decoration
  shipped as an alert.
- **`description` is the SYMPTOM, not a guessed cause** — the responder's job is the diagnosis;
  a description that names a cause primes a wrong fix (the `PodSigkilled` text is the worked
  example of listing the candidate causes without asserting one).
- **`triage: none | now | dig`** — REQUIRED on every rule (operator decision 2026-10-03). `none` =
  no investigation from inside the cluster can change what anyone does (self-describing state,
  operator-only remedy, meta); `now` = acute, minutes matter — a real-time session should start;
  `dig` = the default: worth a thorough investigation if it stands or recurs unexplained. Classify
  by what an investigator with the cluster's read access could change, never by severity.
  homelab's `prometheus-rules-lint` reds a platform rule without it; run the same check in the
  stack's CI. The stock kube-prometheus-stack rules get theirs from the platform's relabel map
  (`argocd/platform/values/kube-prometheus-stack-triage.yaml`).
- **`platform_machinery: "true"`** = "investigate, but a human merges the fix" (routes to
  homelab). Like `triage`, a rule-site label.
- The `namespace` label must be the app's real namespace — it is the routing key.

**Testing is the stack's.** homelab's `prometheus-rules-lint` covers only homelab's manifests.
Run `promtool check rules` over the rendered `PrometheusRule` in the stack's CI, and put
behaviour fixtures beside the rule file in the `*.promtool-test` shape (`promtool test rules`
— `for:` windows and series semantics, the FU-158 pattern; `argocd/resources/blackbox/probes.promtool-test`
is a small worked example). Gate them only when rule files change (the diff-ci lesson) — they
are seconds, but they are the wrong seconds on an unrelated PR. An untested rule file is how
oracle-iac's pipeline alerts were shipped.

## 4. Reading from outside the cluster (a stack jail, a laptop)

| surface | LAN address | auth / scope | supported? |
|---|---|---|---|
| Prometheus HTTP API | `https://prometheus.teststuff.net/api/v1/query` (HAProxy VIP `192.168.40.13`) | none; **cluster-wide** — every stack's series | **yes**, as a LAN read (the platform's own watch scripts use it). No per-stack scoping exists or is planned: metrics carry no content the way logs do, so the Loki door's tenancy model was not copied |
| Grafana | `https://grafana.teststuff.net` | Grafana login | yes |
| Alertmanager API | `https://alertmanager.teststuff.net` | none, LAN | yes (read; silences are operator-lane) |
| Loki | `https://192.168.40.32:8443` + `X-Scope-OrgID` | SA token, per-namespace RBAC | yes — [`../loki-tenancy.md`](../loki-tenancy.md) §How a stack jail reads its logs |

From inside the cluster the same are `kube-prometheus-stack-prometheus.monitoring.svc:9090`
and `loki.loki.svc:3100` (the responder runbook in `docs/agents/roles.md` shows the in-cluster
Prometheus read; a LAN VIP is a `world` destination under the egress policy).

## What this page does not promise

- **Retention is best-effort, about one month.** The config says `retention: 31d` *or*
  `retentionSize: 45GB` (`argocd/platform/values/kube-prometheus-stack.yaml`), and the size
  cap is what binds: on 2026-10-10 the oldest sample was 25 days old, with ~42 GB of blocks
  and ~500k head series. The window shrinks whenever series grow, so read the live
  `(time() - prometheus_tsdb_lowest_timestamp_seconds) / 86400`, never the `31d`.
- **There is no long-term metrics store.** Anything that must outlive that window (a business
  number, a ledger, a yearly trend) keeps its record in the stack's own storage (S3, Postgres),
  and Prometheus holds only the recent copy. ADR-108 names the shape if one is ever built: a
  *separate* Prometheus for selected series, never the observability instance.
- Retention, scrape-interval floors and TSDB sizing are platform capacity, not a stack
  contract. A stack that needs more asks through the capability-request lane
  ([`../agents/platform-and-stacks.md`](../agents/platform-and-stacks.md) §Cross-stack demand).
- The AgentStack claim renders only the SLO probe; monitors, rules and dashboards stay chart
  content on purpose (they must deploy where homelab is absent).
