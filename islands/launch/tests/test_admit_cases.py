"""The 12 labelled admission cases — one per page row, sourced from `specs/admission.md`.

LAUNCH-ADMIT-HELPER: the 9 rows of "What a call returns". LAUNCH-ADMIT-BOUND: the 3 `via gw_admit`
rows of "An unusable dispatch" (the 4 `via launcher` rows: `test_launcher_ask_cases.py`). A case's id is the row's description cell; its world, args, via and
rc? cells are read from the page at collection, its prose cells are asserted in the case carrying the
id. The gateway's answer is the row's world, loaded through the strict reader; a BOUND row's defect is
applied to that whole world here — never a second hand-written file. Every request sent is validated
against the supplier's request schema.
"""

from __future__ import annotations

import copy
import shlex
import stat

import allure
import jsonschema
import pytest

from conftest import rule
from launch.gateway_admit import GatewayAdmit, Reply, Request, TransportError
from page import Row, table_under
from worlds import load_world, supplier_schema

HELPER_ROWS = table_under("What a call returns")
BOUND_ROWS = table_under("An unusable dispatch")
BOUND_VIA_GW_ADMIT = [r for r in BOUND_ROWS if r["via"] == "gw_admit"]

BOUND_ARGS = "--role coordinator --task t --bind platform-agents/agentstack-loop/p1"
UNBOUND_ARGS = "--role responder --task t --env-file F"

# defect (a BOUND row's prose cell) → what the case does to the whole world body
DEFECTS = {
    "harness-not-run": lambda b: {**b, "harness": "opencode"},
    "unbound-answer-bound": lambda b: {
        **{k: v for k, v in b.items() if k != "env"},
        "env_keys": ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL"],
        "pull_url": "http://agent-gateway.agent-egress.svc.cluster.local:8080/sessions/s-resp-1/env",
    },
    "unbound-env-newline": lambda b: {**b, "env": {**b["env"], "ANTHROPIC_MODEL": "sonnet\nX=1"}},
}
EXTRA_ARGS = {"harness-not-run": "--harnesses claude"}


class Gateway:
    """Injected transport: answers POST /sessions from a world, records every request."""

    def __init__(self, world, body=None):
        self.world, self.body, self.requests = world, body, []

    def __call__(self, req: Request) -> Reply:
        self.requests.append(req)
        if req.method == "DELETE":
            return Reply(200, {"released_at": "2026-11-01T15:00:00Z"})
        if self.world is None:
            raise TransportError("no world: no request expected")
        body = self.world.get("body") if self.body is None else self.body
        return Reply(self.world.get("status"), copy.deepcopy(body))

    def posts(self):
        return [r for r in self.requests if r.method == "POST"]

    def deletes(self):
        return [r for r in self.requests if r.method == "DELETE"]


def _request_validator() -> jsonschema.Draft202012Validator:
    schema = supplier_schema()
    return jsonschema.Draft202012Validator({**schema["post"]["input"], "$defs": schema["$defs"]})


def _run(row: Row, tmp_path, args_cell: str, body=None):
    world = None if row["world"] == "launcher-vars" else load_world(row["world"])
    gw = Gateway(world, body)
    env_file = tmp_path / "env"
    words = [str(env_file) if w == "F" else w for w in shlex.split(args_cell)]
    argv = ["--stack", "platform", *words]
    with allure.step(f"given world {row['world']}; when gw_admit {' '.join(argv)}"):
        adm = GatewayAdmit(gw, lambda: "placeholder-caller-token")
        result = adm.admit(argv)
    for req in gw.posts():
        with allure.step("then the request validates against the supplier's post.input"):
            assert list(_request_validator().iter_errors(req.body)) == [], req.body
    return adm, result, gw, env_file


def _expected_rc(row: Row) -> int:
    return int(row["rc?"].split()[0])


def _helper(row: Row, tmp_path):
    adm, result, gw, env_file = _run(row, tmp_path, row["args"])
    with allure.step(f"then rc {row['rc?']}"):
        assert result.rc == _expected_rc(row)
    out = result.outputs
    rid = row.id
    if rid == "bound-dispatch":
        assert out["GW_WIRE_MODEL"] == "opus"
        assert out["GW_ENV_KEYS"] == "ANTHROPIC_BASE_URL,ANTHROPIC_AUTH_TOKEN,ANTHROPIC_MODEL"
        assert out["GW_PULL_URL"].endswith("/sessions/s-coord-1/env")
        assert out["GW_PULL_PRELUDE"].strip() and "97" in out["GW_PULL_PRELUDE"]
        assert out["GW_SESSION_ID"] == "s-coord-1" and out["GW_HARNESS"] == "claude"
        assert gw.deletes() == []  # from rc 0 the caller owns the release
        adm.release(result)
        adm.release(result)
        assert [d.path for d in gw.deletes()] == ["/sessions/s-coord-1"]  # idempotent: one DELETE
    elif rid == "unbound-dispatch":
        mode = stat.S_IMODE(env_file.stat().st_mode)
        assert mode == 0o600
        world_env = load_world("gw-dispatch-unbound").get("body", "env")
        assert env_file.read_text() == "".join(f"{k}={v}\n" for k, v in world_env.items())
        token = load_world("gw-dispatch-unbound").get("body", "session", "token")
        assert all(token not in v for v in out.values()) and not any("GW_PULL" in k for k in out)
    elif rid == "defer":
        assert out["GW_DEFER_REASON"] == load_world("gw-defer").get("body", "reason") == "rail-capacity"
        assert out["GW_RETRY_AFTER"] == "120"
        assert gw.deletes() == []
    elif rid == "http-503":
        assert out["GW_DEFER_REASON"].startswith("gateway-http 503: {")
        assert "tokenreview-transient" in out["GW_DEFER_REASON"] and out["GW_RETRY_AFTER"] == "?"
    else:  # refused before any request: all outputs empty
        assert gw.requests == [] and out == {} and not env_file.exists()


def _bound(row: Row, tmp_path):
    base = load_world(row["world"]).get("body")
    args = (BOUND_ARGS if row["world"] == "gw-dispatch-bound" else UNBOUND_ARGS) + " " + EXTRA_ARGS.get(row.id, "")
    adm, result, gw, env_file = _run(row, tmp_path, args, body=DEFECTS[row.id](copy.deepcopy(base)))
    assert result.rc == _expected_rc(row)
    assert result.outputs["GW_DEFER_REASON"] == "dispatch-unusable: " + row["defer_reason?"]
    assert result.outputs["GW_RETRY_AFTER"] == "?"
    with allure.step(f"then released? {row['released?']}"):
        n = 1 if row["released?"] == "yes" else 0
        assert [d.path for d in gw.deletes()] == [f"/sessions/{base['session']['id']}"] * n
    assert not env_file.exists()  # nothing built on an unusable dispatch


CASES = {r.id: (r, "LAUNCH-ADMIT-HELPER", _helper) for r in HELPER_ROWS} | {
    r.id: (r, "LAUNCH-ADMIT-BOUND", _bound) for r in BOUND_VIA_GW_ADMIT
}


@pytest.mark.parametrize(
    "case_id",
    [pytest.param(i, marks=rule(CASES[i][1]), id=i) for i in CASES],
)
def test_admit_case(case_id: str, tmp_path) -> None:
    row, _rule, run = CASES[case_id]
    allure.dynamic.title(case_id)
    allure.dynamic.parameter("world", row["world"])
    run(row, tmp_path)
