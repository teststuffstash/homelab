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
Issues permission. Design narrative: [docs/agents/merge-path.md §Updater decision logic](../../../docs/agents/merge-path.md#updater-decision-logic);
the state machine's MP-T02 (update) and MP-T06 (conflict) in
[merge-path-fsm.md](../../../docs/agents/merge-path-fsm.md). Terms: [glossary.md](glossary.md),
[docs/glossary.md](../../../docs/glossary.md).

> **External:** MUST — [GitHub REST · Pulls § Update a pull request branch](https://docs.github.com/en/rest/pulls/pulls#update-a-pull-request-branch) (page and anchor not read this session — verify during implementation) — merges the base into the head (no rebase), and `expected_head_sha` makes a concurrent push a 422 instead of a clobber — read off the wire (homelab#986); the `commits` connection at `--limit 100` exceeds GitHub's 500,000-node cap and the whole list is rejected — observed 2026-09-05..08.

## Interface — the machine half

**[`updater.schema.json`](updater.schema.json)** holds the per-PR fields the pass reads and the
actions it can emit.

| Requirement | Governs (schema) | Status |
|---|---|---|
| [SCAN-UPDATER-PICK](#scan-updater-pick) | `pr`, `action.update` | 🚧 WIP → #3389 — rule-labelled tests in islands/scan/tests/test_updater.py; no evidence publisher for this root (fixture: `updater`) |
| [SCAN-UPDATER-UNSTRAND](#scan-updater-unstrand) | `action.update` | 🚧 WIP → #3389 — rule-labelled tests in islands/scan/tests/test_updater.py; no evidence publisher for this root (fixture: `updater`) |
| [SCAN-UPDATER-CONFLICT](#scan-updater-conflict) | `action.label` | 🚧 WIP → #3389 — rule-labelled tests in islands/scan/tests/test_updater.py; no evidence publisher for this root (fixture: `updater`) |
| [SCAN-UPDATER-RENOVATE](#scan-updater-renovate) | `action.handback` | 🚧 WIP → #3389 — rule-labelled tests in islands/scan/tests/test_updater.py (updater family); the `fu124-nudge` half is the scan clause's, not built (fixture: `updater`, `fu124-nudge`) |

**World for every table below:** [`board`](worlds/README.md#family-worlds-fixture-local-worldsname-named-in-rowspsv) — one repo, `#90` armed ∧ CLEAN, `#91` un-armed ∧ BEHIND; each row's `patch` adds its condition.

**Legend — the `expect?` literals.** Each decodes the recorded action stream (`expected/<literal>.txt`) into what it observes. Every stream starts with the one `gh pr list` snapshot; "probe" is a per-candidate `gh pr view --json commits` call.

| literal | probes | updates issued | other observable |
|---|---|---|---|
| `noop` | 0 | none | the line `no armed+BEHIND PR to update` |
| `noop-probe1` | 1 (the candidate) | none | as `noop` |
| `noop-probe-hold` | 1, unreadable | none | `commit probe unreadable — HOLDING`, then `no armed+BEHIND PR to update` |
| `picks` | 0 | one `update-branch` PUT for the picked PR | `updating #n (oldest armed+BEHIND, FIFO)` |
| `picks-probe1` | 1 | one PUT | as `picks` |
| `picks-probe2` | 2 (both candidates) | one PUT, for the older PR | as `picks` |
| `picks-two-probe2` | 2 | two PUTs, one per base lane | an `updating` line per PR |
| `lane-hop` | 2 | PUT for the older PR (422, skipped), then PUT for the lane's next PR | `update of #n failed (422) — skipping`, then `updating #n (lane hop …)`; gh's stderr passes through |
| `picks-probe1-renovate` | 1, plus the rollup reads (check-runs, status) | one PUT for the Renovate PR | as `picks` |
| `renovate-skip-probe1` | 1, plus the rollup reads | none | `Renovate-authored, untouched and not green … skipping` |
| `renovate-probe-hold` | 1, then the check-runs read fails | none | `commit probe unreadable — HOLDING` |
| `renovate-handback-probe1` | 1, plus the rollup reads | none | hand-back: the PR body is read, then PATCHed with the rebase box ticked; leg-1b `handed back to Renovate` line, then `no armed+BEHIND PR to update` |
| `sweep-handback-probe1` | 1, plus the rollup reads | none | the same hand-back (body read, PATCH ticking the box), printed by the sweep as `handback[…]` after `no armed+BEHIND PR to update` |
| `sweep-silent-probe1` | 1, plus the rollup reads | none | no hand-back, no label op, no skip line: only `no armed+BEHIND PR to update` |
| `unstrand-yes` | 1 (`--json commits,reviews`) | one PUT for the CR ∧ BEHIND PR | `unstrand: updating CR-and-behind PR #n (new content since verdict)` |
| `unstrand-no` | 1 (`commits,reviews`) | none | `unstrand: … NO new content since the verdict … not updating` |
| `unstrand-hold` | 1 (`commits,reviews`), unreadable | none | `unstrand: … probe unreadable — HOLDING` |
| `dirty-label` | 0 | none | label op (`action.label.op` = add): the label created with `POST …/labels`, then `POST …/issues/n/labels` on the DIRTY PR |
| `label-clear` | 0 | none | label op (`action.label.op` = remove): `DELETE …/issues/n/labels/merge-conflict` |
| `update-fail` | 1 | one PUT for `#101`, which fails | `update of #101 failed (422) — skipping; next pass retries`; gh's stderr on ERR; no label op |

### SCAN-UPDATER-PICK

Leg 1 updates the oldest PR per lane that is **armed ∧ BEHIND ∧ [merge-ready](glossary.md#merge-ready)**
(`update-pr-branch.sh:142`, homelab#1452): `reviewDecision` APPROVED, or `""` (a ruleset that
requires no approval) with the reviewer bot's APPROVED newer than the newest non-merge commit, or
the `automerge` label. There is **no green requirement** (except for untouched or updater-merged Renovate PRs, see [merge-ready](glossary.md#merge-ready)) — a base-side CI fix can only reach a PR
through an update (2026-07-10). `REVIEW_REQUIRED` is a park: never merge-ready, never probed
(#1649). The commit half of "approved at head" is a per-candidate `gh pr view --json commits`
probe; an unreadable probe holds. The lane is walked oldest-first and stops at the first
successful update, so a member whose update 422s every pass cannot hold its lane hostage
(#2203). `UPDATER_MERGE_READY_ONLY=0` restores the pre-#1452 pick (armed ∧ BEHIND).

#### Which PR does the main leg update?

| description | world | patch | base | review | env | expect? |
|---|---|---|---|---|---|---|
| armed-only-noop | board | — | — | — (no armed ∧ BEHIND PR: `#90` is CLEAN, `#91` un-armed) | — | noop |
| fifo-pick | board | add-two-behind-ready | `#101`, `#102` → master | `reviewDecision ""`, the bot's `reviews[]` APPROVED post-dates the newest non-merge commit (both PRs) | — | picks-probe2 (`#101`, the older) |
| lane-hop-wedged-oldest | board | add-two-behind-ready | `#101`, `#102` → master | `reviewDecision ""`, the bot's `reviews[]` APPROVED post-dates the newest non-merge commit (both PRs) | `STUB_GH_api_repos_teststuffstash_testrepo_pulls_101_update_branch=fail` | lane-hop (`#102` updated in the same pass) |
| two-lanes-two-updates | board | add-two-lanes | `#101` → master, `#110` → goal/x | `reviewDecision ""`, the bot's `reviews[]` APPROVED post-dates the newest non-merge commit (both PRs) | — | picks-two-probe2 (one per base) |
| same-lane-one-update | board | add-two-same-goal-lane | `#110`, `#111` → goal/x | `reviewDecision ""`, the bot's `reviews[]` APPROVED post-dates the newest non-merge commit (both PRs) | — | picks-probe2 (one) |
| unreviewed-behind-no-update | board | add-two-behind | `#101`, `#102` → master | `reviewDecision ""`, no review, no `automerge` label | — | noop |
| bot-approved-head-update | board | add-bot-approved-head | `#141` → master | `reviewDecision ""`, the bot's `reviews[]` APPROVED post-dates the newest non-merge commit | — | picks-probe1 |
| stale-approval-no-update | board | add-bot-approved-stale | `#142` → master | `reviewDecision ""`, the bot's APPROVED is older than a later content commit (stale) | — | noop-probe1 |
| probe-unreadable | board | add-bot-approved-head | `#141` → master | `reviewDecision ""`, the bot's `reviews[]` APPROVED post-dates the newest non-merge commit; the commit probe `pr-view-141.json` is a non-JSON body | (probe fails) | noop-probe-hold |
| parked-approved-head-no-update | board | add-parked-approved-head | `#150` → master | `REVIEW_REQUIRED` (park); `latestReviews` bot COMMENTED, `reviews[]` bot APPROVED at head | — | noop |
| park-skip | board | add-park-skip | `#130` → master | `REVIEW_REQUIRED` (park); `latestReviews` bot APPROVED | — | noop |
| merge-ready-only-off-legacy-pick | board | add-two-behind | `#101`, `#102` → master | `reviewDecision ""`, no review, no `automerge` label (not merge-ready) | `UPDATER_MERGE_READY_ONLY=0` | picks |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-UPDATER-PICK.md"

</details>

### SCAN-UPDATER-UNSTRAND

Leg 2 closes the CHANGES_REQUESTED ∧ BEHIND crack: an armed PR in that state is updated only when
its newest non-merge commit post-dates the newest reviewer-bot verdict — the fix round has
landed and needs currency to be reviewed again; breaker labels exclude it; unreadable commit or
review data holds (`update-pr-branch.sh:362`, rule #6).

#### Is a changes-requested, behind PR brought current?

| description | world | patch | probe | env | expect? |
|---|---|---|---|---|---|
| unstrand-yes | board | add-cr-behind | newest non-merge commit 12:00 after the bot's CHANGES_REQUESTED 11:00 | — | unstrand-yes |
| unstrand-no | board | add-cr-behind | newest non-merge commit 10:00 before the bot's CHANGES_REQUESTED 11:00 (the 12:00 merge commit is not content) | — | unstrand-no |
| unstrand-unreadable | board | add-cr-behind | unreadable (non-JSON body) | — | unstrand-hold |

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

| description | world | patch | #90 before the pass | env | expect? |
|---|---|---|---|---|---|
| conflict-dirty | board | dirty-90 | armed ∧ DIRTY, no `merge-conflict` label | — | dirty-label (`action.label.op` = add) |
| conflict-clear | board | label-conflict-90 | carries `merge-conflict`, no longer armed ∧ DIRTY | — | label-clear (`action.label.op` = remove) |
| update-fail | board | conflict-101 (`#101` armed ∧ BEHIND, not DIRTY) | `#90` not exercised | `STUB_GH_api_repos_teststuffstash_testrepo_pulls_101_update_branch=fail` | update-fail (the `update-branch` PUT for `#101` is attempted and 422s, the skip line prints, and no `merge-conflict` label op is issued for `#101`) |

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
again. A Renovate PR that is armed, current (not BEHIND, so outside legs 1 and 2) and
updater-merged is swept by leg 1b (`update-pr-branch.sh` hand-back sweep): a concluded red (or
CHANGES_REQUESTED) is handed back; a pending, absent or green rollup is left silent — pending waits
for the next pass. A worker-pushed Renovate PR (the FU-046 `deps-review` shape) is no longer Renovate's and
rides the ordinary legs. A CANCELLED check that a same-named sibling outlives is not red (#2754);
an unreadable rollup holds. A rollup that reports no check runs is not green
(`renovate_green` requires at least one concluded check, `agents/renovate-currency.sh:54`). The island's predicate functions live in `islands/scan/src/scan_island/renovate.py` (the shell
original, `agents/renovate-currency.sh`, remains for the scan's FU-124 nudge until retired).

#### Whose currency is this Renovate PR?

| description | world | patch | review | commits | checks | env | expect? |
|---|---|---|---|---|---|---|---|
| renovate-untouched-no-update ⚖ | board | add-renovate-approved | `APPROVED`, BEHIND | Renovate only | none reported | — | renovate-skip-probe1 |
| renovate-untouched-green-update | board | add-renovate-approved | `APPROVED`, BEHIND | Renovate only | `ci` success | — | picks-probe1-renovate |
| renovate-untouched-red-no-update | board | add-renovate-approved | `APPROVED`, BEHIND | Renovate only | `ci` failure | — | renovate-skip-probe1 |
| renovate-worker-pushed-update | board | add-renovate-approved | `APPROVED`, BEHIND | Renovate + a worker commit + an updater merge commit | none reported | — | picks-probe1-renovate |
| renovate-updater-merged-red-handback | board | add-renovate-approved | `APPROVED`, BEHIND | Renovate + an updater merge commit | `ci` success, `system-test` failure | — | renovate-handback-probe1 |
| renovate-superseded-cancel-green-update | board | add-renovate-approved | `APPROVED`, BEHIND | Renovate + an updater merge commit | `ci` cancelled, outlived by `ci` success | — | picks-probe1-renovate |
| renovate-checks-unreadable-hold | board | add-renovate-approved | `APPROVED`, BEHIND | Renovate only | unreadable | `STUB_GH_api_repos_teststuffstash_testrepo_commits_ren150oid789_check_runs_per_page_100=fail` | renovate-probe-hold |
| renovate-merged-current-red-handback | board | add-renovate-current-review | `REVIEW_REQUIRED`, no review, PR CURRENT (BLOCKED, not BEHIND) | Renovate + an updater merge commit | `ci` success, `system-test` failure | — | sweep-handback-probe1 |
| renovate-merged-current-pending-noop ⚖ | board | add-renovate-current-review | `REVIEW_REQUIRED`, no review, PR CURRENT (BLOCKED, not BEHIND) | Renovate + an updater merge commit | `ci` success, `system-test` in progress | — | sweep-silent-probe1 |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-UPDATER-RENOVATE.md"

</details>
