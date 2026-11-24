"""Boundary checks for the guard component against the old member. Unlabelled: no spec row names them."""

import json

import pytest
from old_member import old_verdict
from rulings import check, check_known
from test_guard_expr_comparison import ROWS

from retro_island.guard_expr import FAIL, FIRE, QUIET, decide


def _vec(*vals):
    return json.dumps({"status": "success", "data": {"resultType": "vector", "result": [{"metric": {}, "value": [1, v]} for v in vals]}})


BOUNDARIES = [
    (_vec("-1"), QUIET),
    (_vec("0", "2"), FIRE),
    (_vec("NaN"), FAIL),
    (_vec("0", "NaN"), FAIL),
    (_vec("x"), FAIL),
    ("not json", FAIL),
    ("[]", FAIL),
    (json.dumps({"status": "success", "data": {"resultType": "scalar", "result": [1, "3"]}}), FIRE),
    (json.dumps({"status": "success", "data": {"resultType": "scalar", "result": [1, "0"]}}), QUIET),
    (json.dumps({"status": "success", "data": {"resultType": "matrix", "result": [{"metric": {}, "values": [[1, "1"]]}]}}), FAIL),
]


@pytest.mark.parametrize("body, expected", BOUNDARIES)
def test_guard_expr_boundaries_match_old_member(body, expected):
    """Unlabelled boundary checks (no spec row): the component's verdict, then old vs new through rulings.json."""
    new = decide(body).verdict
    assert new == expected
    check("RETRO-GUARD-EXPR", body, str(old_verdict(body)), str(new))


def test_boundary_rulings_name_known_inputs():
    check_known("RETRO-GUARD-EXPR", {b for b, _ in BOUNDARIES} | {f"{r} (family row)" for r in ROWS} | set(ROWS))
