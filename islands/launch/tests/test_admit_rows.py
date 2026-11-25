"""The 12 rows of `agents/replay/fixtures/gateway-admit/rows.psv`, one UNLABELLED case per row.

Case id = the row id verbatim. Target of every case
here: the island's helper `islands/launch/lib/gateway-admit.sh` (#3393).
"""

from __future__ import annotations

import allure
import pytest

from conftest import ISLAND, REPLAY, replay_row

TARGET = "islands/launch/lib/gateway-admit.sh"

HELPER = ["bound-dispatch", "unbound-dispatch", "defer", "http-503", "no-mode", "both-modes",
          "bad-bind", "bad-round", "missing-role"]
BOUND = ["harness-not-run", "unbound-answer-bound", "unbound-env-newline"]

# The fixture's own table is the row list; a row added or dropped there must be (un)labelled here.
_psv = REPLAY / "fixtures" / "gateway-admit" / "rows.psv"
_ids = [ln.split("|", 1)[0].strip() for ln in _psv.read_text(encoding="utf-8").splitlines()
        if ln.strip() and not ln.startswith("#")]
if sorted(_ids) != sorted(HELPER + BOUND):
    raise RuntimeError(f"rows.psv rows {sorted(_ids)} != the labelled set {sorted(HELPER + BOUND)}")

# Unlabelled since homelab#3484: the labelled cases are sourced from the page (test_admit_cases.py);
# these keep running as the comparison's precursor until #3485.
CASES = [pytest.param(r, id=r) for r in HELPER + BOUND]


@pytest.mark.parametrize("row_id", CASES)
def test_replay_row(row_id: str) -> None:
    allure.dynamic.title(row_id)
    allure.dynamic.parameter("target", TARGET)
    ok, out = replay_row(row_id, ISLAND / "lib" / "gateway-admit.sh")
    allure.attach(out, name="run.sh output", attachment_type=allure.attachment_type.TEXT)
    assert ok, out
