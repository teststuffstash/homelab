# Island facts — the cluster substrate

> The §Island facts block for the **substrate** island (3 CPs, disks, Garage, Longhorn, CNPG,
> services, the public edge). Rules:
> [`islands/intake/rules/intake.md`](../../islands/intake/rules/intake.md) — this file holds only
> the island's facts, under `## Sources` the island's own rows of its §What you read table, and
> under `## What a ride can do` the recipe, write tier, gates and reach. Island list:
> [`spikes/context-and-autonomy.md`](../spikes/context-and-autonomy.md) §C7.

Body shape: edit

- **Repo** `teststuffstash/homelab`; no single root — `tofu/` (main root + `cloudflare/`,
  `provisioning/`), `machines/`, `SERVICES.md`, the substrate `argocd/resources/` dirs (`garage-*`,
  `longhorn-*`, `talos-substrate`, `postgres`, `pg-backup`, `node-fstrim`, `smartctl-exporter`,
  `pve-metrics`), `ansible/{matchbox*,pve-*,garage-backup*}`, `scripts/{garage-,longhorn-,pg-backup,prometheus-rules-lint}`.
- **Owning docs to read** (the section the item names, not the whole file):
  [`controlplane-ha.md`](../controlplane-ha.md), [`storage-ledger.md`](../storage-ledger.md),
  [`garage.md`](../garage.md), [`longhorn-backup.md`](../longhorn-backup.md),
  [`SERVICES.md`](../../SERVICES.md).
- **Membership** — `island_members substrate` in
  [`intake-select.sh`](../../islands/intake/scripts/intake-select.sh). `tofu/` is the substrate's, but the
  router files under it (`tofu/opnsense-*.tf`) go to the router pair (longest prefix wins) and
  `tofu/github/` to the agent loop.
- **How a merge reaches live**: `argocd/resources/**` — merge IS deploy (ArgoCD). `tofu/*.tf` and
  `ansible/matchbox*` — the management box plans/applies from master
  ([`management-box.md`](../management-box.md) §MB3–MB4); `machines/machines.yaml` → the box's
  reconciler. So a `tofu/` or `machines/` body is queue-able only when the plan is a no-op on live
  or the box's own bracket covers it — otherwise `seat`.
- **Alerts / recording rules ship with a promtool fixture** (`*.promtool-rules` + `*.promtool-test`
  beside the rule, `prometheus-rules-lint`), and a rule born from an event carries a replay at the
  event's timestamps (detection before fix — [`agents/jail-seat-card.md`](../../agents/jail-seat-card.md)
  §Safety). A queue-ready body says which fixture rows.
- **`seat`, always**: anything needing a live apply outside the box's bracket, a maintenance
  window or drain/cordon on a surface the [capability ledger](../management-box.md#the-capability-ledger--what-the-box-has-been-tested-doing-on-its-own-fu-097) lists
  `attended` or `manual` (an `unattended` row queues), a node reinstall or `talosctl upgrade` (never on a Proxmox nocloud VM —
  same §Safety), a Garage layout change, a Longhorn upgrade (CNPG restore points first,
  `pg-backup-now`), hardware, or the public edge's live checks (#1334's class).

## Sources

How a sitting runs a Prometheus query or a kube read: the LIVE READS block of
[`sitting.sh`](../../islands/intake/scripts/sitting.sh).

