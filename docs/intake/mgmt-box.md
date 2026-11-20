# Island facts — the management box

> The §Island facts block for the **mgmt-box** island (R12: holds main's tofu state, applies from
> master, the upgrade lease). Rules:
> [`islands/intake/rules/intake.md`](../../islands/intake/rules/intake.md) — this file holds only
> the island's facts, under `## Sources` the island's own rows of its §What you read table, and
> under `## What a ride can do` the recipe, write tier, gates and reach. Island list:
> [`spikes/context-and-autonomy.md`](../spikes/context-and-autonomy.md) §C7.

Body shape: edit

- **Repo** `teststuffstash/homelab`; island root `mgmt/` (`mgmt/nixos/`, `mgmt/scripts/`), plus
  `argocd/resources/{mgmt-metrics,upgrade-lease-reader,kube-prometheus-stack-lease}/` (the [upgrade lease](../dependency-upgrades.md), ADR-150) and the box
  verbs `scripts/{node,host,runner}-maintenance*`, `scripts/maintenance-window.sh`,
  `scripts/controlplane-upgrade.sh`.
- **Owning doc**: [`management-box.md`](../management-box.md) — read ONLY the §section the item
  names (MB2 belt, MB3 sentinel, MB4 reconciler, MB5 lease); it is the largest owning doc on any
  island.
- **Membership** — `island_members mgmt-box` in
  [`intake-select.sh`](../../islands/intake/scripts/intake-select.sh): title `mgmt` / `management box` /
  `upgrade lease`, or every `Touches` entry under the prefixes. Precedes the substrate and agent
  loop; a `Mgmt*Opnsense*` dig finding is the router pair's (earlier row).
- **How a merge reaches live**: `mgmt/` changes activate on the box by `mgmt-pull` →
  `nixos-rebuild test` → stamp (diff-gated; [`management-box.md`](../management-box.md) §The update
  loop); `argocd/resources/**` by ArgoCD. Belts ride `argocd/resources/mgmt-metrics/` and need a
  promtool fixture ([`agents/jail-seat-card.md`](../../agents/jail-seat-card.md) §Safety).
- **`seat`, always**: anything the box must APPLY to be proven (a new apply class, a capability
  ledger row), a [declared window](../glossary.md) or a drain on a surface the [capability ledger](../management-box.md#the-capability-ledger--what-the-box-has-been-tested-doing-on-its-own-fu-097) lists `attended` or `manual` (an `unattended` row is the box's own window and queues), the box's credentials/state (ADR-129, §Credentials),
  hardware (the pilot's replacement), and any sentinel policy widening (`policy/mgmt/**`,
  `codeowner-merge` — ADR-131's input allowlist is a security boundary).

## Sources

How a sitting runs a Prometheus query or a kube read: the LIVE READS block of
[`sitting.sh`](../../islands/intake/scripts/sitting.sh).

| question | read | note |
|---|---|---|
| What the box does on its own on a surface, what is attended, what is manual (the capability register) | [`management-box.md`](../management-box.md) §The capability ledger | decides `queue` vs `seat` for anything the box must apply; its live reads carry their own date |
| Where the box's units and their timers are declared | [`mgmt/nixos/hosts/mgmt/default.nix`](../../mgmt/nixos/hosts/mgmt/default.nix) (`grep -n OnCalendar mgmt/nixos/hosts/mgmt/default.nix`) | a merge reaches the box by the update loop, not at merge |
| Is the apply loop running | Prometheus `time() - mgmt_apply_last_ok_tick_timestamp_seconds{host="mgmt"}` | seconds since the last good tick |
| What the health belt says | Prometheus `mgmt_probe_check{host="mgmt"}` | one series per check, `status` and `reason` as labels |
| Where a node stands in a rollout | Prometheus `mgmt_reconcile_node_state{host="mgmt"}` and `mgmt_node_drift{host="mgmt"}` | value 1 on the node's current `state`; drift per `axis` |
| Is an upgrade lease open, and until when | Prometheus `upgrade_lease_info` and `mgmt_lease_active{host="mgmt"}` | an empty `upgrade_lease_info` with the query succeeding = no lease open. The record itself is a ConfigMap in `agent-coordinator` (`kubectl -n agent-coordinator get configmaps -l homelab.teststuff.net/upgrade-lease=true`) — **seat-only**: the sitting reads no ConfigMap |
| Where a lease's deadline and cap are declared | [`argocd/resources/kube-prometheus-stack-lease/upgrade-lease.sh`](../../argocd/resources/kube-prometheus-stack-lease/upgrade-lease.sh) header (the record) and [`management-box.md`](../management-box.md) §MB5 | the reader that turns it into the gauges: `argocd/resources/upgrade-lease-reader/` |
| The island's alert rules | `argocd/resources/mgmt-metrics/{prometheusrule,upgrade-lease,reconcile-rollout}.yaml` and `argocd/resources/upgrade-lease-reader/prometheusrule.yaml` (fixtures: the `*.promtool-test` files beside them); as deployed `kubectl -n monitoring get prometheusrules` (the `mgmt-*` and `upgrade-lease-reader` objects) | the router's rules in the same directory (`router-*`, `opnsense-drill`, `cert-carry`) are the router pair's |

Never: the box itself (no ssh from a sitting); `management-box.md` beyond the section the item names.

## What a ride can do

- **Recipe**: [`.agents/fix.yaml`](../../.agents/fix.yaml) (a `task/build` item: [`.agents/build.yaml`](../../.agents/build.yaml)).
  It refuses `mgmt/scripts/**` and the three box verbs outright (the box runs them from master).
- **Write tier** (`classify_touches` in [`agents/footprint.sh`](../../agents/footprint.sh), run 2026-11-20):
  `mgmt/scripts/**` and `scripts/{node-maintenance,maintenance-window,controlplane-upgrade}.sh` =
  `codeowner-author` ([`agents/iac-lane.md`](../agents/iac-lane.md) §The platform lane) →
  **`seat`**; `mgmt/nixos/**` and `policy/mgmt/**` = `codeowner-merge` (`mgmt/nixos/flake.lock`
  carved out to `machine-merge`); `scripts/{host,runner}-maintenance.sh`,
  `argocd/resources/{mgmt-metrics,upgrade-lease-reader,kube-prometheus-stack-lease}/**`,
  `docs/management-box.md` = `machine-merge`.
- **Gates**: `pr-open` runs `devbox run pr-gate` — the CI gates the diff selects plus `scan-secrets`; the map is
  [`scripts/diff-ci.sh`](../../scripts/diff-ci.sh).
  The `argocd/resources/**` dirs select `manifest-lint`, `argocd-validate-pins`,
  `component-check` and `prometheus-rules-lint` (a belt ships its promtool fixture);
  `scripts/{host,runner}-maintenance.sh` selects `maint-self-test`, `shellcheck-lint` and
  `sigpipe-lint`; `mgmt/nixos/**` selects no build gate — nothing in a PR evaluates the flake.
- **Reach**: the repo's one claim block — the list is [agent-loop.md §What a ride can do](agent-loop.md#what-a-ride-can-do).
  For this island that is the `mgmt_*` and `upgrade_lease_*` gauges in Prometheus and nothing else.
- **Not reachable, so intake reads it and writes it into the body**: the box (a LAN host: no ssh,
  no `nixos-rebuild`, no plan output), the lease ConfigMaps, the deployed rule objects in
  `monitoring`, and Loki. A ride cannot prove anything the box must apply — that is `seat`.
