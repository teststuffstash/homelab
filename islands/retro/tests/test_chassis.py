"""The chassis's own guarantees: rule() fails loudly, and a case with no oracle row fails."""

import pytest
from conftest import oracle_green, rule


def test_rule_rejects_unknown_id():
    with pytest.raises(ValueError, match="RETRO-NO-SUCH-RULE"):
        rule("RETRO-NO-SUCH-RULE")


def test_rule_accepts_spec_headings():
    assert rule("RETRO-GUARD-EXPR") and rule("RETRO-REPORT-FLOOR")


def test_missing_oracle_row_is_red():
    assert not oracle_green("retro-quiet-guard", "retro-quiet-guard/no-such-row")
