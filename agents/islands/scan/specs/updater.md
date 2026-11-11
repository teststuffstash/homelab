---
id: IF-SCAN-UPDATER
use-cases: [UC-1]
schema: updater.schema.json
---
# `update-pr-branch.sh <owner/repo>` — keep one merge-ready PR per lane current

*Which PR in this lane has nothing but currency between it and auto-merge — and is it behind?*
The rulesets require an up-to-date branch (`strict_required_status_checks_policy`), and nothing
else updates PR branches, so a behind PR stalls silently with auto-merge armed and approval
given. The updater is the platform-native merge queue: per pass over one `gh pr list` snapshot
it runs three legs, acting on at most one main-leg update per (repo, base) lane (ADR-111,
ADR-125). It is woken by the `/update-pr` doorbell (the github-exporter's `maybe_dispatch_behind`
edge, payload `{repo}`) or the `*/15` sweep over the `stacks.json` universe, both serialized by
one mutex (`update-pr-argo.yaml`); a lost ring costs nothing. It runs as the `homelab-merge` App
(a workflow `GITHUB_TOKEN` push would not re-trigger `ci`); label writes ride a separate
identity (`UPDATER_LABEL_TOKEN` = `coordinator-git`), because the merge App deliberately holds no
Issues permission. Design narrative: [../docs/merge-path-mechanism.md §Updater decision logic](../docs/merge-path-mechanism.md#updater-decision-logic);
the state machine's MP-T02 (update) and MP-T06 (conflict) in
[merge-path-fsm.md](../../../../docs/agents/merge-path-fsm.md). Terms: [glossary.md](glossary.md),
[docs/glossary.md](../../../../docs/glossary.md).

> **External:** MUST — [GitHub REST · Pulls § Update a pull request branch](https://docs.github.com/en/rest/pulls/pulls#update-a-pull-request-branch) (page and anchor not read this session — verify during implementation) — merges the base into the head (no rebase), and `expected_head_sha` makes a concurrent push a 422 instead of a clobber — read off the wire (homelab#986); the `commits` connection at `--limit 100` exceeds GitHub's 500,000-node cap and the whole list is rejected — observed 2026-09-05..08.

## Interface — the machine half

**[`updater.schema.json`](updater.schema.json)** holds the per-PR fields the pass reads and the
actions it can emit.

| Requirement | Governs (schema) | Status |
|---|---|---|
| [SCAN-UPDATER-PICK](#scan-updater-pick) | `pr`, `action.update` | 🚧 WIP — no evidence pipeline yet (fixture: `updater`) |
| [SCAN-UPDATER-UNSTRAND](#scan-updater-unstrand) | `action.update` | 🚧 WIP — no evidence pipeline yet (fixture: `updater`) |
| [SCAN-UPDATER-CONFLICT](#scan-updater-conflict) | `action.label` | 🚧 WIP — no evidence pipeline yet (fixture: `updater`) |
| [SCAN-UPDATER-RENOVATE](#scan-updater-renovate) | `action.handback` | 🚧 WIP — no evidence pipeline yet (fixture: `updater`, `fu124-nudge`) |

**World for every table below:** [`board`](worlds/README.md#family-worlds-fixture-local-worldsname-named-in-rowspsv) — one repo, `#90` armed ∧ CLEAN, `#91` un-armed ∧ BEHIND; each row's `patch` adds its condition.

### SCAN-UPDATER-PICK

Leg 1 updates the oldest PR per lane that is **armed ∧ BEHIND ∧ [merge-ready](glossary.md#merge-ready)**
(`update-pr-branch.sh:142`, homelab#1452): `reviewDecision` APPROVED, or `""` (a ruleset that
requires no approval) with the reviewer bot's APPROVED newer than the newest non-merge commit, or
the `automerge` label. There is **no green requirement** — a base-side CI fix can only reach a PR
through an update (2026-07-10). `REVIEW_REQUIRED` is a park: never merge-ready, never probed
(#1649). The commit half of "approved at head" is a per-candidate `gh pr view --json commits`
probe; an unreadable probe holds. The lane is walked oldest-first and stops at the first
successful update, so a member whose update 422s every pass cannot hold its lane hostage
(#2203). `UPDATER_MERGE_READY_ONLY=0` restores the pre-#1452 pick (armed ∧ BEHIND).

#### Which PR does the main leg update?

| description | world | patch | env | expect? |
|---|---|---|---|---|
| armed-only-noop | board | — | — | noop |
| fifo-pick | board | add-two-behind-ready | — | picks-probe2 (`#101`, the older) |
| lane-hop-wedged-oldest | board | add-two-behind-ready | `…pulls_101_update_branch=fail` | lane-hop (`#102` updated in the same pass) |
| two-lanes-two-updates | board | add-two-lanes | — | picks-two-probe2 (one per base) |
| same-lane-one-update | board | add-two-same-goal-lane | — | picks-probe2 (one) |
| unreviewed-behind-no-update | board | add-two-behind | — | noop |
| bot-approved-head-update | board | add-bot-approved-head | — | picks-probe1 |
| stale-approval-no-update | board | add-bot-approved-stale | — | noop-probe1 |
| probe-unreadable | board | add-bot-approved-head | (probe fails) | noop-probe-hold |
| parked-approved-head-no-update | board | (`latestReviews` non-APPROVED, `reviews[]` APPROVED at head, `REVIEW_REQUIRED`) | — | noop |
| park-skip | board | add-park-skip | — | noop |
| merge-ready-only-off-legacy-pick | board | add-two-behind | `UPDATER_MERGE_READY_ONLY=0` | picks |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-UPDATER-PICK.md"

</details>

### SCAN-UPDATER-UNSTRAND

Leg 2 closes the CHANGES_REQUESTED ∧ BEHIND crack: an armed PR in that state is updated only when
its newest non-merge commit post-dates the newest reviewer-bot verdict — the fix round has
landed and needs currency to be reviewed again; breaker labels exclude it; unreadable commit or
review data holds (`update-pr-branch.sh:362`, rule #6).

#### Is a changes-requested, behind PR brought current?

| description | world | patch | env | expect? |
|---|---|---|---|---|
| unstrand-yes | board | add-cr-behind | — | unstrand-yes |
| unstrand-no | board | add-cr-behind | — | unstrand-no |
| unstrand-unreadable | board | add-cr-behind | — | unstrand-hold |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-UPDATER-UNSTRAND.md"

</details>

### SCAN-UPDATER-CONFLICT

Leg 3 labels every armed ∧ DIRTY PR `merge-conflict` (creating the label idempotently first) and
removes the label once the PR is no longer armed-and-DIRTY (`update-pr-branch.sh:412`). The
updater never resolves a conflict: the label is what the scan's `merge-conflict` clause reads
([SCAN-CLAUSE-PR](scan-decision.md#scan-clause-pr)). A failed `update-branch` (a 422 — race or
conflict, deliberately not told apart, homelab#1007) is a skip; the next pass re-lists.

#### Does an armed, conflicted PR carry the label — and only while it is?

| description | world | patch | env | expect? |
|---|---|---|---|---|
| conflict-dirty | board | dirty-90 | — | dirty-label |
| conflict-clear | board | label-conflict-90 | — | label-clear |
| update-fail | board | conflict-101 | `…pulls_101_update_branch=fail` | update-fail |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-UPDATER-CONFLICT.md"

</details>

### SCAN-UPDATER-RENOVATE

Renovate owns its own currency (ADR-141, ADR-153): `rebaseWhen: behind-base-branch` is the org
default, so an **untouched** Renovate PR (author Renovate ∧ every non-merge commit
Renovate-authored, both login shapes normalized — homelab#2007) is left alone; an updater merge
commit would make Renovate stop maintaining it. One exception: an untouched Renovate PR that is
armed, APPROVED and green is merge-ready, and the updater takes it. A Renovate PR the updater
already merged into and that is not merge-ready is **handed back** by ticking Renovate's own
rebase checkbox (leg 1b, `update-pr-branch.sh:331`), so Renovate rebuilds the branch and owns it
again. A worker-pushed Renovate PR (the FU-046 `deps-review` shape) is no longer Renovate's and
rides the ordinary legs. A CANCELLED check that a same-named sibling outlives is not red (#2754);
an unreadable rollup holds. The predicate functions live in `agents/renovate-currency.sh`, shared
with the scan's FU-124 nudge — one copy.

#### Whose currency is this Renovate PR?

| description | world | patch | env | expect? |
|---|---|---|---|---|
| renovate-untouched-no-update | board | add-renovate-approved | — | renovate-skip-probe1 |
| renovate-untouched-green-update | board | add-renovate-approved | — | picks-probe1-renovate |
| renovate-untouched-red-no-update | board | add-renovate-approved | — | renovate-skip-probe1 |
| renovate-worker-pushed-update | board | add-renovate-approved | — | picks-probe1-renovate |
| renovate-updater-merged-red-handback | board | add-renovate-approved | — | renovate-handback-probe1 |
| renovate-superseded-cancel-green-update | board | add-renovate-approved | — | picks-probe1-renovate |
| renovate-checks-unreadable-hold | board | add-renovate-approved | (check-runs read fails) | renovate-probe-hold |
| renovate-merged-current-red-handback | board | add-renovate-current-review | — | sweep-handback-probe1 |
| renovate-merged-current-pending-noop | board | add-renovate-current-review | — | sweep-silent-probe1 |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-UPDATER-RENOVATE.md"

</details>
