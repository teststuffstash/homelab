# Island facts — dependency upgrades

> The §Island facts block for the **dependency-upgrades** island (Renovate, version sets, the lock
> intake). Rules: [`islands/intake/rules/intake.md`](../../islands/intake/rules/intake.md) — this
> file holds only the island's facts, under `## Sources` the island's own rows of its §What you read
> table, and under `## What a ride can do` the recipe, write tier, gates and reach. Island list:
> [`spikes/context-and-autonomy.md`](../spikes/context-and-autonomy.md) §C7.

Body shape: edit

- **Repo** `teststuffstash/homelab`; paths `.github/renovate-global.json`, `version-sets/`,
  `argocd/resources/version-sets/`, `scripts/{renovate-*,lock-intake-lint*,dependency-coverage*}`,
  and the owning docs.
- **Owning docs to read** (the section the item names):
  [`dependency-upgrades.md`](../dependency-upgrades.md) (§2 Review = the lanes),
  [`dependency-classes.yaml`](../dependency-classes.yaml) (the class rulings),
  [`renovate.md`](../renovate.md) (policy; §Coordinator × Renovate — closing a Renovate PR is never a
  terminal action).
- **Membership** — `island_members dependency-upgrades` in
  [`intake-select.sh`](../../islands/intake/scripts/intake-select.sh): title `renovate` / `dependency` /
  `version set` / `S9` (the Renovate stint), or every `Touches` entry under the prefixes. Renovate's
  own PRs are not intake inputs — the lanes own them.
- **Majors are not a queue.** A major goes through the `major` lane's lens (upstream research +
  platform-compat under the lens's headings, `agents/major-handoff.sh`, human merge unless the class
  arms — [`dependency-upgrades.md`](../dependency-upgrades.md) §2 Review). An issue asking for a major
  bump is `seat` (or `standing` if no consumer needs it now); never write its body as queue-ready.
- **Gate / deploy**: lane by class (automerge / deps-review / major); a pin's merge reaches live by
  its class's edge (ArgoCD sync, the box's helm/tofu apply under the upgrade lease — ADR-150/152).
- **Operator-only**: lane and grouping rules in `renovate-global.json`, an `opentofu` major (the one
  one-way door — state stamp), version-set membership rulings (§Version SETS, owner #2014),
  anything the [stint](../glossary.md) container (#1985) marks pending.

## Sources

How a sitting runs a Prometheus query or a kube read: the LIVE READS block of
[`sitting.sh`](../../islands/intake/scripts/sitting.sh).

| question | read | note |
|---|---|---|
| Which class a dependency is in, and each class's proposer, gate, deploy edge, detector, revert and canary (the rulings register) | [`dependency-classes.yaml`](../dependency-classes.yaml); the joined table is the generated block in [`dependency-upgrades.md`](../dependency-upgrades.md) §The dependency inventory | edit the YAML, never the generated block (`devbox run dependency-coverage`) |
| What is still manual and what it waits on; the open gaps | [`dependency-upgrades.md`](../dependency-upgrades.md) §What is still manual and §Gap register | hand-kept, with its own read date |
| Where the lanes, grouping and release-age limits are declared | [`.github/renovate-global.json`](../../.github/renovate-global.json) (`packageRules`, `minimumReleaseAge`, `prHourlyLimit`) | operator-only to change; policy in [`renovate.md`](../renovate.md) |
| Is Renovate proposing at all | Prometheus `time() - max(github_renovate_last_pr_timestamp)` | seconds since its newest PR; a green Renovate workflow is not liveness; **experiment** |
| Which classes are complete, and when each was last proven | Prometheus `github_dependency_coverage_complete` and `time() - github_dependency_coverage_last_proven_timestamp` | one series per `class`, `class_name`; **experiment** |
| Which versions of a set run where | Prometheus `version_set_running_info{job="version_set_probe"}` | `consumer`, `tool`, `version` as labels; the declared sets: `version-sets/` and [`dependency-upgrades.md`](../dependency-upgrades.md) §Version SETS; **experiment** |
| Open Renovate PRs and their lane labels | `gh pr list --repo teststuffstash/homelab --label dependencies --json number,title,labels` | the lane is the second label (`automerge`, `deps-review`, `major`). Not intake inputs — the lanes own them; read only to see whether an item is already proposed. `[]` = none open |
| The island's alert rules | [`argocd/resources/version-sets/prometheusrule.yaml`](../../argocd/resources/version-sets/prometheusrule.yaml), and `RenovateSilent` / `DependencyClassProofStale` in [`argocd/resources/github-exporter/prometheusrule.yaml`](../../argocd/resources/github-exporter/prometheusrule.yaml); as deployed `kubectl -n monitoring get prometheusrules version-sets github-exporter` | — |

Never: a Renovate PR's diff as an intake input.

## What a ride can do

- **Recipe**: [`.agents/fix.yaml`](../../.agents/fix.yaml) (a `task/build` item: [`.agents/build.yaml`](../../.agents/build.yaml)).
  It refuses `.github/**` and this repo's `devbox.json|lock`; pins move only by the deploy
  pipeline's and Renovate's bump PRs (`pin-only-lint`), so a hand-edited pin is not a ride's.
- **Write tier** (`classify_touches` in [`agents/footprint.sh`](../../agents/footprint.sh), run 2026-11-20):
  `.github/renovate-global.json` and `devbox.json|lock` = `codeowner-author` → **`seat`**;
  `version-sets/**`, `argocd/resources/version-sets/**`, `scripts/renovate-lane-lint.sh`,
  `scripts/lock-intake-lint.py`, `docs/{dependency-upgrades.md,dependency-classes.yaml,renovate.md}` =
  `machine-merge`.
- **Gates**: `pr-open` runs `devbox run pr-gate` — the CI gates the diff selects plus `scan-secrets`; the map is
  [`scripts/diff-ci.sh`](../../scripts/diff-ci.sh).
  `scripts/lock-intake-lint*` selects `lock-intake-lint-test`; `argocd/resources/version-sets/**`
  selects `version-sets-selftest` and the manifest and rule lints; the docs select
  `follow-ups-lint` and `docs-graph-lint`. A bump PR's lane (automerge / deps-review / major)
  is the class's, not the ride's.
- **Reach**: the repo's one claim block — the list is [agent-loop.md §What a ride can do](agent-loop.md#what-a-ride-can-do).
  For this island: GitHub (PRs, run logs through `results-receiver.actions.githubusercontent.com`),
  the registry mirrors, `ghcr.io`, PyPI, and the gauges above in Prometheus.
- **Not reachable, so intake reads it and writes it into the body**: an upstream's release notes
  or changelog on any host not in that list (a major's upstream research is the `major` lane's
  lens, never a ride's guess), the Renovate dashboard's run logs beyond GitHub, and what version
  a machine outside the cluster runs (the box, the routers, the hypervisors).
