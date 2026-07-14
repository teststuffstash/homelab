# Garage — self-hosted S3 object store

Garage (Deuxfleurs) is the in-cluster S3-compatible object store (ADR-031). It's the convergence
point for the sleep-tracking pipeline (ADR-045) and a future home for Longhorn/HA backups.

- **Deploy:** `tofu/garage.tf` (Helm, chart vendored at `tofu/charts/garage`, Garage **v2.3.0**).
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
$G layout assign -z dc1 -c 10G <NODE_ID>
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
- Updating Garage: re-vendor the chart at the new tag (see `charts/garage/VENDORED.md`), bump
  values in `garage.tf`, `plan`, review, `apply`.

## Static-website serving (3902, live 2026-07-14)

`s3.web.rootDomain = ".teststuff.net"` (garage.tf): any **website-enabled** bucket is served
anonymously at `https://<global_alias>.teststuff.net` (HAProxy VIP → 40.16:3902 → Garage web;
the S3 API keeps 403ing anonymous reads — this is the one browser-consumable seam). Because the
**bucket alias IS the hostname**, website bucket aliases MUST be stack-namespaced
(`oracle-specs`, not `specs` — a generic alias squats the name for every future stack; bit live
on the first consumer, oracle-iac#7). Non-website buckets stay dark regardless of alias. Each
new site name still needs the OPNsense cert/HAProxy/Unbound entries (runbook §HTTPS name —
mind the sign-before-haproxy order).
