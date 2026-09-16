# 2026-09-16 — a targeted `tofu apply` for one node replaced three worker VMs

**First symptom:** 18:39–18:44Z, wk-02, wk-04 and then wk-01 go `NotReady`; Grafana, Alertmanager,
Argo, ArgoCD, Loki and the responder all Pending (operator: "grafana/alertmanager and argo went down?").
**Class:** self-inflicted, seat-driven — a targeted apply from the management box executed three
pending VM replacements that were never in the target set. **No data lost:** none of the 40 Longhorn
volumes had a replica on the three VMs (checked before recovery). Total platform outage ≈ 12 min.

## Timeline (UTC)

| when | what |
|---|---|
| 18:06 | PR#1740 merges: the worker Talos version moves to v1.13.10, so every worker VM's `file_id` has a pending REPLACE (accepted, "one at a time"). |
| 18:08 | Seat plans the wk-03 recreate with `-exclude` on the other VMs + the metal config applies: `3 to add, 3 to destroy` — exactly right. Applied 18:11 with `-replace` on wk-03's config apply added; the replace was silently not executed (3/3), so the fresh VM sat in maintenance mode, `up` timed out at 18:37. |
| 18:38 | Seat applies `-target='talos_machine_configuration_apply.node["wk-03"]' -replace=<same>` **without planning that exact command**. `-target` pulls the target's dependencies, and the config-apply resource depends on the whole `proxmox_virtual_environment_vm.node` resource, not on one instance — so every pending VM replacement came along: wk-01, wk-02 (pve) and wk-04 (nx-02) destroyed and recreated. `4 added, 4 destroyed`. |
| 18:44 | wk-03 Ready on v1.13.10. wk-01/02/04 are fresh Talos in maintenance mode; the seat's tail of the apply log showed only two of the four `Creating…` lines. |
| 18:47 | Operator: "if they are down then might as well do the upgrade" — the three fresh VMs already boot the v1.13.10 image, so the recovery IS the upgrade. |
| 18:48–18:50 | Recovery without tofu: each node's rendered config from `tofu console` on the box (`nonsensitive(data.talos_machine_configuration.node["<n>"].machine_configuration)`) → `talosctl apply-config --insecure -n <ip> -e <ip> -f <n>-config.yaml`. All three Ready 18:50, uncordoned; pods rescheduling. |

## Root cause

Two seat errors, one mechanism:

1. **Apply without planning the exact command.** The `-exclude` plan was read and was correct; the
   `-target` apply that followed had a different, unplanned scope. The seat card's "plan and review
   before any apply" means the *same arguments*, not a related plan an hour earlier.
2. **`-target` includes dependencies at RESOURCE granularity.** `talos_machine_configuration_apply.node`
   depends on `proxmox_virtual_environment_vm.node` as a whole, so targeting one instance drags every
   instance of the VM resource into the run — and any of them with a pending replace gets replaced.
   `-exclude` and `-target` cannot be combined, and `-replace` next to `-exclude` was ignored without
   an error, which is what pushed the seat toward `-target` in the first place.

## What held

- The pre-flight rule that matters most held: Longhorn replicas were nowhere on the VM tier, so a
  three-VM loss was an availability event, not a durability one. (Read BEFORE recovery, not after.)
- The control plane never blinked (cp-01 excluded by its own version variable — the PR#1740 split
  is what kept the CP out of the blast radius).
- `tofu console` on the box is a safe read path to a node's rendered config; `talosctl apply-config
  --insecure` finishes a fresh VM without touching the tofu graph at all.

## Residual actions

- **FU-248** — the recipe and the guard: a VM recreate is `-exclude`-shaped (never `-target` a
  config apply while any VM has a pending replace), the config-apply step is `console` +
  `apply-config --insecure`, and `mgmt-tf` should refuse an `apply` whose arguments were not planned
  first (plan file → apply plan file, the loop's own shape).
