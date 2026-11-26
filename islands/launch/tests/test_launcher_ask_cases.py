"""The 13 LAUNCH-ADMIT-LAUNCHER rows that send a request, and the 4 `via launcher` LAUNCH-ADMIT-BOUND rows
(homelab#3408).

One case per page row; id = the row's description cell; `world`, and the `rc?` / `harness?` / `model?`
/ `released?` / `defer_reason?` / `request?` cells are read from the page at collection. The `knobs`
and `reply` cells are prose, set up by the case carrying the row's id (SETUP below); the gateway's
answer is the row's world loaded through the strict reader, changed only by what `reply` / `defect`
says — never a second hand-written file. Every request sent is validated against the supplier's
`post.input`, read in place — except the `canary` member, which that schema does not define yet
(see `_validate`).
"""

from __future__ import annotations

import copy
import re

import allure
import pytest

from conftest import rule
from launch.gateway_admit import MODEL_KEY
from launch.launcher_admission import DEFAULT_GATEWAY_URL, Asked, LauncherAdmission
from page import table_under
from test_admit_cases import Gateway, _request_validator
from test_launcher_cases import OK_TOKEN
from worlds import load_stack_world, load_world

ROWS = {r.id: r for r in table_under("Admission through the launcher")}
BOUND_ROWS = {r.id: r for r in table_under("An unusable dispatch")}
# Rows the island does not build (Goal #3480 pin 6): the old path, work #3409.
NEVER_BUILT = ["off", "other-stack"]
MINTED = "placeholder-minted-token"


def _knob_url(case_id: str) -> str:
    """The `AGENT_GATEWAY_URL=<value>` the case's knobs cell on the page sets."""
    m = re.search(r"AGENT_GATEWAY_URL=([^\s`,]+)", ROWS[case_id]["knobs"])
    assert m, f"{case_id}: knobs cell carries no AGENT_GATEWAY_URL=<value>"
    return m.group(1)


OVERRIDDEN_URL = _knob_url("dispatch-goose")

# case id → (knobs, admit kwargs, task, round, reply: (rail, harness, model) or None, answer: "world" | "none")
_OPENCODE = ("opencode", "opencode", "opencode-go/deepseek-v4-flash")
SETUP = {
    "caller-minted": ({"AGENT_GATEWAY_CALLER_SA": "platform-agents/agentstack-loop", "AGENT_GATEWAY_RAIL": "opencode"},
                      {}, "issue-1", "1", _OPENCODE, "world"),
    "dispatch-opencode": ({"AGENT_GATEWAY_RAIL": "opencode"}, {}, "issue-1", "1", _OPENCODE, "world"),
    "dispatch-claude-explicit": ({}, {"harness": "claude"}, "issue-42", "2",
                                 ("opencode", "claude", "opencode-go/deepseek-v4-flash"), "world"),
    "dispatch-claude-subscription": ({}, {"harness": "claude"}, "issue-1", "1",
                                     ("anthropic", "claude", "claude/sonnet"), "world"),
    "dispatch-goose": ({"AGENT_GATEWAY_URL": OVERRIDDEN_URL}, {"harness": "goose"}, "issue-1", "1",
                       ("openrouter", "goose", "deepseek/deepseek-v4-flash"), "world"),
    "dispatch-codex": ({"AGENT_GATEWAY_ROLE": "prober"}, {"harness": "codex"}, "issue-1", "1",
                       ("codex", "codex", "codex/gpt-6-astra"), "world"),
    "dispatch-attempt-2": ({"AGENT_GATEWAY_ATTEMPT": "2"}, {}, "issue-1", "1", _OPENCODE, "world"),
    "dispatch-canary": ({"AGENT_GATEWAY_ROLE": "prober",
                         "AGENT_GATEWAY_CANARY": "deepseek/deepseek-v4.1-flash@deepinfra"}, {}, "issue-1", "1",
                        ("openrouter", "opencode", "deepseek/deepseek-v4.1-flash"), "world"),
    "defer": ({}, {}, "issue-1", "1", None, "world"),
    "http-503": ({}, {}, "issue-1", "1", None, "world"),
    "unreachable": ({}, {}, "issue-1", "1", None, "none"),
    "fallback-unreachable": ({"AGENT_GATEWAY_FALLBACK_EXIT": "75"}, {}, "issue-1", "1", None, "none"),
    "fallback-defer": ({"AGENT_GATEWAY_FALLBACK_EXIT": "75"}, {}, "issue-1", "1", None, "world"),
}
# BOUND `via launcher` defect (the row's prose cell) → what the case does to the whole world body
DEFECTS = {
    "credential-in-answer": lambda b: {
        **{k: v for k, v in b.items() if k not in ("env_keys", "pull_url")},
        "harness": "opencode",
        "session": {**b["session"], "token": "placeholder-session-token"},
        "env": {"OPENCODE_CONFIG_CONTENT": "placeholder"},
    },
    "bad-pull-url": lambda b: {**b, "pull_url": "http://agent-gateway.invalid/other/path"},
    "unusable-env": lambda b: {**b, "harness": "opencode", "env_keys": ["BAD KEY"]},
    "unknown-decision": lambda b: {**b, "decision": "maybe", "session": {**b["session"], "token": "placeholder"}},
}
BOUND_CASES = {i: BOUND_ROWS[i] for i in DEFECTS}
CASES = {i: ROWS[i] for i in SETUP}


