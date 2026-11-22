"""Boundary checks for the guard component against the old member. Unlabelled: no spec row names them."""

import json

import pytest
from test_guard_expr import old_verdict

from retro_island.guard_expr import FAIL, FIRE, QUIET, decide


def _vec(*vals):
    return json.dumps({"status": "success", "data": {"resultType": "vector", "result": [{"metric": {}, "value": [1, v]} for v in vals]}})


@pytest.mark.parametrize(
    "body, expected",
    [
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
    ],
)
def test_guard_expr_boundaries_match_old_member(body, expected):
    """Unlabelled boundary checks (no spec row): the component agrees with the old parser."""
    assert decide(body).verdict == expected == old_verdict(body)
