# Garage — self-hosted S3 object store

Garage (Deuxfleurs) is the in-cluster S3-compatible object store (ADR-031). It's the convergence
point for the sleep-tracking pipeline (ADR-045) and a future home for Longhorn/HA backups.

- **Deploy:** `tofu/garage.tf` (Helm, chart vendored at `argocd/charts/garage` — moved out of `tofu/` 2026-08-04 so ArgoCD can read it, FU-136 — Garage **v2.3.0**).
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
- Chart is kept **chart-shaped** (homelab adds only the LoadBalancer Service); migrating to an
  ArgoCD Application later is a re-point, not a rewrite (ADR-003/004).
- Updating Garage: re-vendor the chart at the new tag (see `argocd/charts/garage/VENDORED.md`), bump
  values in `garage.tf`, `plan`, review, `apply`.

## Durability — what actually stands between you and losing all of it

Measured 2026-08-04, because "can I afford to lose this?" deserves numbers rather than a shrug.

**~63.7 GB across 12 buckets**, and the shape matters more than the total: `ert-snapshots` is 60.4
GB / 252k objects of it and is **recoverable** — the oracle-fleet ingestion re-downloads its source
zip, so losing it costs a long re-ingest, not data. Everything else together is ~3.3 GB, and the
part that is genuinely irreplaceable is small: `agent-transcripts` (491 MB, the loop's own
observability record) and the `sleep-*` buckets (27.5 MB of real personal data). `allure-reports`
and `oracle-specs` regenerate from CI and from `specs/` in the stack repos; `loki` self-expires at
7 days.

**What protects it:** Garage runs `replication_factor = 1` on a single node, so *all* redundancy is
Longhorn's — 2 replicas per volume, currently healthy on distinct nodes (data `wk-metal-01`+`wk-02`,
meta `thinkcentre`+`wk-02`). Note `wk-02` carries a replica of both; losing it degrades both at once
without losing either.

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

## Static-website serving (3902, live 2026-07-14)

`s3.web.rootDomain = ".teststuff.net"` (garage.tf): any **website-enabled** bucket is served
anonymously at `https://<global_alias>.teststuff.net` (HAProxy VIP → 40.16:3902 → Garage web;
the S3 API keeps 403ing anonymous reads — this is the one browser-consumable seam). Because the
**bucket alias IS the hostname**, website bucket aliases MUST be stack-namespaced
(`oracle-specs`, not `specs` — a generic alias squats the name for every future stack; bit live
on the first consumer, oracle-iac#7). Non-website buckets stay dark regardless of alias. Each
new site name still needs the OPNsense cert/HAProxy/Unbound entries (runbook §HTTPS name —
mind the sign-before-haproxy order).
