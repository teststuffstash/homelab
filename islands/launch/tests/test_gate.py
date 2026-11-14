"""Checks of the gate itself — carry no rule() label."""

from __future__ import annotations

import re

import pytest

from conftest import REPLAY, replay_row, rule

STUB = """\
gw_preflight_caller() { return 0; }
gw_admit() { return 0; }
gw_release() { return 0; }
"""


def _rows() -> list[str]:
    psv = REPLAY / "fixtures" / "gateway-admit" / "rows.psv"
    return [ln.split("|", 1)[0].strip() for ln in psv.read_text(encoding="utf-8").splitlines()
            if ln.strip() and not ln.startswith("#")]


def test_control_stub_target_fails_every_row(tmp_path) -> None:
    """The same family against a do-nothing stub passes only when all 12 rows FAIL."""
    stub = tmp_path / "gateway-admit.sh"
    stub.write_text(STUB, encoding="utf-8")
    rows = _rows()
    assert len(rows) == 12
    passed = [r for r in rows if replay_row(r, stub)[0]]
    assert passed == [], f"rows that still passed against the stub: {passed}"


def test_rule_refuses_an_id_with_no_spec_heading() -> None:
    with pytest.raises(ValueError, match=re.escape("LAUNCH-ADMIT-NOPE")):
        rule("LAUNCH-ADMIT-NOPE")