def _reply_body(world, reply):
    """The world's body, changed to the `reply` cell's rail / harness / model and that harness's env keys."""
    body = copy.deepcopy(world.get("body"))
    if reply is not None:
        rail, harness, model = reply
        keys = [k for k in body["env_keys"] if k not in MODEL_KEY.values()]
        body.update(rail=rail, harness=harness, model=model, env_keys=[*keys, MODEL_KEY[harness]])
    return body


def _validate(req) -> None:
    """The request validates against the supplier's `post.input`. `canary` is the one member the
    supplier's schema does not define (additionalProperties:false) though its page names it
    (gateway sessions.md, GW-CATALOG-OR-CANARY): it is checked here against the page's shape and left
    out of the schema check — a supplier gap, reported on the PR."""
    body = {k: v for k, v in req.body.items() if k != "canary"}
    assert list(_request_validator().iter_errors(body)) == [], req.body
    if "canary" in req.body:
        assert set(req.body["canary"]) == {"model", "provider"}


def _request_cell(cell: str) -> dict[str, str]:
    """`rail: opencode`, `canary: {model: m, provider: p}` … → {key: value text} (bare words dropped)."""
    return {m.group(1): m.group(2).strip() for m in re.finditer(r"(\w+): (\{[^}]*\}|[^,{]+)", cell)}


def _launch(world_id: str, knobs, kwargs, task, rnd, body, answer):
    stack = load_stack_world("stack-platform").get("row")
    world = load_world(world_id)
    gw = Gateway(None if answer == "none" else world, body)
    adm = LauncherAdmission(gw, lambda _p: OK_TOKEN, lambda _sa: MINTED)
    with allure.step(f"given world {world_id}, knobs {knobs}, args {kwargs}, task {task} r{rnd}"):
        result = adm.ask(knobs, stack, "platform-repo", task, round=rnd, run="r", **kwargs)
    for req in gw.posts():
        _validate(req)
    return result, gw


def _post(gw):
    assert len(gw.posts()) == 1, "one POST /sessions per admission"
    return gw.posts()[0]


