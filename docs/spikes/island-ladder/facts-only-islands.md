# Facts-only islands — position on the island maturity ladder

> Part of the island-ladder spike ([README](README.md)). Read at homelab `f1be04ca`, 2026-11-22.
> Covers the five islands that exist for intake only as a facts file and a selector row, with no
> directory under `islands/`: agent-loop, dependency-upgrades, mgmt-box, router-pair, substrate.

## What it is

Each island is a row in [`intake-select.sh`](../../../islands/intake/scripts/intake-select.sh)
(`island_members`: a title regular expression plus `Touches` path prefixes; `island_pattern`: a
text regular expression for dig findings) and a facts file under `docs/intake/`. None has a README,
specs root or tests root of its own; all five pass `facts-check.sh` (exit 0, no output).

- **agent-loop** ([facts](../../intake/agent-loop.md)) — everything under `agents/`, `docs/agents/`,
  `.agents/`, `tofu/github/`, the openrouter-proxy and AgentStack resources, that no carved island
  (gateway, scan, launch, retro, intake) has taken. Titles `scan:` / `coordinator` / `reviewer` /
  `ride` / `responder` / `dig` / `fixer` / …. Also receives every bot-filed issue no island claims
  (`ATTRIBUTION_ISLAND=agent-loop`). Alerts: pushgateway, agentstack, openrouter-proxy,
  github-exporter, argo-workflows-alerts rule files.
- **dependency-upgrades** ([facts](../../intake/dependency-upgrades.md)) — Renovate's lanes
  (`.github/renovate-global.json`), version sets, `lock-intake-lint`, `dependency-coverage`. Alerts:
  `version-sets` (5) plus `RenovateSilent` and `DependencyClassProofStale` in github-exporter.
- **mgmt-box** ([facts](../../intake/mgmt-box.md)) — the management box: `mgmt/` (NixOS host and
  scripts), the upgrade lease, the box verbs (`scripts/{node,host,runner}-maintenance*`,
  `maintenance-window.sh`, `controlplane-upgrade.sh`). Alerts: 35 across `mgmt-metrics/`
  (`prometheusrule`, `upgrade-lease`, `reconcile-rollout`) and `upgrade-lease-reader/`.
- **router-pair** ([facts](../../intake/router-pair.md)) — the OPNsense CARP pair, the test VM and the
  rebuild drill: `ansible/opnsense-*`, `opnsense/`, `tofu/opnsense-*.tf`, `scripts/opnsense-*`. Alerts:
  15 in `mgmt-metrics/{router-*,opnsense-drill,cert-carry}.yaml` and `opnsense-config-backup/`, plus
  `RouterPairMasterCount` and `RouterWanGateSilent` in `pve-metrics/`.
- **substrate** ([facts](../../intake/substrate.md)) — control planes, disks, Garage, Longhorn,
  CloudNativePG, `SERVICES.md`, the public edge: `tofu/` (minus router and GitHub files),
  `machines/`, the substrate `argocd/resources/` directories. Alerts: 63 across ten rule files.

Alert counts: `grep -c -- '- alert:'` over the files each facts file names.

## Position

