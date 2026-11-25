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


def _unbound_gateway(**changes):
    import copy

    from test_admit_cases import Gateway
    from worlds import load_world

    world = load_world("gw-dispatch-unbound")
    body = copy.deepcopy(world.get("body"))
    for path, value in changes.items():
        node = body
        *parents, last = path.split(".")
        for key in parents:
            node = node[key]
        node[last] = value
    return Gateway(world, body), body


def test_trailing_newline_is_refused_in_env_key_and_session_id(tmp_path) -> None:
    gw, body = _unbound_gateway()
    body["env"]["FOO\n"] = "x"
    result = GatewayAdmit(gw, lambda: "t").admit(
        ["--stack", "platform", "--role", "responder", "--task", "t", "--env-file", str(tmp_path / "env")])
    assert result.rc == 3 and not (tmp_path / "env").exists()
    assert len(gw.deletes()) == 1

    gw, body = _unbound_gateway()
    body["session"]["id"] = "s-1\n"
    result = GatewayAdmit(gw, lambda: "t").admit(
        ["--stack", "platform", "--role", "responder", "--task", "t", "--env-file", str(tmp_path / "env2")])
    assert result.rc == 3 and "GW_SESSION_ID" not in result.outputs


def test_unknown_harnesses_entry_is_refused_before_any_request(tmp_path) -> None:
    gw, _ = _unbound_gateway()
    result = GatewayAdmit(gw, lambda: "t").admit(
        ["--stack", "platform", "--role", "responder", "--task", "t", "--env-file", str(tmp_path / "env"),
         "--harnesses", "foo"])
    assert result.rc == 2 and gw.requests == []


def test_unwritable_env_file_releases_the_session_and_fails_closed(tmp_path) -> None:
    gw, body = _unbound_gateway()
    result = GatewayAdmit(gw, lambda: "t").admit(
        ["--stack", "platform", "--role", "responder", "--task", "t",
         "--env-file", str(tmp_path / "missing-dir" / "env")])
    assert result.rc == 3
    assert result.outputs["GW_DEFER_REASON"] == "dispatch-unusable: env-file"
    assert [d.path for d in gw.deletes()] == [f"/sessions/{body['session']['id']}"]
