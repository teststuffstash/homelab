"""The 9 labelled LAUNCH-ADMIT-LAUNCHER cases that refuse before any request (homelab#3486).

One case per row of "Admission through the launcher" that sends no request; id = the row's
description cell; `world` and `rc?` are read from the page at collection. The `knobs` cell is
prose — the case carrying the row's id sets up what it says. Each case asserts the exit code and
that nothing reached the injected gateway transport.
"""

from __future__ import annotations

import allure
import pytest

from conftest import rule
from launch.gateway_admit import CallerTokenError
from launch.launcher_admission import LauncherAdmission, Refusal
from page import Row, table_under
from worlds import load_stack_world

ROWS = table_under("Admission through the launcher")
# Rows the island does not build (Goal #3480 pin 6): the old path.
NEVER_BUILT = ["off", "other-stack"]
# The 13 rows that send a request: #3408's — an explicit list that it empties.
OWNED_BY_3408 = [
    "caller-minted", "dispatch-opencode", "dispatch-claude-explicit", "dispatch-claude-subscription",
    "dispatch-goose", "dispatch-codex", "dispatch-attempt-2", "dispatch-canary",
    "defer", "http-503", "unreachable", "fallback-unreachable", "fallback-defer",
]

OK_TOKEN = "placeholder-caller-token"


class Gateway:
    def __init__(self):
        self.requests = []

    def __call__(self, req):
        self.requests.append(req)
        raise AssertionError("a refusal must not reach the gateway")


def _mint_fails(_sa: str) -> str:
    raise CallerTokenError("TokenRequest refused")


# case id → (knobs, admit kwargs, token file present?, mint)
SETUP = {
    "model-refused": ({}, {"model": "opencode-go/deepseek-v4-flash", "run": "r"}, True, None),
    "round-refused": ({}, {"round": "r2", "run": "r"}, True, None),
    "attempt-refused": ({"AGENT_GATEWAY_ATTEMPT": "0"}, {"run": "r"}, True, None),
    "interactive-refused": ({}, {}, True, None),
    "no-caller-token": ({}, {"run": "r"}, False, None),
    "caller-sa-malformed": ({"AGENT_GATEWAY_CALLER_SA": "agentstack-loop"}, {"run": "r"}, True, None),
    "caller-mint-fails": ({"AGENT_GATEWAY_CALLER_SA": "platform-agents/agentstack-loop"}, {"run": "r"}, False,
                          _mint_fails),
    "fallback-no-caller-token": ({"AGENT_GATEWAY_FALLBACK_EXIT": "75"}, {"run": "r"}, False, None),
    "fallback-model-refused": ({"AGENT_GATEWAY_FALLBACK_EXIT": "75"},
                               {"model": "opencode-go/deepseek-v4-flash", "run": "r"}, True, None),
}
CASES = {r.id: r for r in ROWS if r.id in SETUP}


def _run(row: Row):
    knobs, kwargs, has_token, mint = SETUP[row.id]
    stack = load_stack_world(row["world"]).get("row")
    gw = Gateway()
    adm = LauncherAdmission(
        gw,
        lambda _path: OK_TOKEN if has_token else None,
        mint or (lambda _sa: OK_TOKEN),
    )
    with allure.step(f"given world {row['world']}, knobs {knobs}, args {kwargs}"):
        result = adm.admit(knobs, stack, "platform-repo", "issue-1", **kwargs)
    return result, gw


@pytest.mark.parametrize("case_id", [pytest.param(i, marks=rule("LAUNCH-ADMIT-LAUNCHER"), id=i) for i in CASES])
def test_launcher_refusal(case_id: str) -> None:
    row = CASES[case_id]
    allure.dynamic.title(case_id)
    allure.dynamic.parameter("world", row["world"])
    result, gw = _run(row)
    with allure.step(f"then exit {row['rc?']}"):
        assert isinstance(result, Refusal)
        assert result.rc == int(row["rc?"])
    with allure.step("then no request reached the gateway"):
        assert gw.requests == []
    if case_id == "model-refused":
        assert result.stderr.startswith("PREFLIGHT REFUSED: --model opencode-go/deepseek-v4-flash under AGENT_GATEWAY=sessions")
    else:
        assert result.stderr.startswith("PREFLIGHT REFUSED: ") and "\n" not in result.stderr
