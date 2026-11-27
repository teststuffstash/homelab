"""Checks of the gate itself — carry no rule() label."""

from __future__ import annotations

import re

import pytest

from conftest import rule


def test_rule_refuses_an_id_with_no_spec_heading() -> None:
    with pytest.raises(ValueError, match=re.escape("LAUNCH-ADMIT-NOPE")):
        rule("LAUNCH-ADMIT-NOPE")
