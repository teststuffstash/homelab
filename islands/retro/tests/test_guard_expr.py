"""RETRO-GUARD-EXPR (specs/guard.md) — world prom-instant. One case per row of the page's table: the
Prometheus answer is the recorded entry named by `PROM_VALUE`, read by the strict reader; `down` is the
entry with no body, which the component gets as a transport failure."""

import allure
import pytest
from conftest import rule

from retro_island import worlds
from retro_island.guard_expr import decide

pytestmark = rule("RETRO-GUARD-EXPR")

QUIET_CELL = {"true": True, "false": False, "—": None}


@pytest.mark.parametrize(
    "PROM_VALUE, PREP_RC, CURL_RC_1, expected_QUIET, expected_prepare_called, expected_rc",
    [
        pytest.param("1", "0", "—", "false", "--no-ledger", 0, id="expr-fires"),
        pytest.param("0", "—", "0", "true", "no", 0, id="expr-quiet"),
        pytest.param("absent", "—", "—", "—", "no", 1, id="⚖ expr-absent"),
        pytest.param("error", "—", "—", "—", "no", 1, id="expr-error"),
        pytest.param("down", "—", "—", "—", "no", 1, id="expr-prom-down"),
    ],
)
def test_guard_expr(PROM_VALUE, PREP_RC, CURL_RC_1, expected_QUIET, expected_prepare_called, expected_rc):
    allure.dynamic.parameter("world", "prom-instant")
    entry = worlds.load("prom-instant", PROM_VALUE)
    d = decide(entry.body)  # body None (the declared `down` entry) = transport failure
    assert (d.rc, d.quiet, d.prepare_called) == (expected_rc, QUIET_CELL[expected_QUIET], expected_prepare_called)
