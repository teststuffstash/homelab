"""RETRO-GUARD-EXPR (specs/guard.md) — world guard-bridge. Each case is green exactly when the
`retro-quiet-guard/<id>` row of the replay family is green against the old member."""

import json
import subprocess

import allure
import pytest
from conftest import REPO, case_id, oracle_green, rule

from retro_island.guard_expr import FAIL, decide

pytestmark = rule("RETRO-GUARD-EXPR")

FAMILY = "retro-quiet-guard"


def bridge_body(prom_value: str) -> str | None:
    """The body agents/replay/fixtures/retro-quiet-guard/bridge.sh's `curl` shadow builds for PROM_VALUE (None = `down`)."""
    if prom_value == "down":
        return None
    if prom_value == "error":
        return '{"status":"error","errorType":"bad_data","error":"parse error"}'
    if prom_value == "absent":
        return '{"status":"success","data":{"resultType":"vector","result":[]}}'
    return json.dumps({"status": "success", "data": {"resultType": "vector", "result": [{"metric": {}, "value": [1761523200, prom_value]}]}}, separators=(",", ":"))


def old_verdict(body: str) -> int:
    return subprocess.run(["python3", "agents/retro_guard_expr.py"], cwd=REPO, input=body, capture_output=True, text=True, check=False).returncode


@pytest.mark.parametrize(
    "PROM_VALUE, PREP_RC, CURL_RC_1, expected_QUIET, expected_prepare_called, expected_rc",
    [
        pytest.param("1", "0", "—", "false", "--no-ledger", 0, id="expr-fires"),
        pytest.param("0", "—", "0", "true", "no", 0, id="expr-quiet"),
        pytest.param("absent", "—", "—", None, "no", 1, id="⚖ expr-absent"),
        pytest.param("error", "—", "—", None, "no", 1, id="expr-error"),
        pytest.param("down", "—", "—", None, "no", 1, id="expr-prom-down"),
    ],
)
def test_guard_expr(request, PROM_VALUE, PREP_RC, CURL_RC_1, expected_QUIET, expected_prepare_called, expected_rc):
    row = case_id(request.node.callspec.id)
    allure.dynamic.parameter("world", "guard-bridge")
    assert oracle_green(FAMILY, f"{FAMILY}/{row}"), f"replay row {FAMILY}/{row} is not green (or missing)"

    body = bridge_body(PROM_VALUE)
    d = decide(body)
    assert (d.rc, d.quiet, d.prepare_called) == (expected_rc, {"true": True, "false": False, None: None}[expected_QUIET], expected_prepare_called)
    if body is not None:  # `down`: curl fails, the old parser is never called
        assert d.verdict == old_verdict(body)
    else:
        assert d.verdict == FAIL

