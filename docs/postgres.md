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
  instances: 2            # HA pair — one instance per PHYSICAL box (next block)
  affinity:               # ADR-114: REQUIRED, on the zone — never CNPG's default
    podAntiAffinityType: required
    topologyKey: topology.kubernetes.io/zone
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

**Why the `affinity` block is not optional.** CNPG's default anti-affinity is `preferred` on
`kubernetes.io/hostname` — a soft per-*node* preference. It let forgejo-pg heal both instances onto
one VM (2026-08-24), and a hostname rule can never see that every pve VM shares one hypervisor and
one thin pool. `topology.kubernetes.io/zone` is the physical box (`machines.yaml` `zone`: every
pve VM reads `proxmox`, nx-02's read `nx-02`), and `required` makes co-location impossible rather
than unlikely. Decided in [ADR-114](adr.md) (delivery tracked by FU-137); the platform's own three clusters carry it since 2026-09-21
(#1840).

**The platform's own three go one step further** (ADR-114's other CNPG half, 2026-09-21): their
volumes are **replica-1 node-local** (`storageClass: longhorn-local-std`) — Postgres already
replicates itself, so a second Longhorn copy of each instance is pure write tax — which ties each
instance to its box, hence a node-affinity pin to the zones that have a std disk and
`primaryUpdateMethod: switchover`. Rationale and costs:
[`storage-ledger.md` §2026-09-21](storage-ledger.md). **Stack clusters keep the default class**
for now: that pin is a hand-kept zone list, not yet a label your `-iac` repo could name (FU-137).

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
| one instance `Pending` — `didn't match pod anti-affinity rules` | only one zone is schedulable for it right now (a hypervisor down, nodes cordoned). By design: the cluster runs on the other instance until a second zone returns — never relax `required` to "fix" it |
| you need a second *database* later | declare a `Database` CR (the CRD is live, operator 1.28) — it does **not** mint another `-app` secret; that role/password is yours |
| CNPG pod-status alerts stay silent for your cluster | the `CNPGInstanceNotReady`/`CNPGInstanceCrashLooping` belts pin namespaces in [`kube-prometheus-stack.yaml`](../argocd/platform/values/kube-prometheus-stack.yaml) — a platform one-liner adds yours (the metric-based belts cover you automatically once the PodMonitor is on) |

## Backups — on by default (ADR-147)

**You declare nothing.** Every `Cluster` in a namespace the platform has given a backup store is
wired at admission to the **Barman Cloud plugin**: continuous WAL archiving plus a **daily base
backup** (the platform's `pg-backup` CronJob, 02:15Z), kept **14 days**, in bucket `cnpg-<namespace>`
on the backup Garage — outside Longhorn, so a Longhorn failure cannot take the copies with the
originals ([`longhorn-backup.md`](longhorn-backup.md) §The target). Each namespace has its own
bucket and key; no tenant can read another's backups.

| you want | do |
|---|---|
| nothing (the default) | nothing — a NEW `Cluster` is created wired (`spec.plugins: [barman-cloud…]` appears; that line is the platform's, not drift) |
| an EXISTING cluster in a newly-stored namespace wired | the seat runs `devbox run pg-backup-wire -- <ns>/<cluster>` in a maintenance window — never a bare re-apply (below) |
| no backups for a throwaway cluster | annotate it `homelab.io/pg-backup: disabled` |
| a backup NOW (before a risky change) | the seat runs `devbox run pg-backup-now` — every cluster, waits, exit 0 only if all completed |
| a namespace that has no store yet | ask the platform: a `store-<ns>.yaml` in `argocd/resources/pg-backup/` + the bucket. Until then the daily job reports your cluster UNCOVERED and fails, so it is seen |

Backups are taken **from the primary**: its `pg_backup_stop` waits until the backup's WAL is in the
store, so a completed backup is restorable at once. A standby backup is not — on 2026-10-03 one
reported `completed` four minutes before its WAL was archived, and one taken from a standby that had
just rejoined after a failover could not be restored at all (*"unexpected timeline ID"*).

**Why wiring a running cluster is a verb, not an apply.** Adding the plugin changes the running
primary's `archive_command` at once, before its pod has the plugin sidecar; the rolling update's
switchover then waits for that primary to archive its last WAL — which it cannot — and CNPG has
already emptied the `-rw` Service. Result: no writable primary until `switchoverDelay` (1 h). The
2026-10-03 rollout hit it on grafana-pg and forgejo-pg (~10 min each, nothing alerted —
`CNPGNoWritablePrimary` now does). So the admission policy wires only new clusters, re-asserts
already-wired ones, and wires a running one only on the explicit `homelab.io/pg-backup: wire`
request that `pg-backup-wire` makes: it waits for the switchover to start, checks the old primary's
LSN equals the target's, and fails it over at once (`-rw` gap 16–17 s on infisical-pg and oracle-pg).

**Restore** (the "the upgrade broke everything" path: accept the loss since the backup, rebuild
from it). A new `Cluster` bootstraps from the store, under a NEW name — its old name's WAL is in
the store, and CNPG refuses to archive over it:

```yaml
spec:
  bootstrap:
    recovery: { source: origin }          # latest backup + all archived WAL; add recoveryTarget for a point in time
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters: { barmanObjectName: pg-backup, serverName: <old cluster name> }
```

Proven 2026-10-03: infisical-pg restored from a primary backup into `infisical-pg-drill` (same
namespace, 1 instance) — healthy in 85 s, all 704 tables with identical row counts. To restore a
specific backup rather than the latest, add `backup: { name: <Backup CR> }` under `recovery`.
A recovery-bootstrapped cluster is **not** auto-wired: once it is healthy, `devbox run
pg-backup-wire -- <ns>/<name>`, or the daily job reports it UNCOVERED. Point the
app at the new `-rw` Service/secret (or restore under the old name in a fresh namespace).
**After a total loss**, Infisical (which feeds the store credentials) is itself on a CNPG volume:
seed `pg-backup-s3` in `infisical` from the wallet (`cnpg-backup-infisical-{key-id,secret}`, keys
`ACCESS_KEY_ID`/`ACCESS_SECRET_KEY`) and restore Infisical's cluster first.

## What the platform owns — and deliberately does not provide

The platform owns the operator lifecycle (`argocd/platform/cnpg-operator.yaml`), failover, the
alert belts, and the Longhorn storage underneath. It does **not** provision databases for you
(the `Cluster` CR is yours, in your repo), does not manage extra roles or databases beyond the
bootstrap one, and leaves retention and cadence to the defaults above until per-tenant knobs exist (FU-299) — backups
themselves are the platform's, on by default (§Backups).
