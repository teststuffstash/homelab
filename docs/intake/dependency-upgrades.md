# Island facts — dependency upgrades

> The §Island facts block for the **dependency-upgrades** island (Renovate, version sets, the lock
> intake). Rules: [`gateway/intake.md`](../../gateway/intake.md) — this file replaces only its
> §Island facts and island read rows. Island list:
> [`spikes/context-and-autonomy.md`](../spikes/context-and-autonomy.md) §C7.

- **Repo** `teststuffstash/homelab`; paths `.github/renovate-global.json`, `version-sets/`,
  `argocd/resources/version-sets/`, `scripts/{renovate-*,lock-intake-lint*,dependency-coverage*}`,
  and the owning docs.
- **Owning docs to read** (the section the item names):
  [`dependency-upgrades.md`](../dependency-upgrades.md) (§2 Review = the lanes),
  [`dependency-classes.yaml`](../dependency-classes.yaml) (the class rulings),
  [`renovate.md`](../renovate.md) (policy; §Coordinator × Renovate — closing a Renovate PR is never a
  terminal action).
- **Membership** — `island_members dependency-upgrades` in
  [`intake-select.sh`](../../gateway/scripts/intake-select.sh): title `renovate` / `dependency` /
  `version set` / `S9` (the Renovate stint), or every `Touches` entry under the prefixes. Renovate's
  own PRs are not intake inputs — the lanes own them.
- **Write tier** (`classify_touches`, run 2026-10-31): `.github/renovate-global.json` and
  `devbox.json|lock` = `codeowner-author` → **`seat`**; `version-sets/**`,
  `argocd/resources/version-sets/**`, `scripts/renovate-lane-lint.sh`, `scripts/lock-intake-lint.py`,
  the docs = `machine-merge`.
- **Majors are not a queue.** A major goes through the `major` lane's lens (upstream research +
  platform-compat under the lens's headings, `agents/major-handoff.sh`, human merge unless the class
  arms — [`dependency-upgrades.md`](../dependency-upgrades.md) §2 Review). An issue asking for a major
  bump is `seat` (or `standing` if no consumer needs it now); never write its body as queue-ready.
- **Gate / deploy**: lane by class (automerge / deps-review / major); a pin's merge reaches live by
  its class's edge (ArgoCD sync, the box's helm/tofu apply under the upgrade lease — ADR-150/152).
- **Operator-only**: lane and grouping rules in `renovate-global.json`, an `opentofu` major (the one
  one-way door — state stamp), version-set membership rulings (§Version SETS, owner #2014),
  anything the [stint](../glossary.md) container (#1985) marks pending.
