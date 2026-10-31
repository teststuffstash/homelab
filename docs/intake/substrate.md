# Island facts — the cluster substrate

> The §Island facts block for the **substrate** island (3 CPs, disks, Garage, Longhorn, CNPG,
> services, the public edge). Rules: [`gateway/intake.md`](../../gateway/intake.md) — this file
> replaces only its §Island facts and island read rows. Island list:
> [`spikes/context-and-autonomy.md`](../spikes/context-and-autonomy.md) §C7.

- **Repo** `teststuffstash/homelab`; no single root — `tofu/` (main root + `cloudflare/`,
  `provisioning/`), `machines/`, `SERVICES.md`, the substrate `argocd/resources/` dirs (`garage-*`,
  `longhorn-*`, `talos-substrate`, `postgres`, `pg-backup`, `node-fstrim`, `smartctl-exporter`,
  `pve-metrics`), `ansible/{matchbox*,pve-*,garage-backup*}`, `scripts/{garage-,longhorn-,pg-backup,prometheus-rules-lint}`.
- **Owning docs to read** (the section the item names, not the whole file):
  [`controlplane-ha.md`](../controlplane-ha.md), [`storage-ledger.md`](../storage-ledger.md),
  [`garage.md`](../garage.md), [`longhorn-backup.md`](../longhorn-backup.md),
  [`SERVICES.md`](../../SERVICES.md).
- **Membership** — `island_members substrate` in
  [`intake-select.sh`](../../gateway/scripts/intake-select.sh). `tofu/` is the substrate's, but the
  router files under it (`tofu/opnsense-*.tf`) go to the router pair (longest prefix wins) and
  `tofu/github/` to the agent loop.
- **Write tier** (`classify_touches`, run 2026-10-31): every path above = `machine-merge` (the
  ADR-128 narrowed gate: `tofu/*.tf`, `ansible/**`, `machines/**` merge on CI + bot review —
  [`agents/iac-lane.md`](../agents/iac-lane.md) §The platform lane). Exceptions: the box verbs
  `scripts/{node-maintenance,maintenance-window,controlplane-upgrade}.sh` = `codeowner-author`
  (they are the mgmt-box island's anyway).
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
  window, a drain/cordon, a node reinstall or `talosctl upgrade` (never on a Proxmox nocloud VM —
  same §Safety), a Garage layout change, a Longhorn upgrade (CNPG restore points first,
  `pg-backup-now`), hardware, or the public edge's live checks (#1334's class).