| Rung | agent-loop | dependency-upgrades | mgmt-box | router-pair | substrate |
|---|---|---|---|---|---|
| R1 Boundary | partial — facts + row; root `agents/` is the old code (n1) | partial — facts + row | partial — facts + row | partial — facts + row | partial — facts + row, no single root |
| R2 Specs | does not fit (n2) | does not fit; equivalent: `dependency-classes.yaml` (n3) | does not fit; equivalent: capability ledger (n4) | does not fit; equivalent: drill realism score + router-move §Status (n5) | does not fit; equivalent: storage ledger, Garage SLO (n6) |
| R3 Evidence | old-style: 271 replay families (n2) | partial: `lock-intake-lint-test`, `version-sets-selftest`, 1 promtool test | partial: 11 promtool tests, `maint-self-test` | partial: 7 promtool tests, drill behaviour probes | partial: 17 promtool tests over 10 rule dirs; `node-fstrim` has none |
| R4 Worlds | old-style: `agents/replay/worlds` (2) | does not fit | does not fit | reached in its own form: the drill VM built from nothing (n5) | does not fit |
| R5 Gates | reached (old): clause-replay ratchet ADR-103 | reached: lanes by class + diff-ci | partial: `mgmt/nixos/**` selects no build gate | reached: `opnsense-test-vm` required check | partial: `ansible/**` selects no gate; box plan-on-PR for `tofu/` |
| R6 Replaces the old | inverse: shrinks (n2) | does not fit | does not fit | does not fit | does not fit |
| R7 Metrics | reached | reached (no own dashboard found) | reached: 35 alerts + `dashboard-mgmt-box.json` | partial: 17 alerts, 1 panel in the mgmt-box dashboard | reached: 63 alerts + Garage dashboards |
| R8 Feedback loop | partial | partial | partial | partial: 14 of 15 rules `triage: none` (n7) | partial: 15 of 63 `triage: none` |
| R9 Intake | reached (n8) | reached | reached | reached | reached |
| R10 Learns | partial: shared rules only (n9) | partial (n9) | partial (n9) | partial (n9) | partial (n9) |

Notes:

- **n1** The facts file names `agents/` as the island root, but every file there is a live old
  member; there is no "new" side.
- **n2** [`agents/replay/README.md`](../../../agents/replay/README.md) §Index lists 521 fixtures in
  271 top-level families (`fixtures/<family>/…`); [`families.tsv`](../../../agents/replay/families.tsv)
  is only the cleanup move-5 table (177 old dirs → 85 families). Matching the 271 against the replay
  lists in the scan, launch and retro READMEs (globs expanded): 134 are claimed; of the other 137,
  32 are named somewhere under `islands/{scan,launch,retro}/specs`, which leaves **105 families no
  carved island names**. They group as: the revert chains (`deploy-revert-*` 4, `tofu-image-revert-*`
  8, `tofu-provider-revert-*` 6, `workflow-pin-revert-*` 9 — source
  `agents/coordinator/deploy-revert-argo.yaml`); the reviewer (`reviewer-*` 11,
  `specs-review-body-edit`, `tool-gap-surfaces`, `loop-fetch-guard`); the responder (`responder-*`
  12); scan-sourced residue not in scan's lists (`assembly-*` 7, `merged-closeout-*` 3,
  `renovate-rebase-tick-*` 4, `stale-*` 3, `sprout-report-*` 2, `body-footprint-mismatch`, …);
  `fix-debounce` 2, `research-*` 2, `epic-dispositions`, `board-*` 2, `images-env` 2, and about 25
  source-less lint/helper families (`ci-cause-grammar`, `asvs`, `lens-posture`, `sigpipe-lint`, …).
- **n3** [`dependency-classes.yaml`](../../dependency-classes.yaml) rules each class's proposer, gate,
  deploy edge, detector, revert and canary; the generated table in
  [`dependency-upgrades.md`](../../dependency-upgrades.md) carries "Last proven E2E" per class (a PR
  number each) — a requirement row with its evidence, not in allure shape.
- **n4** [`management-box.md`](../../management-box.md) §The capability ledger: one row per surface,
  mode `unattended` / `attended` / `manual`, "last proven" and evidence. A surface becomes
  `unattended` only on its first unattended success — the same rule as a WIP mark lifting.
- **n5** [`opnsense-test-vm.md`](../../opnsense-test-vm.md) §The rebuild drill: weekly, builds OPNsense
  from nothing, runs all router code, probes behaviour, then scores `config.xml` against prod
  (`opnsense/drill/config-compare.py`, buckets) — `MgmtOpnsenseDrillScoreRegressed`.