@pytest.mark.parametrize("case_id", [pytest.param(i, marks=rule("LAUNCH-ADMIT-LAUNCHER"), id=i) for i in CASES])
def test_launcher_request(case_id: str) -> None:
    row = ROWS[case_id]
    allure.dynamic.title(case_id)
    allure.dynamic.parameter("world", row["world"])
    knobs, kwargs, task, rnd, reply, answer = SETUP[case_id]
    world_id = row["world"].split(" · ")[1]
    world = load_world(world_id)
    result, gw = _launch(world_id, knobs, kwargs, task, rnd,
                         _reply_body(world, reply) if world_id == "gw-dispatch-bound" else None, answer)
    assert isinstance(result, Asked)
    req = _post(gw)
    body = req.body
    with allure.step("then the request: {stack, role, task, round} + the request? cell"):
        assert body["stack"] == load_stack_world("stack-platform").get("row", "name") == "platform"
        assert body["role"] == knobs.get("AGENT_GATEWAY_ROLE", "worker")
        assert body["task"] == task and body["round"] == int(rnd)
        pod = f"agent-platform-repo-{task}-r{rnd}"
        assert body["bind"] == {"namespace": "platform-repo", "serviceaccount": "agentstack-worker", "pod": pod}
        assert "model" not in body  # LAUNCH-ADMIT-NO-MODEL
        sent = _request_cell(row["request?"])
        expected_extra = {k for k in sent if k != "canary"} | ({"canary"} if "canary" in sent else set())
        stock = {"stack", "role", "task", "round", "bind"}
        assert set(body) - stock == expected_extra - {"role"}, (set(body), row["request?"])
        for key in ("rail", "harness", "attempt"):
            if key in sent:
                assert str(body[key]) == sent[key]
        if "role" in sent:
            assert body["role"] == sent["role"]
        if "canary" in sent:
            model, provider = re.findall(r"model: ([^,]+), provider: ([^}]+)", sent["canary"])[0]
            assert body["canary"] == {"model": model, "provider": provider}
        if "minted bearer" in row["request?"]:
            assert req.headers["Authorization"] == f"Bearer {MINTED}"
        else:
            assert req.headers["Authorization"] == f"Bearer {OK_TOKEN}"
    if "AGENT_GATEWAY_URL" in knobs:
        with allure.step("then the request went to the overridden address"):
            assert req.base == _knob_url(case_id) == row["request?"].split(" → ")[1].strip("`")
    else:
        assert req.base == DEFAULT_GATEWAY_URL
    with allure.step(f"then harness {row['harness?']}, model {row['model?']}, exit {row['rc?']}"):
        assert result.exit == int(row["rc?"])
        if row["harness?"] != "—":
            assert result.admission.outputs["GW_HARNESS"] == row["harness?"]
            assert result.admission.outputs["GW_MODEL"] == row["model?"]
            assert gw.deletes() == []  # from exit 0 the caller owns the release
        else:
            assert result.admission.outputs.get("GW_HARNESS") is None
            assert gw.deletes() == []  # no session exists on a defer / a failed ask


@pytest.mark.parametrize("case_id", [pytest.param(i, marks=rule("LAUNCH-ADMIT-BOUND"), id=i) for i in BOUND_CASES])
def test_launcher_unusable_dispatch(case_id: str) -> None:
    row = BOUND_ROWS[case_id]
    allure.dynamic.title(case_id)
    allure.dynamic.parameter("world", row["world"])
    world = load_world(row["world"])
    body = DEFECTS[case_id](copy.deepcopy(world.get("body")))
    result, gw = _launch(row["world"], {}, {}, "issue-1", "1", body, "world")
    assert isinstance(result, Asked)
    cell = row["defer_reason?"]
    whole = cell.startswith("*(whole)* ")
    expected = cell.removeprefix("*(whole)* ").removesuffix(" (body never printed)") if whole \
        else "dispatch-unusable: " + cell
    with allure.step(f"then exit {row['rc?']}, defer_reason {expected!r}"):
        assert row["via"] == "launcher" and result.exit == int(row["rc?"].split()[0]) == 1
        assert result.admission.outputs["GW_DEFER_REASON"] == expected
    with allure.step(f"then released? {row['released?']}"):
        n = 1 if row["released?"] == "yes" else 0
        assert [d.path for d in gw.deletes()] == [f"/sessions/{world.get('body', 'session', 'id')}"] * n
    if whole:
        assert "placeholder" not in result.admission.outputs["GW_DEFER_REASON"]  # the body is never printed


@pytest.mark.parametrize("fallback,expected", [("75", 75), (None, 2)])
def test_helper_refusal_takes_the_fallback_exit(fallback, expected) -> None:
    """Unlabelled: a refusal by the helper (rc 2: a canary with no `@`) is turned into the fallback exit
    when one is set, and stays 2 when not."""
    knobs = {"AGENT_GATEWAY_CANARY": "foo"}
    if fallback:
        knobs["AGENT_GATEWAY_FALLBACK_EXIT"] = fallback
    stack = load_stack_world("stack-platform").get("row")
    gw = Gateway(None, None)
    adm = LauncherAdmission(gw, lambda _p: OK_TOKEN, lambda _sa: MINTED)
    result = adm.ask(knobs, stack, "platform-repo", "issue-1", round="1", run="r")
    assert result.admission.rc == 2 and gw.posts() == []
    assert result.exit == expected
