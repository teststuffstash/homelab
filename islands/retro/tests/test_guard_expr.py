"""RETRO-GUARD-EXPR (specs/guard.md) — world guard-bridge. Each case is green exactly when the
`retro-quiet-guard/<id>` row of the replay family is green against the old member."""

import allure
import pytest
from conftest import case_id, oracle_green, rule

pytestmark = rule("RETRO-GUARD-EXPR")

FAMILY = "retro-quiet-guard"


@pytest.mark.parametrize(
    "PROM_VALUE, expected_QUIET, expected_prepare_called, expected_rc",
    [
        pytest.param("1", "false", "--no-ledger", 0, id="expr-fires"),
        pytest.param("0", "true", "no", 0, id="expr-quiet"),
        pytest.param("absent", None, "no", 1, id="⚖ expr-absent"),
        pytest.param("error", None, "no", 1, id="expr-error"),
        pytest.param("down", None, "no", 1, id="expr-prom-down"),
    ],
)
def test_guard_expr(request, PROM_VALUE, expected_QUIET, expected_prepare_called, expected_rc):
    row = case_id(request.node.callspec.id)
    allure.dynamic.parameter("world", "guard-bridge")
    assert oracle_green(FAMILY, f"{FAMILY}/{row}"), f"replay row {FAMILY}/{row} is not green (or missing)"