| question | read | note |
|---|---|---|
| A storage tier's capacity and what is committed against it (the capacity ledger) | [`storage-ledger.md`](../storage-ledger.md) §The one hard rule and §Current shape | hand-typed, with its read date; a claim that is not in the ledger does not exist |
| The same, live, per disk | `kubectl -n longhorn-system get nodes.longhorn.io -o json` — `.spec.disks[].tags` for the tier, `.status.diskStatus[]` `storageMaximum` / `storageScheduled` / `storageAvailable`; or Prometheus `longhorn_disk_usage_bytes / longhorn_disk_capacity_bytes` | scheduled above maximum is over-provisioning, not an error (next row) |
| Where Longhorn's limits are declared (over-provisioning, replica placement, the storage classes) | [`tofu/longhorn.tf`](../../tofu/longhorn.tf) (`grep -n storageOverProvisioningPercentage tofu/longhorn.tf`) | applied by the management box from master; why the number is what it is: the ledger's §The Longhorn side has a SECOND sum |
| A volume's size, replica count and health; a claim's size | `kubectl -n longhorn-system get volumes.longhorn.io -o json`; `kubectl get pvc -A` | — |
| Garage: bucket quotas against the layout, and each node's disk | [`storage-ledger.md`](../storage-ledger.md) §Garage bucket quotas vs the layout; Prometheus `garage_bucket_bytes / garage_bucket_quota_bytes`, `garage_local_disk_avail / garage_local_disk_total`, `cluster_healthy{namespace="garage"}` | SLO and belts: [`garage.md`](../garage.md) §SLO, §Belts |
| The hypervisors' thin pools | Prometheus `pve_lvm_thin_pool_data_percent` | read the pool before a body writes GBs to a VM node |
| Which machines exist, their roles, disks and addresses | [`machines/machines.yaml`](../../machines/machines.yaml) | the one inventory; `tofu/locals.tf` and the generated tables read it |
| Which services exist and where | [`SERVICES.md`](../../SERVICES.md) | `LIVE` vs planned — never from memory |
| The Postgres clusters | Prometheus `cnpg_collector_up`; the objects are `kubectl get clusters.postgresql.cnpg.io -A` | the kubectl form is **seat-only**: neither read role lists `postgresql.cnpg.io` |
| The island's alert rules | `argocd/resources/{garage-alerts,garage-write-probe,garage-meta-rotation,longhorn-alerts,longhorn-backup,talos-substrate,pve-metrics,smartctl-exporter,node-fstrim,pg-backup}/prometheusrule.yaml` (fixtures: the `*.promtool-test` files beside them); as deployed `kubectl -n monitoring get prometheusrules` | a rule born from an event carries a replay at the event's timestamps |

Never: `talosctl`, a node's own API, or a tofu plan from a sitting (the plan is the box's, on the PR).

## What a ride can do

- **Recipe**: [`.agents/fix.yaml`](../../.agents/fix.yaml) (a `task/build` item: [`.agents/build.yaml`](../../.agents/build.yaml)).
- **Write tier** (`classify_touches` in [`agents/footprint.sh`](../../agents/footprint.sh), run 2026-11-20):
  every path of the island = `machine-merge` (the ADR-128 narrowed gate: `tofu/*.tf`,
  `tofu/cloudflare/**`, `tofu/provisioning/**`, `ansible/**`, `machines/**`, `SERVICES.md`, the
  substrate `argocd/resources/` dirs, `scripts/{garage-,longhorn-,pg-backup,prometheus-rules-lint}*`,
  the owning docs — [`agents/iac-lane.md`](../agents/iac-lane.md) §The platform lane).
  Exceptions: the box verbs `scripts/{node-maintenance,maintenance-window,controlplane-upgrade}.sh` =
  `codeowner-author` (they are the mgmt-box island's anyway).
- **Gates**: `pr-open` runs `devbox run pr-gate` — the CI gates the diff selects plus `scan-secrets`; the map is
  [`scripts/diff-ci.sh`](../../scripts/diff-ci.sh).
  `tofu/**` selects `tofu fmt -check` and `prometheus-rules-lint`; `machines/**` selects
  `machines-lint`; the `argocd/resources/**` dirs select `manifest-lint`, `argocd-validate-pins`,
  `component-check` and `prometheus-rules-lint`; `ansible/**` selects no gate of its own. A
  `tofu/` PR also gets the box's plan-on-PR ([`management-box.md`](../management-box.md) §MB3).
- **Reach**: the repo's one claim block — the list is [agent-loop.md §What a ride can do](agent-loop.md#what-a-ride-can-do).
  For this island: Prometheus (every gauge above) and kube reads in namespace `homelab` only.
- **Not reachable, so intake reads it and writes it into the body**: the Longhorn node and volume
  objects, claims and pods in any other namespace, nodes and other cluster-scoped kinds, the
  Postgres cluster objects, Loki (kernel logs included), `talosctl`, the hypervisors, the
  backup Garage and every other LAN host, and tofu state or a plan. A size, a free-space number
  or a placement a body turns on is read by intake and written into it with its source.
