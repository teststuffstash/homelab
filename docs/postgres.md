# Postgres (CloudNativePG) — the consumer card

Everything a stack (or platform service) needs to get a relational database is on this page;
everything below §Failure signatures is context you don't need to file one. Catalog row:
[`SERVICES.md`](../SERVICES.md). Decision: `docs/adr.md` ADR-046. Live examples:
[`argocd/resources/postgres/`](../argocd/resources/postgres/) — `grafana-pg.yaml` is the one to
copy.

One term first, because this repo overloads it: the secret below is **CNPG-generated** — minted
by the CloudNativePG *Kubernetes operator*, automatically, at cluster bootstrap. No human (the
other meaning of "operator" here) generates anything, in any jail; the only human-touched
artifact is the `Cluster` manifest in your `-iac` repo.

## What you declare

One `postgresql.cnpg.io/v1` `Cluster` in **your own namespace**, applied by ArgoCD from your
`-iac` repo. A `Cluster` is a namespaced kind, so the stack AppProjects admit it as-is (the
namespace itself is platform-precreated — you never create namespaces):

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: <app>-pg          # stack-generic if more tables will join later (e.g. oracle-pg)
  namespace: <your-ns>
spec:
  instances: 2            # HA pair; replicas spread by default anti-affinity
  storage:
    size: 2Gi             # default StorageClass = replicated Longhorn
  monitoring:
    enablePodMonitor: true  # Prometheus picks up PodMonitors in every namespace
  bootstrap:
    initdb:
      database: <db>
      owner: <role>
      # No `secret:` — CNPG mints `<cluster>-app` for exactly this role/database.
```

Supply your own `secret:` **only** when something outside the cluster must know the password at
build time (`infisical-pg.yaml` does, because tofu assembles its connection string). Default is:
don't.

## What you consume

- **Secret `<cluster>-app`** (same namespace, basic-auth type), carrying `username`, `password`,
  `dbname`, `host`, `port`, `user`, `pgpass`, and ready-made DSNs: `uri`, `jdbc-uri`,
  `fqdn-uri`, `fqdn-jdbc-uri`. Your DSN env is one `secretKeyRef` (`key: uri`) — never assemble
  or commit a connection string.
- **Services `<cluster>-rw` (always the primary), `<cluster>-ro` (replicas), `<cluster>-r`
  (any), all on `:5432`.** The read/write split lives at the *Service* level, not the
  credential level — CNPG mints ONE app-role secret, not Zalando-style per-role read/write
  secrets. A genuinely reduced read-only *role* is SQL you own, with a secret you manage.
- **TLS**: CNPG serves a self-signed cert; `sslmode=require` is the in-cluster dial (encrypts
  without CA verification — see the rationale in
  [`kube-prometheus-stack.yaml`](../argocd/platform/values/kube-prometheus-stack.yaml)'s Grafana
  block; node-pg specifics in FU-010).

## Failure signatures

| symptom | it means |
|---|---|
| `<cluster>-app` never appears | the cluster hasn't finished bootstrapping (read the `Cluster` status/events) — or you set `bootstrap.initdb.secret:`, and CNPG then mints nothing |
| `password authentication failed` after a re-create | supplied-secret drift: the DB was re-initialized but your supplied secret wasn't (the class ADR-046 warns about) — the CNPG-generated path can't hit this |
| TLS/certificate error from node-pg | the self-signed cert (FU-010); use `sslmode=require`, not `verify-*` |
| you need a second *database* later | declare a `Database` CR (the CRD is live, operator 1.28) — it does **not** mint another `-app` secret; that role/password is yours |
| CNPG pod-status alerts stay silent for your cluster | the `CNPGInstanceNotReady`/`CNPGInstanceCrashLooping` belts pin namespaces in [`kube-prometheus-stack.yaml`](../argocd/platform/values/kube-prometheus-stack.yaml) — a platform one-liner adds yours (the metric-based belts cover you automatically once the PodMonitor is on) |

## What the platform owns — and deliberately does not provide

The platform owns the operator lifecycle (`argocd/platform/cnpg-operator.yaml`), failover, the
alert belts, and the Longhorn storage underneath. It does **not** provision databases for you
(the `Cluster` CR is yours, in your repo), does not manage extra roles or databases beyond the
bootstrap one, and declares no backups on your behalf — CNPG's `Backup`/`ScheduledBackup` CRs
exist and are the consumer's call (per the boot-from-git rule, non-rebuildable data belongs in
S3).
