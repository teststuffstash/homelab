"""GW-SESSIONS-RETRY — the retry contract: per-tier model lists, the task's strikes, the harness-scoped
strike, `attempt` (specs/endpoints/sessions.md §Admission → GW-SESSIONS-RETRY). Strikes are arranged
through the outcome endpoint (GW-SESSIONS-OUTCOME) on an earlier session of the SAME task, never
seeded. Header == argnames, description == id (tests/_rows.py)."""

from __future__ import annotations

import pytest

from ._codex_world import fresh_report
from ._rows import ABSENT, DASH, POLICY, body_of, enter_world, expect, inputs
from .conftest import attach_json, bearer, err, given, open_session, quiet, rule, then, when

pytestmark = rule("GW-SESSIONS-RETRY")

T = "specs-review homelab#2700"
TASKS = {"T": T, "another task": "specs-review homelab#2701"}
REVIEWER = {"stack": "platform", "role": "reviewer", "task": T, "round": 0}
PROBER = {"stack": "platform", "role": "prober", "task": T, "round": 0}


async def strike(gw, upstreams, body: dict, klass: str, via: str = "outcome") -> dict:
    """Arrange: an earlier session of the task ends with `klass` (or its request is answered
    upstream-500 → the gateway's provider-5xx), then is released."""
    with quiet():
        doc = await open_session(gw, **body)
        if via == "gateway":
            up = upstreams[doc["rail"]]
            up.behaviour = "upstream-500"
            await gw.post("/anthropic/v1/messages", headers=bearer(doc), json={"max_tokens": 8, "messages": []})
            up.behaviour = "upstream-ok"
        else:
            await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": klass})
        await gw.delete(f"/sessions/{doc['session']['id']}")
    attach_json(f"arranged strike: {klass} on ({doc['rail']}, {doc['model']}) for task {body['task']}",
                {"session": doc["session"]["id"], "attempt": body.get("attempt", 1), "via": via})
    return doc


# `strikes` cell → the arrange program: ("strike", body, attempt, class) through the outcome endpoint;
# ("refuted", body, attempt) = a gateway provider-5xx on the ride, then the consumer reports clean;
# ("fill", rail, n) = the rail at its cap; ("cool",) = a worker standard ride on openrouter answered 429.
STRIKES = {
    DASH: [],
    "harness-gave-up on (anthropic, claude/sonnet)": [("strike", REVIEWER, 1, "harness-gave-up")],
    "no-verdict on claude/sonnet": [("strike", REVIEWER, 1, "no-verdict")],
    "no-verdict on claude/sonnet for T": [("strike", REVIEWER, 1, "no-verdict")],
    "no-verdict on claude/sonnet, no-verdict on claude/opus": [("strike", REVIEWER, 1, "no-verdict"), ("strike", REVIEWER, 2, "no-verdict")],
    "provider-5xx (gateway) on claude/sonnet, then clean": [("refuted", REVIEWER, 1)],
    "no-verdict on claude/haiku": [("strike", PROBER, 1, "no-verdict")],
    "no-verdict on claude/sonnet, no-verdict on claude/opus; opencode at its 3": [
        ("strike", REVIEWER, 1, "no-verdict"), ("strike", REVIEWER, 2, "no-verdict"), ("fill", "opencode", 3)],
    "a 429 cooled (openrouter, deepseek/deepseek-v4-flash)": [("cool",)],
}


async def arrange_strikes(gw, upstreams, strikes: str) -> None:
    with given(f"strikes = {strikes}"):
        for step in STRIKES[strikes]:
            if step[0] == "strike":
                _, body, attempt, klass = step
                await strike(gw, upstreams, {**body, "attempt": attempt}, klass)
            elif step[0] == "refuted":
                _, body, attempt = step
                with quiet():
                    doc = await open_session(gw, **{**body, "attempt": attempt})
                    upstreams[doc["rail"]].behaviour = "upstream-500"
                    await gw.post("/anthropic/v1/messages", headers=bearer(doc), json={"max_tokens": 8, "messages": []})
                    upstreams[doc["rail"]].behaviour = "upstream-ok"
                    r = await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": "clean"})
                    await gw.delete(f"/sessions/{doc['session']['id']}")
                attach_json(f"arranged: a gateway provider-5xx on ({doc['rail']}, {doc['model']}), then clean", r.json())
            elif step[0] == "fill":
                _, rail, n = step
                with quiet():
                    for i in range(n):
                        await open_session(gw, role="worker", task=f"fill-{i}", rail=rail)
                attach_json(f"filled: {rail} × {n}", {"rail": rail, "active_sessions_opened": n})
            elif step[0] == "cool":
                with quiet():
                    doc = await open_session(gw, role="worker", rail="openrouter", harness="goose", task="arrange")
                    upstreams["openrouter"].behaviour = "upstream-429"
                    await gw.post("/openai/v1/chat/completions", headers=bearer(doc), json={"messages": []})
                    upstreams["openrouter"].behaviour = "upstream-ok"
                attach_json("arranged: the cooled cell", {"rail": "openrouter", "model": doc["model"]})


