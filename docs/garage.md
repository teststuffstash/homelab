# Garage — self-hosted S3 object store

Garage (Deuxfleurs) is the in-cluster S3-compatible object store (ADR-031). It's the convergence
point for the sleep-tracking pipeline (ADR-045) and a future home for Longhorn/HA backups.

- **Deploy:** `argocd/platform/garage.yaml` (ArgoCD, since 2026-08-04 — FU-136; chart vendored at
  `argocd/charts/garage`, Garage **v2.3.0**). `tofu/garage.tf` keeps only the namespace, two
  Secrets and the VIP Service.
- **Access model: LAN-only.** In-cluster clients use the ClusterIP Service; LAN clients use
  `https://s3.teststuff.net` (OPNsense HAProxy → BGP VIP **192.168.40.16**:3900). No Cloudflare
  tunnel, no public LoadBalancer. Admin (3903) + RPC (3901) never leave the cluster.
- **Region:** `garage` (S3 clients must set this). **Addressing:** path-style.

> Single-node trial: `replication_factor = 1`, one StatefulSet replica, meta+data on Longhorn.
> Not HA — that waits for the 3-node build (ADR-030). The bytes are data; the layout/config is code.

## One-time layout bootstrap (after the first `tofu apply`)

Garage isn't usable straight from Helm — the single node has no layout (capacity role) yet. This is
a one-time **platform** step (cluster topology, not app data); run the `garage` CLI inside the pod
(binary is `/garage`; it reads `/etc/garage.toml`). Buckets/keys come later and are app-owned.

```sh
KC="--kubeconfig tofu/kubeconfig"
G="devbox run -- kubectl $KC -n garage exec -i garage-0 -- /garage"

# 1. Find the node id (the long hex before the zone column)
$G status

# 2. Give this single node a layout role, then commit it (v2 capacity is a size; live value
#    since 2026-07-13: 140G on the longhorn-bulk data volume — docs/garage-bulk-migration.md).
#    Use the node id from step 1. Verify flag names with `$G layout assign --help` (v2 syntax).
$G layout assign -z dc1 -c 140G <NODE_ID>
$G layout apply --version 1
$G status                      # should now show the node with capacity, no pending layout
```

That's all homelab does to Garage. **Buckets and keys are owned by the consuming application, not
by homelab** (ADR-074; pattern in `docs/patterns/app-owned-resources.md`) — the platform provides the *store*; each app provisions
the *buckets* it needs from its own repo. So `sleep-band` / `sleep-snore` are declared by the
**sleep-tracking app**, not here. See "Who provisions buckets" below.

### Who provisions buckets (app-owned — Crossplane, LIVE)

Isolation in Garage is by **separate buckets + keys** (no AWS-style prefix IAM — ADR-031), which
maps cleanly onto the per-app-repo model (ADR-004): an app declares its own buckets, write keys, and
permission grants, and consumes the generated key as a Secret **in its own namespace**. The platform
only provides the seam (the Garage admin API + a token).

The mechanism is **Crossplane `provider-terraform`** (ADR-076, live since 2026-06-17): the app
declares a `Workspace` CR (wrapping the `jkossis/garage` tofu provider) in its own repo, ArgoCD
syncs it, the provider reconciles in-cluster (admin token injected via ESO), and the generated key
is published to **Infisical** as the source of truth (ADR-062). Full recipe + conventions:
[`patterns/app-owned-resources.md`](patterns/app-owned-resources.md). Homelab does **not** create
app buckets or hold app keys.

## Verify (from the LAN)

```sh
aws --endpoint-url https://s3.teststuff.net --region garage \
    s3 ls                                   # lists buckets with the matching key in ~/.aws
# direct (no HAProxy): aws --endpoint-url http://192.168.40.16:3900 --region garage s3 ls
```

## OPNsense wiring (LAN HTTPS name)

`s3.teststuff.net` → VIP `192.168.40.16:3900`, same pattern as the other services
(`/opnsense-as-code`): Unbound host override + HAProxy reverse-proxy backend + ACME cert (DNS-01
Cloudflare). HAProxy must allow large request bodies / streaming for S3 uploads (no small
`timeout`/buffer caps).

## Notes / gotchas

- **Never expose 3903 (admin) or 3901 (RPC).** Admin has no auth boundary suited to the LAN; RPC is
  the inter-node trust channel (guarded by the rpc_secret, but keep it internal regardless).
