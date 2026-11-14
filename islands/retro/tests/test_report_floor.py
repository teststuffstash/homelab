"""RETRO-REPORT-FLOOR (specs/cell.md) — world cell-report-logs. Each case is green exactly when the
fixture `retro-cell-report/<id>` is green against the old member."""

import allure
import pytest
from conftest import case_id, oracle_green, rule

pytestmark = rule("RETRO-REPORT-FLOOR")

FAMILY = "retro-cell-report"


@pytest.mark.parametrize(
    "ride_log, expected_reason, expected_rc",
    [
        pytest.param("one block, a full report", None, 0, id="present"),
        pytest.param("no markers", "no-markers", 1, id="missing"),
        pytest.param("one block, 9 heading-only lines", "under-floor: 0 content lines < 20", 1, id="⚖ skeleton"),
        pytest.param("three empty echoes, then the real block", None, 0, id="multi-block"),
        pytest.param("a long marker-less transcript", "no-markers", 1, id="⚖ longlog"),
    ],
)
def test_report_floor(request, ride_log, expected_reason, expected_rc):
    row = case_id(request.node.callspec.id)
    allure.dynamic.parameter("world", "cell-report-logs")
    assert oracle_green(f"{FAMILY}/{row}", f"{FAMILY}-{row}"), f"replay fixture {FAMILY}/{row} is not green (or missing)"