# -- strikes walk the list --------------------------------------------------------------------------
LIST_ROWS = [
    pytest.param("policy-default", "reviewer", "T", DASH, 1, "dispatch", "anthropic", "claude/sonnet",
                 id="a tier names an ordered list: the first model is taken"),
    pytest.param("policy-default", "reviewer", "T", "harness-gave-up on (anthropic, claude/sonnet)", 2, "dispatch", "anthropic", "claude/opus",
                 id="a cell strike moves the walk to the next model in the list"),
    pytest.param("policy-default", "reviewer", "T", "no-verdict on claude/sonnet", 2, "dispatch", "anthropic", "claude/opus",
                 id="a model strike excludes the model, the list continues"),
    pytest.param("policy-default", "reviewer", "T", "no-verdict on claude/sonnet, no-verdict on claude/opus", 3, "dispatch", "opencode", "opencode-go/claude-haiku-5-5",
                 id="a struck list moves the walk to the next rail"),
    pytest.param("policy-default", "reviewer", "another task", "no-verdict on claude/sonnet for T", 1, "dispatch", "anthropic", "claude/sonnet",
                 id="a strike is per task"),
    pytest.param("policy-default", "reviewer", "T", "provider-5xx (gateway) on claude/sonnet, then clean", 2, "dispatch", "anthropic", "claude/sonnet",
                 id="a refuted strike excludes nothing"),
]


@pytest.mark.parametrize(("world", "role", "task", "strikes", "attempt", "expected_decision", "expected_rail", "expected_model"), LIST_ROWS)
async def test_strikes_walk_the_list(gw, upstreams, world, role, task, strikes, attempt, expected_decision, expected_rail, expected_model):
    enter_world(world)
    inputs(role=role, task=task, strikes=strikes, attempt=attempt)
    await arrange_strikes(gw, upstreams, strikes)
    body = {"stack": "platform", "role": role, "task": TASKS[task], "round": 0, "attempt": attempt}
    with when(f"POST /sessions {body}"):
        r = await gw.post("/sessions", json=body)
    assert r.status_code == 200, r.text
    expect(r.json(), decision=expected_decision, rail=expected_rail, model=expected_model)


# -- cooled, exhausted, or held ---------------------------------------------------------------------
LEFT_ROWS = [
    pytest.param("policy-default · upstream-429", "worker", "light", "openrouter", "a 429 cooled (openrouter, deepseek/deepseek-v4-flash)", 1,
                 "dispatch", "openrouter", "deepseek/deepseek-v4.1-flash", DASH, DASH,
                 id="a cooled cell in the list is skipped, the next model taken"),
    pytest.param("policy-default", "prober", POLICY, POLICY, "no-verdict on claude/haiku", 2,
                 "defer", DASH, DASH, "cells-exhausted", ABSENT,
                 id="every cell struck: cells-exhausted, no retry_after_s ⚖"),
    pytest.param("policy-default", "reviewer", POLICY, POLICY, "no-verdict on claude/sonnet, no-verdict on claude/opus; opencode at its 3", 3,
                 "defer", DASH, DASH, "rail-capacity", 60,
                 id="a capacity-blocked rail outranks struck cells: the defer waits ⚖"),
]


@pytest.mark.parametrize(("world", "role", "tier", "rail", "strikes", "attempt",
                          "expected_decision", "expected_rail", "expected_model", "expected_reason", "expected_retry_after_s"), LEFT_ROWS)
