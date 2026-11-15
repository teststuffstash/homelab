"""Updater legs 1–3 (pick, unstrand, conflict) and Renovate currency — the island's `scan_island.updater` against the `updater` replay family."""

import sys

import allure
import pytest

from .old_subjects import UPDATER_DIR
from .replay import load_family, load_rows, row_verdict
from .rules import rule

FAMILY = load_family(UPDATER_DIR)
ROWS = {row.id: row for row in load_rows(FAMILY)}
ARGV = [sys.executable, "-m", "scan_island.updater", "teststuffstash/testrepo"]  # updater/bridge.sh:3

PICK = [
    "armed-only-noop",
    "fifo-pick",
    "lane-hop-wedged-oldest",
    "two-lanes-two-updates",
    "same-lane-one-update",
    "unreviewed-behind-no-update",
    "bot-approved-head-update",
    "stale-approval-no-update",
    "probe-unreadable",
    "parked-approved-head-no-update",
    "park-skip",
    "merge-ready-only-off-legacy-pick",
]
UNSTRAND = [
    ("unstrand-yes", "newest non-merge commit 12:00 after the bot's CHANGES_REQUESTED 11:00"),
    ("unstrand-no", "newest non-merge commit 10:00 before the bot's CHANGES_REQUESTED 11:00 (the 12:00 merge commit is not content)"),
    ("unstrand-unreadable", "unreadable (non-JSON body)"),
]


def check(row):
    with allure.step(f"Given replay world {row.world}, patch {row.patch or '—'} and row {row.id}"):
        pass
    with allure.step("When the island updater runs, its action stream matches the recorded verdict"):
        result = row_verdict(FAMILY, row, ARGV)
        assert result is None, result


@rule("SCAN-UPDATER-PICK")
@pytest.mark.parametrize("row", [pytest.param(ROWS[i], id=i) for i in PICK])
def test_pick(row):
    check(row)


@rule("SCAN-UPDATER-UNSTRAND")
@pytest.mark.parametrize("row, probe", [pytest.param(ROWS[i], probe, id=i) for i, probe in UNSTRAND])
def test_unstrand(row, probe):
    with allure.step(f"Given the commit/review probe answers: {probe}"):
        pass
    check(row)


CONFLICT = [
    ("conflict-dirty", "armed ∧ DIRTY #90 gains the label (created first, over REST)"),
    ("conflict-clear", "#90 carries the label but is no longer armed ∧ DIRTY: the label is removed"),
    ("update-fail", "#101's update-branch PUT fails: the skip line prints and gh's stderr passes through"),
]
RENOVATE = [  # id, review, commits, checks (the table's three input columns, read from the patch and rows/<id>/gh/)
    ("renovate-untouched-no-update", "`APPROVED`, BEHIND", "Renovate only", "none reported"),
    ("renovate-untouched-green-update", "`APPROVED`, BEHIND", "Renovate only", "`ci` success"),
    ("renovate-untouched-red-no-update", "`APPROVED`, BEHIND", "Renovate only", "`ci` failure"),
    ("renovate-worker-pushed-update", "`APPROVED`, BEHIND", "Renovate + a worker commit + an updater merge commit", "none reported"),
    ("renovate-updater-merged-red-handback", "`APPROVED`, BEHIND", "Renovate + an updater merge commit", "`ci` success, `system-test` failure"),
    ("renovate-superseded-cancel-green-update", "`APPROVED`, BEHIND", "Renovate + an updater merge commit", "`ci` cancelled, outlived by `ci` success"),
    ("renovate-checks-unreadable-hold", "`APPROVED`, BEHIND", "Renovate only", "unreadable"),
    ("renovate-merged-current-red-handback", "`REVIEW_REQUIRED`, no review, PR CURRENT (BLOCKED, not BEHIND)", "Renovate + an updater merge commit", "`ci` success, `system-test` failure"),
    ("renovate-merged-current-pending-noop", "`REVIEW_REQUIRED`, no review, PR CURRENT (BLOCKED, not BEHIND)", "Renovate + an updater merge commit", "`ci` success, `system-test` in progress"),
]
LISTED = {*PICK, *(i for i, _ in UNSTRAND), *(i for i, _ in CONFLICT), *(i for i, *_ in RENOVATE)}


@rule("SCAN-UPDATER-CONFLICT")
@pytest.mark.parametrize("row, effect", [pytest.param(ROWS[i], effect, id=i) for i, effect in CONFLICT])
def test_conflict(row, effect):
    with allure.step(f"Given: {effect}"):
        pass
    check(row)


@rule("SCAN-UPDATER-RENOVATE")
@pytest.mark.parametrize("row, review, commits, checks", [pytest.param(ROWS[i], review, commits, checks, id=i) for i, review, commits, checks in RENOVATE])
def test_renovate(row, review, commits, checks):
    with allure.step(f"Given the PR is: {review}; the branch carries: {commits}; the check rollup is: {checks}"):
        pass
    check(row)


# Family completeness (Goal pin 5): rows no listed requirement of this Goal owns still run, unlabelled.
@pytest.mark.parametrize("row", [pytest.param(r, id=i) for i, r in ROWS.items() if i not in LISTED])
def test_family_completeness(row):
    check(row)