- **rpc_secret** is pinned in tofu state (`random_id.garage_rpc`) so applies don't churn it.
- Chart is kept **chart-shaped** (homelab adds only the LoadBalancer Service); the ArgoCD
  re-point happened 2026-08-04 (FU-136).
- Updating Garage: re-vendor the chart at the new tag (see `argocd/charts/garage/VENDORED.md`),
  bump values in `argocd/platform/garage.yaml`, ArgoCD syncs (steps:
  [`garage-bulk-migration.md`](garage-bulk-migration.md)).

## Durability — what actually stands between you and losing all of it

Measured 2026-08-04, because "can I afford to lose this?" deserves numbers rather than a shrug.

**~63.7 GB across 12 buckets**, and the shape matters more than the total: `ert-snapshots` is 60.4
GB / 252k objects of it. Everything else together is ~3.3 GB, and the part that is genuinely
irreplaceable is small: `agent-transcripts` (491 MB, the loop's own observability record) and the
`sleep-*` buckets (27.5 MB of real personal data). `allure-reports` and `oracle-specs` regenerate
from CI and from `specs/` in the stack repos; `loki` self-expires at 7 days.

**⚠ `ert-snapshots` is NOT the cheap-to-lose bucket this section called it until 2026-08-25.** The
old reading — "the oracle-fleet ingestion re-downloads its source zip, so losing it costs a long
re-ingest, not data" — is true about the *bytes* and wrong about the *asset*. Re-ingesting fetches
**today's** register, so it produces a current corpus and destroys the only thing a stale one is
good for: the delta job (oracle-fleet `specs/ingestion/riigiteataja-delta.md`) updates a base
corpus in place, and testing it needs a base that has genuinely aged. The 2026-07-12 ingest is that
base, and it is not re-creatable at any price — re-download moves the window, it does not restore
it (operator, 2026-08-25). Nor is the published ghcr `ert-corpus` image a substitute: `resolve_base`
needs `latest.json`, the `build/` + `publish/` step manifests and the whole `parsed/` set, none of
which ride in the image. Treat this bucket as **irreplaceable while an un-run delta window is open**,
and as production data outright once the oracle stack serves traffic.

**What protects it:** Garage runs `replication_factor = 1` on a single node, so *all* redundancy
is Longhorn's (2 replicas per volume). Replica PLACEMENT is owned by
[`storage-ledger.md`](storage-ledger.md) §tier fence (the 2026-08-04 placement recorded here was
invalidated by the 2026-08-07 `diskSelector` stamping — read the ledger, not a dated copy).

**What does not protect it:** nothing backs Garage *out*. FU-013 backs other things *into* it. The
sharp edge is the **meta volume** — 10Gi of LMDB on `longhorn`, tiny next to the data, and losing it
makes the ~60 GB of blocks unreadable.

Two consequences worth holding:

- `scripts/garage-backup.sh` (`devbox run garage-backup`) pulls every non-excluded bucket to
  `backups/garage/` (gitignored) and **verifies object counts against Garage**, refusing to call a
  short copy a backup. It copies **objects, not volumes**, on purpose: an object copy survives a
  metadata loss, a block-level snapshot does not. Offsite (AWS/Civo) is the real answer — **FU-137**.
- Garage durability is now load-bearing for **tofu state** too (FU-012 put three roots there). Those
  additionally have timestamped copies in `~/.claude/homelab-tofu-state-backups/`.

**The sharp edge fired 2026-08-24** — the meta LMDB came back empty-tabled after a pve
thin-pool freeze ([incident](incidents/2026-08-24-pve-thin-pool-garage-meta-wipe.md)); the
Aug-04 object copy was the restore source. Hardening now live: `metadata_fsync = true` (the
default FALSE runs LMDB `MDB_NOSYNC` — documented corruption-prone on unclean shutdown),
`metadata_auto_snapshot_interval = 6h`, snapshots on the data volume
(`metadata_snapshots_dir` — they need up to 4× the DB size). **Recovery recipe** (garagehq
"Recovering from failures" Scenario 3, rf=1 flavor — the snapshot interval is a hard loss
window): stop Garage, `mv db.lmdb db.lmdb.bak && cp -r /mnt/data/meta_snapshots/<latest> db.lmdb`,
restart, `garage repair -a --yes tables`.

**When there is no snapshot and no backup covering the window**, the objects are still recoverable:
blocks are content-addressed and only a *manual* `garage repair blocks` reaps orphans, and LMDB's
copy-on-write leaves the emptied tables' pages readable in a frozen volume layer. That carve
recovered the whole Aug-4→24 delta on incident day —
[`scripts/garage-forensics/`](../scripts/garage-forensics/README.md) is the method and the tooling.
Its first instruction is the one with a deadline: **freeze the evidence and do not run
`garage repair blocks`** until the carve is done.

## Target architecture — rf=3 across physical zones (ADR-114, build-out in progress)

**Grounding** — the upstream pages this design was read against (2026-08-24; before any
substantial change here, read them all — they are what changed the outcome):

- [configuration reference](https://garagehq.deuxfleurs.fr/documentation/reference-manual/configuration/) —
  `metadata_fsync=false` default = LMDB `MDB_NOSYNC` (the wipe mechanism); rf=1 "test
  deployments" only; snapshot sizing (4× DB); SQLite as the single-node alternative.
- [recovering from failures](https://garagehq.deuxfleurs.fr/documentation/operations/recovering/) —
  every recovery path assumes a pre-armed belt or rf ≥ 2; Scenario-3 snapshot restore is our
  runbook recipe; rf=1 makes the snapshot interval a hard loss window.
- [durability & repairs](https://garagehq.deuxfleurs.fr/documentation/operations/durability-repairs/) —
  scrub is verify-only; `repair blocks` is the only orphan reaper (manual); native snapshots
  are the clean kind vs fs-level.
- [real-world deployment](https://garagehq.deuxfleurs.fr/documentation/cookbook/real-world/) —
  zones as failure domains, capacity balancing (usable = smallest zone), XFS-not-EXT4 for
  data, meta on SSD, "LMDB + snapshots or switch to Sqlite".
- [cluster layout](https://garagehq.deuxfleurs.fr/documentation/operations/layout/) — layout =
  versioned staged changes (plan/apply-shaped); apply once per version, one RPC host; the
  algorithm minimizes movement, capacity values steer distribution.

The single-node posture above is being retired: **`replication_factor = 3`, one Garage instance
per physical failure domain, node-local XFS storage — Longhorn drops out of the Garage data
path entirely** (engines replicate; storage stores singles — the same ruling moves CNPG to
replica-1 storage + *required* zone anti-affinity). Zones come from `machines.yaml`'s `zone`
field → `topology.kubernetes.io/zone`: physical box = zone, every pve-pool VM = `proxmox`.

- **Layout:** `wk-metal-01` (500G MX500), `wk-metal-04` (500G SATA), and interim third zone
  `proxmox` (wk-02) — losing the whole pve zone keeps quorum (2/3, reads+writes continue).
  Planned upgrade: a disk in hp-01 replaces wk-02 (`garage layout assign` + rebalance, no
  downtime). Capacity ~100G/zone balanced (usable = smallest zone); fits by reclaiming Garage's
  own 150Gi×2 Longhorn footprint from the same disks.
- **Layout ops discipline** (garagehq layout doc): stage assigns, review `layout show`, ONE
  `layout apply --version N` against ONE RPC host; never reuse a version number.
- **Engine:** LMDB stays — upstream recommends it for rf ≥ 2; metadata corruption on one node
  becomes `delete + garage repair tables` (resync from peers), not an incident. fsync +
  snapshots stay as belts.
- **Backup contracts to the logical-deletion class** (Garage has no S3 object versioning — a
  write key can delete irreversibly and replication propagates it): in-cluster CronJob syncing
  objects to a std-tier Longhorn PVC (not the Garage zones), pushgateway-alerted. No manual
  step, no external creds. Offsite stays parked (FU-137).

## Static-website serving (3902, live 2026-07-14)

`s3.web.rootDomain = ".teststuff.net"` (garage.tf): any **website-enabled** bucket is served
anonymously at `https://<global_alias>.teststuff.net` (HAProxy VIP → 40.16:3902 → Garage web;
the S3 API keeps 403ing anonymous reads — this is the one browser-consumable seam). Because the
**bucket alias IS the hostname**, website bucket aliases MUST be stack-namespaced
(`oracle-specs`, not `specs` — a generic alias squats the name for every future stack; bit live
on the first consumer, oracle-iac#7). Non-website buckets stay dark regardless of alias. Each
new site name still needs the OPNsense cert/HAProxy/Unbound entries (runbook §HTTPS name —
mind the sign-before-haproxy order).
