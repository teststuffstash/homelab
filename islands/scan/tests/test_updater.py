"""Updater legs 1–2 (pick, unstrand) — the island's `scan_island.updater` against the `updater` replay family."""

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
