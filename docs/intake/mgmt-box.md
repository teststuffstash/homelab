# Island facts — the management box

> The §Island facts block for the **mgmt-box** island (R12: holds main's tofu state, applies from
> master, the upgrade lease). Rules: [`gateway/intake.md`](../../gateway/intake.md) — this file
> replaces only its §Island facts and island read rows. Island list:
> [`spikes/context-and-autonomy.md`](../spikes/context-and-autonomy.md) §C7.

- **Repo** `teststuffstash/homelab`; island root `mgmt/` (`mgmt/nixos/`, `mgmt/scripts/`), plus
  `argocd/resources/{mgmt-metrics,upgrade-lease-reader,kube-prometheus-stack-lease}/` and the box
  verbs `scripts/{node,host,runner}-maintenance*`, `scripts/maintenance-window.sh`,
  `scripts/controlplane-upgrade.sh`.
- **Owning doc**: [`management-box.md`](../management-box.md) — read ONLY the §section the item
  names (MB2 belt, MB3 sentinel, MB4 reconciler, MB5 lease); it is the largest owning doc on any
  island.
- **Membership** — `island_members mgmt-box` in
  [`intake-select.sh`](../../gateway/scripts/intake-select.sh): title `mgmt` / `management box` /
  `upgrade lease`, or every `Touches` entry under the prefixes. Precedes the substrate and agent
  loop; a `Mgmt*Opnsense*` dig finding is the router pair's (earlier row).
- **Write tier** (`classify_touches`, run 2026-10-31): `mgmt/scripts/**` and
  `scripts/{node-maintenance,maintenance-window,controlplane-upgrade}.sh` = `codeowner-author` (the
  box runs them from master — [`agents/iac-lane.md`](../agents/iac-lane.md) §The platform lane) →
  **`seat`**; `mgmt/nixos/**` = `codeowner-merge` (`flake.lock` carved out to `machine-merge`);
  `scripts/{host,runner}-maintenance.sh`, `argocd/resources/mgmt-metrics/**`,
  `argocd/resources/kube-prometheus-stack-lease/**`, the doc = `machine-merge`.
- **How a merge reaches live**: `mgmt/` changes activate on the box by `mgmt-pull` →
  `nixos-rebuild test` → stamp (diff-gated; [`management-box.md`](../management-box.md) §The update
  loop); `argocd/resources/**` by ArgoCD. Belts ride `argocd/resources/mgmt-metrics/` and need a
  promtool fixture ([`agents/jail-seat-card.md`](../../agents/jail-seat-card.md) §Safety).
- **`seat`, always**: anything the box must APPLY to be proven (a new apply class, a capability
  ledger row), a declared window or a drain, the box's credentials/state (ADR-129, §Credentials),
  hardware (the pilot's replacement), and any sentinel policy widening (`policy/mgmt/**`,
  `codeowner-merge` — ADR-131's input allowlist is a security boundary).
