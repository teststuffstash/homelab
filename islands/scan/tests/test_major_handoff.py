"""The major handoff contract, exercised through the recorded replay worlds."""

import sys

import allure
import pytest

from .old_subjects import MAJOR_HANDOFF_DIR
from .replay import load_family, load_rows, row_verdict, subject_argv_from_env
from .rules import rule

FAMILY = load_family(MAJOR_HANDOFF_DIR)
ROWS = load_rows(FAMILY)
ARM = {"packaging-only-arms", "app-moves-parks"}


def cases(ids):
    return [pytest.param(row, id=row.id) for row in ROWS if row.id in ids]


def check(row):
    with allure.step(f"Given replay world {row.world} and row {row.id}"):
        argv = subject_argv_from_env(FAMILY, row, "IN_SLUG", "IN_PR")
    with allure.step("When the island gate runs, its action stream matches the recorded verdict"):
        result = row_verdict(FAMILY, row, [sys.executable, "-m", "scan_island.major_handoff", *argv])
        assert result is None, result


@rule("SCAN-HANDOFF-GATE")
@pytest.mark.parametrize("row", cases({r.id for r in ROWS} - ARM - {"handoff-graphql-drained"}))
def test_gate(row):
    check(row)


@rule("SCAN-HANDOFF-ARM")
@pytest.mark.parametrize("row", cases(ARM))
def test_arm(row):
    check(row)


@pytest.mark.parametrize("row", cases({"handoff-graphql-drained"}))
def test_family_completeness(row):
    check(row)
