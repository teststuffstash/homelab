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

**[`updater.schema.json`](updater.schema.json)** holds the per-PR fields the pass reads, the fields
it requires of each per-PR read, and the actions it can emit.

| Requirement | Governs (schema) | Status |
|---|---|---|
| [SCAN-UPDATER-PICK](#scan-updater-pick) | `pr`, `commit_probe`, `pull_commits_read`, `ci_check_read`, `action.update` | 🚧 WIP → #3490 — rule-labelled tests in islands/scan/tests/test_updater.py over recorded world `pr-board`; no evidence publisher for this root (comparison: `updater`) |
| [SCAN-UPDATER-UNSTRAND](#scan-updater-unstrand) | `commit_review_probe`, `pull_commits_read`, `action.update` | 🚧 WIP → #3490 — rule-labelled tests in islands/scan/tests/test_updater.py over recorded world `pr-board`; no evidence publisher for this root (comparison: `updater`) |
| [SCAN-UPDATER-CONFLICT](#scan-updater-conflict) | `action.label` | 🚧 WIP → #3490 — rule-labelled tests in islands/scan/tests/test_updater.py over recorded world `pr-board`; no evidence publisher for this root (comparison: `updater`) |
| [SCAN-UPDATER-RENOVATE](#scan-updater-renovate) | `commit_probe`, `pull_commits_read`, `check_runs_read`, `status_read`, `action.handback` | 🚧 WIP → #3490 — rule-labelled tests in islands/scan/tests/test_updater.py over recorded world `pr-board`; the `fu124-nudge` half is the scan clause's, not built (comparison: `updater`, `fu124-nudge`) |

**World for every table below:** [`pr-board`](worlds/README.md#recorded-worlds-worldsname--here) —
one repo, `#90` armed ∧ CLEAN, `#91` un-armed ∧ BEHIND, as overrides on the recorded snapshot;
each row's cells add its pull requests. A pull request a row adds starts with no label and no
review, and its cells set the rest. A recorded entry no cell names stays as recorded; none is
BEHIND, armed ∧ DIRTY or labelled `merge-conflict`, so no leg acts on it.

⚖ A `#n` in a cell names an entry of the recorded snapshot: `#90` and `#91` stand for two recorded
entries the pass reads nothing further for, and the pull requests a row adds stand for the recorded
items whose per-PR reads the world holds, in the order the row names them. A printed or written
number is that entry's recorded number. The alternative re-addresses the recorded reads to the
page's numbers, which serves reads the world does not hold.

**Legend — the `expect?` literals.** Each literal names what one pass issues and prints. Every pass
starts with the one `gh pr list` snapshot; "probe" is the per-candidate commit probe: the `gh pr view --json commits` call, then the pull-commits read `gh api repos/<slug>/pulls/<n>/commits?per_page=100` for the same pull request. Leg 2's probe is the `--json commits,reviews` call followed by the same read, so a literal's "1 (`commits,reviews`), unreadable" covers a failure of either call. The ci read is `gh api repos/<slug>/commits/<headRefOid>/check-runs?per_page=100` for one pull request; the base ci read is `gh api repos/<slug>/commits/heads/<baseRefName>/check-runs?per_page=100`. A probe is unreadable when either call is; when the first is, the second is not issued (unverified — expected to hold: no row fails the first call and counts the second). Every literal but `unreadable-snapshot` exits 0. A quoted line is matched within one printed
line: `…` stands for any text, and `#n` for the pull request of the literal's update (the first
update's, then the next).

| literal | probes | updates issued | other observable |
|---|---|---|---|
| `noop` | 0 | none | only the line `no armed+BEHIND PR to update` |
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
| `renovate-handback-probe1` | 1, plus the rollup reads | none | hand-back: the PR body is read, then PATCHed with the rebase box ticked; leg 1's `updater[…]: #n … handed back to Renovate` line ⚖, then `no armed+BEHIND PR to update` |
| `sweep-handback-probe1` | 1, plus the rollup reads | none | the same hand-back (body read, PATCH ticking the box), printed by the sweep as `handback[…]` after `no armed+BEHIND PR to update` |
| `sweep-silent-probe1` | 1, plus the rollup reads | none | no hand-back, no label op, no skip line: only `no armed+BEHIND PR to update` |
| `unstrand-yes` | 1 (`--json commits,reviews`) | one PUT for the CR ∧ BEHIND PR | `unstrand: updating CR-and-behind PR #n (new content since verdict)` |
| `unstrand-no` | 1 (`commits,reviews`) | none | `unstrand: … NO new content since the verdict … not updating` |
| `unstrand-hold` | 1 (`commits,reviews`), unreadable | none | `unstrand: … probe unreadable — HOLDING` |
| `dirty-label` | 0 | none | label op (`action.label.op` = add): the label created with `POST …/labels`, then `POST …/issues/n/labels` on the DIRTY PR |
| `label-clear` | 0 | none | label op (`action.label.op` = remove): `DELETE …/issues/n/labels/merge-conflict` |
| `update-fail` | 1 | one PUT for `#101`, which fails | `update of #101 failed (422) — skipping; next pass retries`; gh's stderr on ERR; no label op |
| `unreadable-snapshot` | 0 | none | no label operation, no hand-back; the line `snapshot unreadable`; the pass exits 4 ⚖ |
| `noop-ci1` | 0, plus the ci read (the candidate) | none | as `noop` |
| `noop-ci2` | 0, plus the ci read of both candidates | none | as `noop` |
| `noop-probe1-ci1` | 1, plus the ci read | none | as `noop` |
| `noop-ci1-base` | 0, plus the ci read and the base ci read | none | as `noop` |
| `noop-ci-hold` | 0, plus the ci read, unreadable | none | `ci check read unreadable — HOLDING`, then `no armed+BEHIND PR to update` |
| `inherited-picks` | 0, plus the ci read and the base ci read | one PUT for the pull request | `#n … inherited red`, then `updating #n (oldest armed+BEHIND, FIFO)` |
| `inherited-picks-probe1` | 1, plus the ci read and the base ci read | one PUT | as `inherited-picks` |
| `inherited-picks-two` | 0, plus the ci read of both candidates and one base ci read | one PUT, for the older PR | as `inherited-picks`, the `inherited red` line once per pull request, each with that pull request's own number (the older's first); the `updating` line's `#n` is the older's |

The two printed lines are `updater[<slug>]: #<n> ci failed before <base>'s head went green — inherited red, admitted without merge-ready` and `updater[<slug>]: #<n> ci check read unreadable — HOLDING, not updating (rule #6; the */15 cron retries)`. An unreadable base ci read prints `updater[<slug>]: #<n> base check read unreadable — HOLDING, not updating (rule #6; the */15 cron retries)` once for each pull request of that base that reaches the read (unverified — expected to hold: no row fails the base ci read).

⚖ An unreadable snapshot exits 4, the island's code for a read that failed before any write
(as [SCAN-HANDOFF-GATE](major-handoff.md#scan-handoff-gate)'s exit 4); a failing `gh pr list` passes gh's own exit status
through. The alternative, any non-zero status, is also what a crash prints. ⚖ Literals with the
same probes and updates differ only by the lines they quote; each one's quoted lines are printed
by no other such literal's pass. That is why `renovate-handback-probe1` quotes leg 1's
`updater[…]` line in full: the sweep's hand-back line ends in the same words.

### SCAN-UPDATER-PICK

Leg 1 updates the oldest PR per lane that is **armed ∧ BEHIND ∧ [merge-ready](glossary.md#merge-ready)**
(`update-pr-branch.sh:142`, homelab#1452): `reviewDecision` APPROVED, or `""` (a ruleset that
requires no approval) with the reviewer bot's APPROVED newer than the newest [non-merge commit](glossary.md#merge-commit), or
the `automerge` label. There is **no green requirement** (except for untouched or updater-merged Renovate PRs, see [merge-ready](glossary.md#merge-ready)) — a base-side CI fix can only reach a PR
through an update (2026-07-10). `REVIEW_REQUIRED` is a park: never merge-ready, never commit-probed
(#1649). The commit half of "approved at head" is the per-candidate commit probe (Legend), whose second read tells which commits are [merge commits](glossary.md#merge-commit); an unreadable probe holds. The lane is walked oldest-first and stops at the first
successful update, so a member whose update 422s every pass cannot hold its lane hostage
(#2203). `UPDATER_MERGE_READY_ONLY=0` restores the pre-#1452 pick (armed ∧ BEHIND), and the inherited-red leg is then not asked.

**Inherited red** (homelab#2588; operator-ruled 2026-10-15: one predicate inside this pick, no new mover). A pull request that is armed ∧ BEHIND, not `CHANGES_REQUESTED`, not authored by Renovate and not merge-ready is still updated when its red is its base's ([inherited red](glossary.md#inherited-red)): the newest `ci` check run at its head is `completed` with conclusion `failure`, the newest `ci` check run at the head of its base branch is `completed` with conclusion `success`, and the first started before the second (`started_at`). `ci` is the check the rulesets require; newest is by `started_at`. ⚖ A `ci` run with no `started_at` has not started: it is newer than every run that has one, and it is not `completed`, so that head is not an inherited red. Two times that are equal are not one before the other: at the two heads that is not an inherited red; the alternative, a refresh on a tie, spends a CI cycle on a run that may already hold the base's fix (unverified — expected to hold: no row has two `ci` runs at one head, a run with no `started_at`, or equal times). The leg is asked where the admission gives such a pull request up — the `REVIEW_REQUIRED` park whatever its reviews, no bot approval, a bot approval older than the newest non-merge commit — and nowhere else: a merge-ready pull request and one whose commit probe holds never reach it. ⚖ A pull request carrying `agent/error` or `agent/arbitrate` is never asked: the leg makes neither of its reads for it. The exclusion is this leg's alone and the admission above is unchanged: a merge-ready pull request carrying either label is still updated, a `REVIEW_REQUIRED` park or one with no bot approval gets no read at all, and one with a stale bot approval is commit-probed by the admission as before and then not asked (unverified — expected to hold: both breakered rows carry `agent/error`; no row carries `agent/arbitrate`, and no row adds a merge-ready pull request with a breaker label). The leg reads the pull request's check runs (the ci read, Legend) and, only when they show that failure, its base's (the base ci read), at most once per base per pass (unverified — expected to hold: no row runs the leg on two bases). A newest `ci` run that is not `completed`, a conclusion other than `failure` at the pull request or other than `success` at the base, or no `ci` check run at either, is not an inherited red (unverified for the pull request's own head — expected to hold: the rows show a base with no `ci` run and a base that is not `success`; none shows a pull request whose newest `ci` run is in flight or absent). An unreadable ci read or base ci read holds that pull request with a line; the base's answer, unreadable or not, is kept for the pass, so every pull request of that base that reaches the base ci read holds on the one read, each with its own line; an answer that lacks a field the schema's `ci_check_read` requires is unreadable. An admitted pull request joins the lane walk as a merge-ready one does: oldest first, one landed update per lane (unverified — expected to hold: no row puts a merge-ready and an admitted pull request in one lane, and none answers 422 to an admitted one's update). After the update its `ci` run starts after its base's, so the leg retires itself; a pull request red for its own reason costs one update and one CI cycle.

⚖ The leg reads check runs, not workflow runs: the merge App holds `checks: read` and no Actions permission (`docs/github-apps.yaml`), and `gh run list` needs the second. ⚖ The base's run is the one at the base's head, not the base's newest successful run: while the head is red or in flight, an update merges that head in. ⚖ The base is the pull request's own base, not always the default branch. A `goal/**` head carries a `ci` check run only while it is the head of an open pull request (`CI` runs on `pull_request`, and on `push` to master only), so on a goal lane the leg seldom acts (unverified — expected to hold: no row runs the leg on a `goal/**` base). ⚖ A Renovate-authored pull request is never asked, a worker-pushed one included: an untouched or updater-merged one's currency is [SCAN-UPDATER-RENOVATE](#scan-updater-renovate)'s, and a worker-pushed one rides the admission above but not this leg. The alternative asks a worker-pushed one as any other pull request; it lost because that requirement's probe already reads the same head's check runs against `check_runs_read`, and one wire read would then answer to two schema parts (unverified — expected to hold: no row adds a Renovate-authored pull request to this table, and no row of SCAN-UPDATER-RENOVATE adds one that is BEHIND and not `APPROVED`). ⚖ A failed `ci` run that was re-run after the base went green starts after it, and the leg does not act (unverified — expected: the read lists a re-run in place of the run it replaces).

> **External:** MUST — [GitHub REST · Checks § List check runs for a Git reference](https://docs.github.com/en/rest/checks/runs#list-check-runs-for-a-git-reference) — `{ref}` takes `heads/<branch>`; each run carries `name`, `status`, `conclusion` and `started_at`; a branch that does not exist answers 422 — read off the wire 2026-11-26 on `teststuffstash/homelab` (`heads/master`: one `ci` run, `success`; `heads/goal/3305-runtime-tiers`: two `approve / approve` runs, `skipped`, no `ci` run; a deleted branch: 422 `No commit found for SHA`).

⚖ A snapshot entry that lacks a field the schema's `pr` requires makes the snapshot unreadable, and
the pass issues no write for any PR. The alternative is to skip that one PR and continue. The whole
pass holds because one list query returns every entry, so a missing field is a changed answer
shape, not one odd PR; holding is also the cheaper side to reverse. ⚖ `pr` requires every field
the pass reads. A required field that is null where the schema allows no null, or of another type,
reads as absent. A review's `author` may be null (a deleted account); it is then no one's verdict.
A review's `submittedAt` may not: a pending review, the only kind without one, is visible only to
its author, never to the pass's identity. ⚖ A commit probe answer that lacks a field the schema's
`commit_probe` requires is unreadable, as a non-JSON body is, and that PR holds. ⚖ A pull-commits answer that lacks a field the schema's `pull_commits_read` requires, or an element for a commit of the first read, is unreadable, and that PR holds (unverified — expected to hold as the failed read does: the updater's rows fail the read, none removes a field or an element; `SCAN-HANDOFF-GATE` has both rows).

**World:** the one above. A pull request a `base` cell names is armed ∧ BEHIND, and the pull
requests were created in the order the cell names them. A commit a cell describes has one parent unless the cell says two. A pull request a row adds has one `ci` check run at its head, `completed` with conclusion `success`, unless the `ci` cell says otherwise. The `ci` cell gives the newest `ci` check run at the pull request's head, then the one at its base's head, each as its conclusion and the time it started, the times on one day; `—` leaves the head as this line sets it, and the base's is then not read. A pull request a `base` cell names is not Renovate-authored. A label a `review` cell names is on that pull request.

#### Which PR does the main leg update?

| description | world | base | review | ci | fault | env | expect? |
|---|---|---|---|---|---|---|---|
| armed-only-noop | pr-board | — | — (no armed ∧ BEHIND PR: `#90` is CLEAN, `#91` un-armed) | — | — | — | noop |
| fifo-pick | pr-board | `#101`, `#102` → master | `reviewDecision ""`, the bot's `reviews[]` APPROVED post-dates the newest non-merge commit (both PRs) | — | — | — | picks-probe2 (`#101`, the older) |
| lane-hop-wedged-oldest | pr-board | `#101`, `#102` → master | `reviewDecision ""`, the bot's `reviews[]` APPROVED post-dates the newest non-merge commit (both PRs) | — | the `update-branch` PUT for `#101` answers 422 | — | lane-hop (`#102` updated in the same pass) |
| two-lanes-two-updates | pr-board | `#101` → master, `#110` → goal/x | `reviewDecision ""`, the bot's `reviews[]` APPROVED post-dates the newest non-merge commit (both PRs) | — | — | — | picks-two-probe2 (one per base) |
| same-lane-one-update | pr-board | `#110`, `#111` → goal/x | `reviewDecision ""`, the bot's `reviews[]` APPROVED post-dates the newest non-merge commit (both PRs) | — | — | — | picks-probe2 (one) |
| unreviewed-behind-no-update | pr-board | `#101`, `#102` → master | `reviewDecision ""`, no review, no `automerge` label | — | — | — | noop-ci2 |
| bot-approved-head-update | pr-board | `#141` → master | `reviewDecision ""`, the bot's `reviews[]` APPROVED post-dates the newest non-merge commit | — | — | — | picks-probe1 |
| stale-approval-no-update | pr-board | `#142` → master | `reviewDecision ""`, the bot's APPROVED is older than a later content commit (stale) | — | — | — | noop-probe1-ci1 |
| probe-unreadable | pr-board | `#141` → master | `reviewDecision ""`, the bot's `reviews[]` APPROVED post-dates the newest non-merge commit | — | the commit probe for `#141` answers a non-JSON body | — | noop-probe-hold |
| parents-unreadable | pr-board | `#141` → master | `reviewDecision ""`, the bot's `reviews[]` APPROVED post-dates the newest non-merge commit | — | the pull-commits read for `#141` fails | — | noop-probe-hold |
| hand-titled-merge-after-approval-update | pr-board | `#141` → master | `reviewDecision ""`, the bot's `reviews[]` APPROVED post-dates the newest content commit; a later commit has two parents and the headline `Merge master into <head>` | — | — | — | picks-probe1 |
| merge-titled-content-after-approval-no-update ⚖ | pr-board | `#142` → master | `reviewDecision ""`, the bot's APPROVED is older than a later commit with one parent and the headline `Merge branch 'master' into <head>` (content: stale) | — | — | — | noop-probe1-ci1 |
| parked-approved-head-no-update | pr-board | `#150` → master | `REVIEW_REQUIRED` (park); `latestReviews` bot COMMENTED, `reviews[]` bot APPROVED at head | — | — | — | noop-ci1 |
| park-skip | pr-board | `#130` → master | `REVIEW_REQUIRED` (park); `latestReviews` bot APPROVED | — | — | — | noop-ci1 |
| merge-ready-only-off-legacy-pick | pr-board | `#101`, `#102` → master | `reviewDecision ""`, no review, no `automerge` label (not merge-ready) | — | — | `UPDATER_MERGE_READY_ONLY=0` | picks |
| snapshot-lacks-field ⚖ | pr-board | `#141` → master | `reviewDecision ""`, the bot's `reviews[]` APPROVED post-dates the newest non-merge commit | — | the snapshot's entry for `#141` has no `baseRefName` field | — | unreadable-snapshot |
| inherited-red-unreviewed-update | pr-board | `#101` → master | `reviewDecision ""`, no review, no `automerge` label | PR `failure` 10:00; base `success` 11:00 | — | — | inherited-picks |
| inherited-red-parked-update ⚖ | pr-board | `#130` → master | `REVIEW_REQUIRED` (park); `latestReviews` bot APPROVED | PR `failure` 10:00; base `success` 11:00 | — | — | inherited-picks |
| inherited-red-stale-approval-update | pr-board | `#142` → master | `reviewDecision ""`, the bot's APPROVED is older than a later content commit (stale) | PR `failure` 10:00; base `success` 11:00 | — | — | inherited-picks-probe1 |
| inherited-red-base-red-no-update | pr-board | `#101` → master | `reviewDecision ""`, no review, no `automerge` label | PR `failure` 10:00; base `failure` 11:00 | — | — | noop-ci1-base |
| inherited-red-fresh-no-update | pr-board | `#101` → master | `reviewDecision ""`, no review, no `automerge` label | PR `failure` 12:00; base `success` 11:00 | — | — | noop-ci1-base |
| inherited-red-base-no-ci-run-no-update ⚖ | pr-board | `#101` → master | `reviewDecision ""`, no review, no `automerge` label | PR `failure` 10:00; base: no `ci` run (one `approve / approve` run, `skipped`, 11:00) | — | — | noop-ci1-base |
| inherited-red-breakered-no-update ⚖ | pr-board | `#101` → master | `reviewDecision ""`, no review, no `automerge` label; the PR carries `agent/error` | PR `failure` 10:00; base `success` 11:00 | — | — | noop |
| inherited-red-breakered-stale-approval-no-update ⚖ | pr-board | `#142` → master | `reviewDecision ""`, the bot's APPROVED is older than a later content commit (stale); the PR carries `agent/error` | PR `failure` 10:00; base `success` 11:00 | — | — | noop-probe1 |
| inherited-red-ci-unreadable-hold ⚖ | pr-board | `#101` → master | `reviewDecision ""`, no review, no `automerge` label | — | the check-runs read for `#101`'s head answers an error | — | noop-ci-hold |
| inherited-red-two-one-base-read | pr-board | `#101`, `#102` → master | `reviewDecision ""`, no review, no `automerge` label | PR `failure` 10:00 (both PRs); base `success` 11:00 | — | — | inherited-picks-two (`#101`, the older) |

⚖ `merge-titled-content-after-approval-no-update`: the alternative is the title test, as for the handoff's row.

⚖ `inherited-red-parked-update`: the alternative leaves a park whose newest bot review is APPROVED unread, as the commit probe does; it lost because that pull request was green when it was approved and is the one a codeowner is about to merge. ⚖ `inherited-red-base-no-ci-run-no-update`: the alternative reads every check run of the base's head as its rollup; it lost because a goal head read that way is green on two skipped `approve / approve` runs (the External line). ⚖ `inherited-red-ci-unreadable-hold`: the alternative is a silent no; the page's rule for this leg is that an unreadable read holds with a line. ⚖ `inherited-red-breakered-no-update` and `inherited-red-breakered-stale-approval-no-update`: the alternative refreshes a breakered pull request like any other, its red being its base's and not its own; it lost because a breaker label hands the pull request to a human, and an update starts a CI cycle and new loop work on it — the exclusion #2588 lists as filed ("`agent/error` / `agent/arbitrate` excluded") and the one [SCAN-UPDATER-UNSTRAND](#scan-updater-unstrand) already makes ("breaker labels exclude it"). The second row is the first with a stale approval: the admission's commit probe is issued, the leg's reads are not.

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-UPDATER-PICK.md"

</details>

### SCAN-UPDATER-UNSTRAND

Leg 2 closes the CHANGES_REQUESTED ∧ BEHIND crack: an armed PR in that state is updated only when
its newest [non-merge commit](glossary.md#merge-commit) post-dates the newest reviewer-bot verdict — the fix round has
landed and needs currency to be reviewed again; breaker labels exclude it; unreadable commit or
review data holds (`update-pr-branch.sh:362`, rule #6). ⚖ A commit-and-review probe answer that
lacks a field the schema's `commit_review_probe` requires is unreadable, and that PR holds.

**World:** the one above, plus `#120` → master, armed ∧ BEHIND, `reviewDecision`
CHANGES_REQUESTED, not Renovate-authored. The `probe` cell is its commit-and-review probe, its
times on one day. A commit the cell describes has one parent unless the cell says two; the probe is the commit-and-review call followed by the pull-commits read.

#### Is a changes-requested, behind PR brought current?

| description | world | probe | expect? |
|---|---|---|---|
| unstrand-yes | pr-board | newest non-merge commit 12:00 after the bot's CHANGES_REQUESTED 11:00 | unstrand-yes |
| unstrand-no | pr-board | newest non-merge commit 10:00 before the bot's CHANGES_REQUESTED 11:00; the 12:00 commit has two parents and the headline `Merge branch 'master' into <head>` (a merge commit, not content) | unstrand-no |
| unstrand-no-hand-titled-merge | pr-board | a content commit 10:00 before the bot's CHANGES_REQUESTED 11:00; the 12:00 commit has two parents and the headline `Merge master into <head>` | unstrand-no |
| unstrand-yes-merge-titled-content ⚖ | pr-board | a content commit 10:00 before the bot's CHANGES_REQUESTED 11:00; the 12:00 commit has one parent and the headline `Merge branch 'master' into <head>` | unstrand-yes |
| unstrand-unreadable | pr-board | unreadable (non-JSON body) | unstrand-hold |
| unstrand-parents-unreadable | pr-board | commits and reviews readable; the pull-commits read fails | unstrand-hold |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-UPDATER-UNSTRAND.md"

</details>

### SCAN-UPDATER-CONFLICT

Leg 3 labels every armed ∧ DIRTY PR `merge-conflict` (creating the label idempotently first) and
removes the label once the PR is no longer armed-and-DIRTY (`update-pr-branch.sh:412`). The
updater never resolves a conflict: the label is what the scan's `merge-conflict` clause reads
([SCAN-CLAUSE-PR](scan-decision.md#scan-clause-pr)). A failed `update-branch` (a 422 — race or
conflict, deliberately not told apart, homelab#1007) is a skip; the next pass re-lists.

**World:** the one above; the `#90 before the pass` and `#101` cells change it.

#### Does an armed, conflicted PR carry the label — and only while it is?

| description | world | #90 before the pass | #101 | fault | expect? |
|---|---|---|---|---|---|
| conflict-dirty | pr-board | armed ∧ DIRTY, no `merge-conflict` label | — | — | dirty-label (`action.label.op` = add) |
| conflict-clear | pr-board | carries `merge-conflict`, no longer armed ∧ DIRTY | — | — | label-clear (`action.label.op` = remove) |
| update-fail | pr-board | `#90` not exercised | armed ∧ BEHIND, not DIRTY, `reviewDecision ""`, the bot's APPROVED post-dates its newest non-merge commit | the `update-branch` PUT for `#101` answers 422 | update-fail (the `update-branch` PUT for `#101` is attempted and 422s, the skip line prints, and no `merge-conflict` label op is issued for `#101`) |

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
rides the ordinary legs, except the inherited-red leg of [SCAN-UPDATER-PICK](#scan-updater-pick), which asks no Renovate-authored pull request. A Renovate-authored PR with any non-merge commit by a login other than
Renovate's is worker-pushed even when it also carries updater merge commits: it is neither
untouched nor updater-merged, so it has no green requirement and is never handed back. Leg 1 and
the sweep read a Renovate-authored PR's commits and its rollup (check-runs, status) in one probe,
before its class is known; for a worker-pushed PR the rollup is read but not required green. A CANCELLED check that a same-named sibling outlives is not red (#2754);
an unreadable rollup holds. The probe's order is the view call, the pull-commits read, then the rollup reads (check-runs, status). When the view call or the pull-commits read is unreadable the rollup reads are not issued, and the pass prints what any unreadable commit probe prints (`noop-probe-hold`). A rollup that reports no check runs is not green
(`renovate_green` requires at least one concluded check, `agents/renovate-currency.sh:54`). The island's predicate functions live in `islands/scan/src/scan_island/renovate.py` (the shell
original, `agents/renovate-currency.sh`, remains for the scan's FU-124 nudge until retired).
⚖ The check-runs and status reads are taken raw and read against the schema's `check_runs_read`
and `status_read`; an answer that lacks a field is unreadable and holds. The old member projects
both through `--jq` with defaults, so an absent `check_runs` reads there as none reported.

**World:** the one above, plus `#150` → master, armed, authored by Renovate (the list prints
`app/homelab-renovate-1234`; a Renovate commit's author is `homelab-renovate-1234[bot]`), its body
carrying Renovate's unticked rebase checkbox `- [ ] <!-- rebase-check -->`. A worker commit and
an updater merge commit (two parents; headline `Merge branch 'master' into <head>`) are authored by a login other than
Renovate's. Any other commit a cell describes has one parent unless the cell says two. The `checks` cell is the whole rollup, each check a check run; the status read reports
none.

#### Whose currency is this Renovate PR?

| description | world | review | commits | checks | fault | expect? |
|---|---|---|---|---|---|---|
| renovate-untouched-no-update ⚖ | pr-board | `APPROVED`, BEHIND | Renovate only | none reported | — | renovate-skip-probe1 |
| renovate-untouched-green-update | pr-board | `APPROVED`, BEHIND | Renovate only | `ci` success | — | picks-probe1-renovate |
| renovate-untouched-red-no-update | pr-board | `APPROVED`, BEHIND | Renovate only | `ci` failure | — | renovate-skip-probe1 |
| renovate-worker-pushed-update | pr-board | `APPROVED`, BEHIND | Renovate + a worker commit + an updater merge commit | none reported | — | picks-probe1-renovate |
| renovate-updater-merged-red-handback | pr-board | `APPROVED`, BEHIND | Renovate + an updater merge commit | `ci` success, `system-test` failure | — | renovate-handback-probe1 |
| renovate-superseded-cancel-green-update | pr-board | `APPROVED`, BEHIND | Renovate + an updater merge commit | `ci` cancelled, outlived by `ci` success | — | picks-probe1-renovate |
| renovate-hand-titled-merge-red-handback | pr-board | `APPROVED`, BEHIND | Renovate + a two-parent commit by another login, headline `Merge master into <head>` | `ci` success, `system-test` failure | — | renovate-handback-probe1 |
| renovate-merge-titled-worker-commit-update ⚖ | pr-board | `APPROVED`, BEHIND | Renovate + a one-parent commit by another login, headline `Merge branch 'master' into <head>` | `ci` failure | — | picks-probe1-renovate |
| renovate-parents-unreadable-hold | pr-board | `APPROVED`, BEHIND | Renovate only | not read | the pull-commits read for the PR fails | noop-probe-hold |
| renovate-checks-unreadable-hold | pr-board | `APPROVED`, BEHIND | Renovate only | unreadable | the check-runs read for the PR's head answers an error | renovate-probe-hold |
| renovate-merged-current-red-handback | pr-board | `REVIEW_REQUIRED`, no review, PR CURRENT (BLOCKED, not BEHIND) | Renovate + an updater merge commit | `ci` success, `system-test` failure | — | sweep-handback-probe1 |
| renovate-merged-current-pending-noop ⚖ | pr-board | `REVIEW_REQUIRED`, no review, PR CURRENT (BLOCKED, not BEHIND) | Renovate + an updater merge commit | `ci` success, `system-test` in progress | — | sweep-silent-probe1 |

The first new row is the page's `renovate-updater-merged-red-handback` with the merge titled by hand: a two-parent commit is a merge commit, so the PR is untouched and updater-merged, and its red is handed back. ⚖ `renovate-merge-titled-worker-commit-update`: a one-parent commit by another login is content, so the PR is worker-pushed and has no green requirement; the alternative, the title test, hands it back.

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-UPDATER-RENOVATE.md"

</details>