async def test_cooled_exhausted_or_held(gw, upstreams, world, role, tier, rail, strikes, attempt,
                                        expected_decision, expected_rail, expected_model, expected_reason, expected_retry_after_s):
    enter_world(world)
    inputs(role=role, tier=tier, rail=rail, strikes=strikes, attempt=attempt)
    await arrange_strikes(gw, upstreams, strikes)
    body = {"stack": "platform", "task": T, "round": 0, "attempt": attempt, **body_of(role=role, tier=tier, rail=rail)}
    with when(f"POST /sessions {body}"):
        r = await gw.post("/sessions", json=body)
    assert r.status_code == 200, r.text
    expect(r.json(), decision=expected_decision, rail=expected_rail, model=expected_model, reason=expected_reason,
           retry_after_s=expected_retry_after_s)


# -- harness-scoped strikes (world policy-codex; operator ruling 2026-10-24, homelab#2867's round 1) --
TH = "homelab-2867-r1"
WORKER_TH = {"stack": "platform", "role": "worker", "task": TH, "round": 1}
STRUCK = "harness-fault on harness opencode"
REFUTED = "harness-fault on harness opencode, then clean on attempt 2's opencode session"

HARNESS_ROWS = [
    pytest.param("policy-codex", STRUCK, POLICY, 2, "dispatch", "opencode", "claude", "opencode-go/claude-haiku-5-5", DASH,
                 id="a harness strike moves the walk to a cell another harness speaks ⚖"),
    pytest.param("policy-codex", STRUCK, "goose", 2, "dispatch", "opencode", "goose", "opencode-go/deepseek-v4.1-flash", DASH,
                 id="a harness strike excludes no model"),
    pytest.param("policy-codex", STRUCK, "opencode", 2, "defer", DASH, DASH, DASH, "cells-exhausted",
                 id="an explicit harness that is struck defers ⚖"),
    pytest.param("policy-codex", REFUTED, POLICY, 3, "dispatch", "opencode", "opencode", "opencode-go/deepseek-v4.1-flash", DASH,
                 id="a refuted harness strike excludes nothing"),
]


async def _report(gw, doc: dict, klass: str) -> dict:
    r = await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": klass})
    assert r.status_code == 200, r.text
    return r.json()


async def arrange_harness_strike(app, gw, clock, strikes: str) -> None:
    with given("codex headroom observed fresh: 20 % / 64 % (the rail's admission gate)"):
        app.state.codex.headroom.observe(fresh_report(clock))
    with given(f"strikes = {strikes}: attempt 1 of task {TH} rode (opencode, opencode-go/deepseek-v4.1-flash) on harness opencode"):
        with quiet():
            first = await open_session(gw, **WORKER_TH)
            second = await open_session(gw, **WORKER_TH, attempt=2) if strikes == REFUTED else None
            struck = await _report(gw, first, "harness-fault")
            await gw.delete(f"/sessions/{first['session']['id']}")
            clean = None
            if second is not None:
                clock.advance(1)
                clean = await _report(gw, second, "clean")
                await gw.delete(f"/sessions/{second['session']['id']}")
        attach_json("arranged: the task's outcomes", {
            "attempt 1": {"rail": first["rail"], "harness": first["harness"], "model": first["model"], "strike": struck["strike"]},
            **({"attempt 2": {"rail": second["rail"], "harness": second["harness"], "model": second["model"],
                              "refuted": clean["refuted"]}} if second is not None else {}),
        })
        assert (first["rail"], first["harness"]) == ("opencode", "opencode"), first
        assert struck["strike"] == {"class": "harness-fault", "scope": "harness"}, struck


@pytest.mark.parametrize(("world", "strikes", "harness", "attempt",
                          "expected_decision", "expected_rail", "expected_harness", "expected_model", "expected_reason"), HARNESS_ROWS)
async def test_harness_scoped_strikes(codex_app, codex_gw, clock, world, strikes, harness, attempt,
                                      expected_decision, expected_rail, expected_harness, expected_model, expected_reason):
    enter_world(world)
    inputs(strikes=strikes, harness=harness, attempt=attempt)
    await arrange_harness_strike(codex_app, codex_gw, clock, strikes)
    body = {**WORKER_TH, "attempt": attempt, **body_of(harness=harness)}
    with when(f"POST /sessions {body}"):
        r = await codex_gw.post("/sessions", json=body)
    assert r.status_code == 200, r.text
    doc = r.json()
    expect(doc, decision=expected_decision, rail=expected_rail, harness=expected_harness, model=expected_model, reason=expected_reason)
    if expected_decision == "defer":
        with then("no retry_after_s: waiting does not help — the platform fixes the harness",
                  keys={"expected": ["decision", "reason"], "actual": sorted(doc)}):
            assert set(doc) == {"decision", "reason"}, doc


