# LENS: k8s-prod — production-readiness review of workload manifests (FU-101)

**ADVISORY LENS.** Findings from this lens are ALWAYS `Follow-ups:` bullets prefixed
`LENS(k8s-prod):` — they NEVER change your verdict (a per-stack claim knob graduates a lens to
blocking; until then advisory is the contract). Apply it ONLY to the manifests this PR touches —
it is a lens on the diff, not an audit of the repo.

**Source (pinned):** the k8s production-checklist class —
[learnk8s/kubernetes-production-best-practices](https://github.com/learnk8s/kubernetes-production-best-practices)
(pin: master @ 2026-07) + the upstream k8s docs "Configuration Best Practices". A new release of
the source = a re-baseline issue, not an inline edit (staleness is outsourced by design).

For each workload (Deployment/StatefulSet/DaemonSet/CronJob) or its chart template touched by
this diff, check:

## Probes & lifecycle
- Readiness probe exists and exercises the **deepest dependency path** the pod serves from —
  never `tcpSocket` on a parent process, never a bare `SELECT 1` when a schema/corpus version
  contract exists. (Local evidence: meta-11 2026-07-26 — tcpSocket-on-parent kept two
  Ready-but-dead replicas in rotation for 13h. The incident class this lens exists for.)
- Liveness probe is NOT the readiness probe verbatim (a dependency blip should unready, not
  restart-loop), and a subprocess-child architecture respawns-or-dies when the child dies.
- `terminationGracePeriodSeconds` + graceful shutdown match (SIGTERM handled; preStop where the
  runtime can't).

## Scheduling & disruption
- ≥2 replicas imply `topologySpreadConstraints` (or pod anti-affinity) across nodes — two
  replicas on one node is one failure domain. (Local evidence: fleet#153/#156 — both MCP
  replicas sat on wk-01.)
- A PodDisruptionBudget exists when replicas ≥2 and the service is availability-claimed.
- Requests set for cpu+memory; limits at least for memory; no limitless memory on nodes that
  also run the compute tier.

## Config & images
- Images pinned by digest (data/corpus images) or immutable calver tag (app images) — never a
  floating `:latest` reaching prod values.
- Schema/format-coupled artifacts (server ↔ corpus/DB) roll **paired** — the chart/values must
  not allow one side to move alone silently (a version-contract gate beats a deploy convention;
  local evidence: the meta-11 schema-skew outage, fleet#155/#159).
- Secrets by reference (`existingSecret`, ESO) — never values in a chart; ConfigMap changes that
  must restart pods carry a checksum annotation.

## Observability
- New long-running workloads: are they scraped (ServiceMonitor/annotations) and do they surface
  a health endpoint the platform blackbox probe (FU-099) can hit?
- stderr of subprocess children is streamed to pod logs, not buffered in an unread PIPE (local
  evidence: fleet#157 — the child's dying words sat in an unread `subprocess.PIPE`).
