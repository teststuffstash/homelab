"""RETRO-GUARD-EXPR comparison (unlabelled): for each row of the page, the old member (the replay
family row; the old parser on the recorded body) and the new component on the same input. A
difference needs a rulings.json entry."""

import pytest
from old_member import old_family_row, old_verdict
from rulings import check

from retro_island import worlds
from retro_island.guard_expr import FAIL, decide

REQ = "RETRO-GUARD-EXPR"
ROWS = ["expr-fires", "expr-quiet", "expr-absent", "expr-error", "expr-prom-down"]
ENTRY = {"expr-fires": "1", "expr-quiet": "0", "expr-absent": "absent", "expr-error": "error", "expr-prom-down": "down"}


@pytest.mark.parametrize("row", ROWS)
def test_family_row_green(row):
    check(REQ, f"{row} (family row)", old_family_row(row), "green")


@pytest.mark.parametrize("row", ROWS)
def test_parser_verdict(row):
    body = worlds.load("prom-instant", ENTRY[row]).body
    if body is None:  # `down`: curl fails, the old parser is never called
        old = new = FAIL
    else:
        old, new = old_verdict(body), decide(body).verdict
    check(REQ, row, str(old), str(new))