# -- the attempt counter ----------------------------------------------------------------------------
ATTEMPT_ROWS = [
    pytest.param("policy-default", "admit with no attempt, GET", "attempt = 1",
                 id="attempt defaults to 1 and is on the row"),
    pytest.param("policy-default", "attempt: 0", "400 malformed-body",
                 id="attempt below 1 is malformed"),
    pytest.param("policy-default", "admit T attempt 1 twice (the same caller, unbound)",
                 "the first released, its token 401 session-released; the second active",
                 id="a re-admission of the same attempt supersedes the active one ⚖"),
    pytest.param("policy-default", "admit T attempt 1, then attempt 2", "both active",
                 id="the next attempt does not supersede"),
    pytest.param("policy-default", "admit T attempt 1 bound to fixer-1, then bound to fixer-2", "both active",
                 id="another pod's same attempt is not superseded"),
    pytest.param("policy-default", "attempt 1 struck no-verdict on claude/sonnet and released; admit T attempt 1 again", "dispatch claude/opus",
                 id="a re-run that restarts at attempt 1 still meets the task's strikes ⚖"),
]
BIND = {"namespace": "platform-agents", "serviceaccount": "agentstack-worker"}


def _state(store, doc: dict) -> str:
    return "released" if store.get_session(doc["session"]["id"]).released_at is not None else "active"


@pytest.mark.parametrize(("world", "sequence", "expected_result"), ATTEMPT_ROWS)
async def test_the_attempt_counter(gw, upstreams, store, world, sequence, expected_result):
    enter_world(world)
    inputs(sequence=sequence)
    if sequence == "admit with no attempt, GET":
        with when("POST /sessions (reviewer, T, no attempt), then GET /sessions/{id}"):
            doc = await open_session(gw, **REVIEWER)
            g = (await gw.get(f"/sessions/{doc['session']['id']}")).json()
        result = f"attempt = {g['attempt']}"
    elif sequence == "attempt: 0":
        with when("POST /sessions (reviewer, T) with attempt 0"):
            r = await gw.post("/sessions", json={**REVIEWER, "attempt": 0})
        result = f"{r.status_code} {err(r)}" if r.status_code >= 400 else f"{r.status_code} {r.json().get('decision')}"
    elif sequence == "admit T attempt 1 twice (the same caller, unbound)":
        with given("attempt 1 of T admitted (unbound, no caller — policy-default observe)"):
            first = await open_session(gw, **REVIEWER)
        with when("POST /sessions (reviewer, T, attempt 1) again"):
            second = await open_session(gw, **REVIEWER)
        with quiet():
            r = await gw.post("/anthropic/v1/messages", headers=bearer(first), json={"max_tokens": 8, "messages": []})
        first_token = f"its token {r.status_code} {err(r)}" if r.status_code >= 400 else f"its token {r.status_code}"
        result = f"the first {_state(store, first)}, {first_token}; the second {_state(store, second)}"
    elif sequence in ("admit T attempt 1, then attempt 2", "admit T attempt 1 bound to fixer-1, then bound to fixer-2"):
        bound = "bound" in sequence
        first_body = {**REVIEWER, **({"role": "worker", "bind": {**BIND, "pod": "fixer-1"}} if bound else {})}
        second_body = {**REVIEWER, **({"role": "worker", "bind": {**BIND, "pod": "fixer-2"}} if bound else {"attempt": 2})}
        with given(f"first = {first_body}: admitted"):
            a = await open_session(gw, **first_body)
        with when(f"POST /sessions {second_body}"):
            b = await open_session(gw, **second_body)
        result = "both active" if (_state(store, a), _state(store, b)) == ("active", "active") else f"first {_state(store, a)}, second {_state(store, b)}"
    else:
        await arrange_strikes(gw, upstreams, "no-verdict on claude/sonnet")
        with when(f"POST /sessions {REVIEWER} — attempt 1 again"):
            doc = await open_session(gw, **REVIEWER)
        result = f"{doc['decision']} {doc['model']}"
    expect({"result": result}, result=expected_result)