- **n6** [`storage-ledger.md`](../../storage-ledger.md) ("a claim that is not in the ledger does not
  exist"), [`garage.md`](../../garage.md) §SLO, `machines/machines.yaml` as the one inventory.
- **n7** Router rules carry `triage: none` because the cause sits in the box journal, beyond the
  responder's reach (comment in `router-verdict.yaml`). Counts: label lines matching `triage: none`;
  mgmt-box 19 of 35, dependency-upgrades 3 of 5. Dig findings for all five islands are routed by
  `island_pattern` text match — only the gateway has an `island_alert_rules` row.
- **n8** `intake-select.sh --list-islands` prints all five (exit 0); `IslandIntakeStale` watches
  `island_intake_last_run_timestamp_seconds` per island.
- **n9** `git log` on each facts file: 3–6 commits, all intake-wide (#3549, #3570, #3637) except
  router-pair's #3621 (a router change). None is an edit born from that island's own stall. The
  shared escape read ([`intake-escape.md`](../../../islands/intake/rules/intake-escape.md)) exists.

## Does the ladder fit?

For the four infrastructure islands (the operator's "platform not yet split" ground) the ladder
splits in two: rungs about **operating** fit, rungs about **rebuilding a component from specs** do not.

- **R1 Boundary** — fits, but the deliverable is the facts file and the selector row, both done. A
  README "stating what it replaces" has nothing to say: they replace nothing.
- **R2 Specs** — no allure pages, and none are needed. Each already has a hand-kept requirement
  register with a proof column: classes (dependency-upgrades), capability ledger (mgmt-box),
  router-move §Status plus drill buckets (router-pair), storage ledger and SLOs (substrate). The
  equivalent rung is "a register where every row names its last proof".
- **R3 Evidence** — the equivalent is a **promtool-tested alert rule**, and for an event-born rule a
  replay at the event's timestamps (substrate facts, "detection before fix"). That is the
  infrastructure island's rule-labelled case. Gap: `node-fstrim` ships rules with no test.
- **R4 Worlds** — only router-pair has one: the rebuild drill is a world built from git and
  measured against prod. The others' world is the live cluster; recording it adds nothing.
- **R5 Gates** — fits as is: diff-ci gates, the box's plan-on-PR, `opnsense-test-vm`. The spec gate,
  join ratchet and specs reviewer do not apply. Real gaps: `mgmt/nixos/**` and `ansible/**` select
  no gate of their own.
- **R6 Replaces the old** — does not apply to the four.
- **R7 Metrics** — fits fully and is these islands' strongest rung.
- **R8 Feedback loop** — fits; the **experiment** is the declared maintenance window with baseline,
  alert watch and before/after comparison
  ([`maintenance-window` skill](../../../.claude/skills/maintenance-window/SKILL.md),
  `scripts/maintenance-window.sh`), and for the box its lease (commit-confirm). The facts files
  already mark reads as `experiment`. What is missing is the routing half: alerts reach intake by
  text pattern, and router-pair's rules mostly opt out of triage.
- **R9 Intake** — fits and is reached.
- **R10 Learns** — fits; it has not run for these five specifically.

**agent-loop is different.** It is the remainder of the loop not yet carved: the reviewer and
specs reviewer, the responder and dig, the revert chains, fix-debounce, research fan-out, epic
dispositions, the board, and scan-sourced clauses scan has not listed (n2: 105 families). Climbing
for it means **shrinking**: each family moves to a carved island's README (or a new `review` /
fresh `intake` island, both "not started" in [`islands/README.md`](../../../islands/README.md)) until
the island is empty. It should not get specs of its own. Its R2–R6 cells measure what is left, not
progress.

**Do these five need a roadmap?** The four infrastructure islands: no ladder roadmap — a facts file,
the alert belts and their existing registers are enough. Their forward work already has homes
(`ROADMAP.md` §Deploy paths, FU-297, FU-319, FU-235) and the intake sitting reads them. agent-loop:
its roadmap is the carve list — which family goes to which island, in what order.

## Not on the draft ladder

- **A proof register with "last proven" per row** (classes, capability ledger, drill) — the
  infrastructure form of R2+R3 together.
- **Operating mode per surface** (`unattended` / `attended` / `manual`) — how much the box does alone.
- **A revert path per class** (dependency-upgrades' revert column, the deploy-revert chains).
- **A canary** — ruled "detector + revert substitutes" for one cluster; router-pair's BACKUP node is
  the one real second instance.

## The island's own items

- dependency-upgrades: the S9 [stint](../../glossary.md) #1985 and its children #1988, #1991; #2605 (xr-render vs
  Renovate bumps); #3663. Majors stay `seat`.
- mgmt-box: `mgmt/nixos/**` has no PR build gate — nothing filed.
- router-pair: the box has refused the BACKUP converge since 2026-10-31 (FU-297); MASTER converge
  is a seat act; `ansible --check` misses `raw` post tasks (dependency-upgrades class 9 row).
- substrate: class-6 bumps have no owner (FU-319); one undetected node-state axis (FU-235);
  `node-fstrim` has no promtool test — nothing filed; garage-write-probe #1571, #1572;
  prometheus-rules-lint #1563.
- agent-loop: the carve list itself — nothing filed.

## In flight

Open issues by title cue only (one `gh issue list --state open`, 102 open; the selector's `Touches`
rule not reproduced): router-pair 0, mgmt-box 0, dependency-upgrades 4 (#1988, #1991, #2605, #3663),
substrate 3 (#1563, #1571, #1572), agent-loop 15 (23 title matches minus 8 `scan island:` titles,
which the scan row takes first) — for example #3426 and #1280 (ci-red lane), #2182 (reviewer),
#1224 (ADR-103 ratchet), #2601 (ride). All serve R8 (a defect fed back); none serves R2–R6.

## Next steps, in order

1. R3, substrate: a promtool test for `node-fstrim` — nothing filed; waits on nothing.
2. R8, all four: decide whether dig findings for these islands should route by alert rule file
   (as the gateway's `island_alert_rules`) instead of text — nothing filed; a seat decision.
3. R5, mgmt-box and router-pair: name the missing gate for `mgmt/nixos/**` and `ansible/**` — nothing
   filed; router-pair's real gate is the test VM, so mgmt-box first.
4. R6 inverse, agent-loop: assign the 105 unnamed families to carved islands, revert chains and
   reviewer first (largest groups) — nothing filed; waits on the `review` island starting.
5. R10, all five: let the escape and wait records accumulate per island before any facts edit.

## What it can lend, what it should borrow

- Lend: the proof-register shape — `dependency-classes.yaml` + `scripts/dependency-coverage.py`
  (generated table, `github_dependency_coverage_last_proven_timestamp` gauge) could carry any
  island's "last proven" per rule. The drill's `config-compare.py` buckets (declared / drift /
  unmanaged) are a world-versus-prod score another island could copy for its recorded worlds.
- Lend: promtool fixtures beside every rule and `prometheus-rules-lint` — R7's test half for all.
- Borrow: the gateway's `island_alert_rules` row in `intake-select.sh` for alert-based routing.
- Note: scan already rebuilds `major-handoff` (dependency-upgrades' major lane) and the Renovate
  updater under `islands/scan/`; the revert chains are dependency-upgrades' revert column but sit
  in agent-loop by path.

## Three-group sort

- R1 Boundary (facts file + selector row) — **common**: every island, these five included.
- R2 Specs — **common in essence** (a requirement register with a proof per row); the allure shape
  is **component-only** (platform-common for software islands, stack-common for oracle-fleet).
- R3 Evidence — **common** as "every rule has a case that can fail" (promtool for alerts);
  rows-as-test-source is component-only.
- R4 Worlds — **component-only**; router-pair's drill is island-only.
- R5 Gates — diff-selected CI **common**; spec gate, join ratchet, specs reviewer component-only.
- R6 Replaces the old — **platform-common, components only**; does not apply to infrastructure.
- R7 Metrics, R8 Feedback loop, R9 Intake, R10 Learns — **common**, literally every island.
- Maintenance window as experiment — platform-common (infrastructure islands).
- agent-loop shrinking — island-only.

## Not verified

- Whether each island's sittings have succeeded recently (no cluster or Prometheus query).
- Issue membership by `Touches` (the selector was not run against live issues).
- The 105-family figure uses word matches over READMEs and specs; a family named only in prose
  elsewhere could be claimed. The gateway README was searched and names no replay dirs.
- Whether Longhorn or Renovate have a dashboard outside `argocd/resources/*/dashboard*.json`.
