"""Gate checks of the admission cases themselves — carry no rule() label."""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from launch.gateway_admit import GatewayAdmit, Request, TransportError
from page import ADMISSION
from test_admit_cases import BOUND_ROWS, BOUND_VIA_GW_ADMIT, CASES, DEFECTS, HELPER_ROWS, LAUNCHER_ROWS
from worlds import WorldError

SRC = Path(__file__).resolve().parent.parent / "src"


def test_every_page_row_has_a_case_and_every_case_a_row() -> None:
    rows = {r.id for r in HELPER_ROWS} | {r.id for r in BOUND_ROWS}
    assert len(HELPER_ROWS) == 9 and len(BOUND_VIA_GW_ADMIT) == 3
    assert rows - set(CASES) == set(LAUNCHER_ROWS)  # the only rows without a case
    assert set(CASES) - rows == set()
    assert set(DEFECTS) == {r.id for r in BOUND_VIA_GW_ADMIT}
    assert all(r["via"] == "launcher" for r in BOUND_ROWS if r.id in LAUNCHER_ROWS)
    assert len(LAUNCHER_ROWS) == 4


def test_page_prose_names_no_shell_mechanism() -> None:
    text = ADMISSION.read_text(encoding="utf-8").split("## The worker launcher")[0]
    for needle in ("trap gw_release", "set -u", "curl -H @<(", "never exits or traps"):
        assert needle not in text


def test_src_names_nothing_under_agents_and_reproduces_no_old_text() -> None:
    for py in SRC.rglob("*.py"):
        text = py.read_text(encoding="utf-8")
        assert not re.search(r"(^|[^\w-])agents/", text, re.M), py
        assert "gateway-admit" not in text, py


def test_admit_never_exits_the_caller_on_a_failing_transport() -> None:
    def boom(_req: Request):
        raise TransportError("down")

    result = GatewayAdmit(boom, lambda: "t").admit(["--stack", "platform", "--role", "worker", "--task", "t",
                                                    "--bind", "a/b/c"])
    assert result.rc == 3 and result.outputs["GW_DEFER_REASON"] == "gateway-unreachable"


def test_strict_world_reader_refuses_an_unknown_world() -> None:
    from worlds import load_world

    with pytest.raises(WorldError):
        load_world("gw-nope")
