"""GW-SESSIONS-ADMIT — the retry contract: per-tier model lists, the task's strikes, `attempt`
(specs/endpoints/sessions.md §The retry contract).

World policy-default: `rails.anthropic.models.heavy` = [claude/sonnet, claude/opus] (the reviewer's
tier), `rails.openrouter.models.light` = [deepseek/deepseek-v4-flash, deepseek/deepseek-v4.1-flash];
every other tier is a bare string (= a one-item list). Strikes are arranged through the outcome
endpoint (GW-SESSIONS-OUTCOME) on an earlier session of the SAME task, never seeded. Task T =
`specs-review homelab#2700`, round 0.

The walk:

| description | arrange (the task's strikes) | body || decision | rail | model | reason |
|---|---|---||---|---|---|---|
| a tier names an ordered list: the first model is taken | — | reviewer, T || dispatch | anthropic | claude/sonnet | — |
| a cell strike moves the walk to the next model in the list | harness-gave-up on (anthropic, claude/sonnet) | reviewer, T, attempt 2 || dispatch | anthropic | claude/opus | — |
| a model strike excludes the model, the list continues | no-verdict on claude/sonnet | reviewer, T, attempt 2 || dispatch | anthropic | claude/opus | — |
| a struck list moves the walk to the next rail | no-verdict on claude/sonnet and on claude/opus | reviewer, T, attempt 3 || dispatch | opencode | opencode-go/claude-sonnet-4-6 | — |
| a strike is per task | no-verdict on claude/sonnet for T | reviewer, another task || dispatch | anthropic | claude/sonnet | — |
| a refuted strike excludes nothing | provider-5xx (gateway) on claude/sonnet, then clean on that session | reviewer, T, attempt 2 || dispatch | anthropic | claude/sonnet | — |
| a cooled cell in the list is skipped, the next model taken | a 429 cooled (openrouter, deepseek/deepseek-v4-flash) | worker, tier light, rail openrouter || dispatch | openrouter | deepseek/deepseek-v4.1-flash | — |
| every cell struck: cells-exhausted, no retry_after_s | no-verdict on claude/haiku (prober: anthropic only, light) | prober, T, attempt 2 || defer | — | — | cells-exhausted |
| a capacity-blocked rail outranks struck cells: the defer waits | no-verdict on claude/sonnet and claude/opus; opencode at its 3 | reviewer, T, attempt 3 || defer | — | — | rail-capacity |

`attempt`:

| description | sequence || result |
|---|---||---|
| attempt defaults to 1 and is on the row | admit with no attempt, GET || attempt = 1 |
| attempt below 1 is malformed | attempt 0 || 400 malformed-body |
| a re-admission of the same attempt supersedes the active one | admit T attempt 1 twice (same caller, unbound) || the first released (its token refused 401 session-released), the second active |
| the next attempt does not supersede | admit T attempt 1, then attempt 2 || both active |
| another pod's same attempt is not superseded | admit T attempt 1 bound to fixer-1, then bound to fixer-2 || both active |
| a re-run that restarts at attempt 1 still meets the task's strikes | attempt 1 struck no-verdict on claude/sonnet and released; admit T attempt 1 again || dispatch claude/opus |
"""

from __future__ import annotations

import pytest

from .conftest import (
    attach_json,
    bearer,
    check,
    err,
    given,
    open_session,
    quiet,
    rule,
    then,
    then_eq,
    when,
    world,
)

pytestmark = rule("GW-SESSIONS-ADMIT")

T = "specs-review homelab#2700"
REVIEWER = {"stack": "platform", "role": "reviewer", "task": T, "round": 0}


async def _strike(gw, upstreams, body: dict, klass: str, via: str = "outcome"):
    """Arrange a strike on the task: an earlier session of it ends with `klass` (or its request is
    answered upstream-500 → the gateway's provider-5xx), then is released."""
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


async def _admit(gw, body: dict) -> dict:
    with when(f"POST /sessions body {body}"):
        r = await gw.post("/sessions", json=body)
    then_eq("status", r.status_code, 200)
    return r.json()


def _verdict(doc: dict, expected: dict) -> None:
    claim = "expected " + ", ".join(f"{k} = {v}" for k, v in expected.items())
    with then(claim, **{k: {"expected": v, "actual": doc.get(k)} for k, v in expected.items()}):
        assert {k: doc.get(k) for k in expected} == expected, f"{claim}: got {doc}"


async def test_first_in_list(gw):
    """row: a tier names an ordered list: the first model is taken"""
    world()
    _verdict(await _admit(gw, REVIEWER), {"decision": "dispatch", "rail": "anthropic", "model": "claude/sonnet"})


WALK_ROWS = [
    ("a cell strike moves the walk to the next model in the list", [("harness-gave-up", 1)], {"attempt": 2},
     {"decision": "dispatch", "rail": "anthropic", "model": "claude/opus"}),
    ("a model strike excludes the model, the list continues", [("no-verdict", 1)], {"attempt": 2},
     {"decision": "dispatch", "rail": "anthropic", "model": "claude/opus"}),
    ("a struck list moves the walk to the next rail", [("no-verdict", 1), ("no-verdict", 2)], {"attempt": 3},
     {"decision": "dispatch", "rail": "opencode", "model": "opencode-go/claude-sonnet-4-6"}),
    ("a strike is per task", [("no-verdict", 1)], {"task": "specs-review homelab#2701"},
     {"decision": "dispatch", "rail": "anthropic", "model": "claude/sonnet"}),
]


@pytest.mark.parametrize(("strikes", "body", "expected"), [r[1:] for r in WALK_ROWS], ids=[r[0] for r in WALK_ROWS])
async def test_walk(gw, upstreams, strikes, body, expected):
    world()
    for klass, attempt in strikes:
        with given(f"strike: attempt {attempt} of task {T} ended {klass}"):
            await _strike(gw, upstreams, {**REVIEWER, "attempt": attempt}, klass)
    _verdict(await _admit(gw, {**REVIEWER, **body}), expected)


async def test_refuted_excludes_nothing(gw, upstreams):
    """row: a refuted strike excludes nothing"""
    world(upstream="upstream-500")
    with given("attempt 1: its request answered upstream-500 (a gateway provider-5xx on (anthropic, claude/sonnet)), then it reported clean"):
        with quiet():
            doc = await open_session(gw, **REVIEWER)
            upstreams["anthropic"].behaviour = "upstream-500"
            await gw.post("/anthropic/v1/messages", headers=bearer(doc), json={"max_tokens": 8, "messages": []})
            upstreams["anthropic"].behaviour = "upstream-ok"
            r = await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": "clean"})
            await gw.delete(f"/sessions/{doc['session']['id']}")
        attach_json("attempt 1's clean outcome", r.json())
    _verdict(await _admit(gw, {**REVIEWER, "attempt": 2}), {"decision": "dispatch", "rail": "anthropic", "model": "claude/sonnet"})


async def test_cooled_in_list(gw, upstreams):
    """row: a cooled cell in the list is skipped, the next model taken"""
    world(upstream="upstream-429")
    with given("a 429 cooled (openrouter, deepseek/deepseek-v4-flash): a worker standard ride there answered upstream-429"):
        with quiet():
            doc = await open_session(gw, role="worker", rail="openrouter", harness="goose", task="arrange")
            upstreams["openrouter"].behaviour = "upstream-429"
            await gw.post("/openai/v1/chat/completions", headers=bearer(doc), json={"messages": []})
            upstreams["openrouter"].behaviour = "upstream-ok"
        attach_json("arranged: the cooled cell", {"rail": "openrouter", "model": doc["model"]})
    _verdict(await _admit(gw, {"stack": "platform", "role": "worker", "task": "t-light", "tier": "light", "rail": "openrouter"}),
             {"decision": "dispatch", "rail": "openrouter", "model": "deepseek/deepseek-v4.1-flash"})


async def test_cells_exhausted(gw, upstreams):
    """row: every cell struck: cells-exhausted, no retry_after_s"""
    world()
    body = {"stack": "platform", "role": "prober", "task": T, "round": 0}
    with given("strike: attempt 1 of the prober task ended no-verdict on (anthropic, claude/haiku) — its only cell"):
        await _strike(gw, upstreams, body, "no-verdict")
    doc = await _admit(gw, {**body, "attempt": 2})
    _verdict(doc, {"decision": "defer", "reason": "cells-exhausted"})
    with then("no retry_after_s: waiting does not help — the caller escalates", keys={"expected": ["decision", "reason"], "actual": sorted(doc)}):
        assert set(doc) == {"decision", "reason"}


async def test_capacity_outranks_struck(gw, upstreams):
    """row: a capacity-blocked rail outranks struck cells: the defer waits"""
    world()
    with given("strikes: no-verdict on claude/sonnet (attempt 1) and claude/opus (attempt 2)"):
        await _strike(gw, upstreams, {**REVIEWER, "attempt": 1}, "no-verdict")
        await _strike(gw, upstreams, {**REVIEWER, "attempt": 2}, "no-verdict")
    with given("state: opencode holds 3 active sessions (its cap)"):
        with quiet():
            for i in range(3):
                await open_session(gw, role="worker", task=f"fill-{i}", rail="opencode")
    doc = await _admit(gw, {**REVIEWER, "attempt": 3})
    _verdict(doc, {"decision": "defer", "reason": "rail-capacity", "retry_after_s": 60})


async def test_attempt_default(gw, store):
    """row: attempt defaults to 1 and is on the row"""
    world()
    doc = await _admit(gw, REVIEWER)
    with then("GET /sessions/{id} → attempt = 1"):
        r = await gw.get(f"/sessions/{doc['session']['id']}")
        check("attempt", r.json()["attempt"], 1)


async def test_attempt_malformed(gw):
    """row: attempt below 1 is malformed"""
    world()
    with when("POST /sessions with attempt 0"):
        r = await gw.post("/sessions", json={**REVIEWER, "attempt": 0})
    then_eq("status", r.status_code, 400)
    then_eq("code", err(r), "malformed-body", claim="error code = malformed-body")


async def test_same_attempt_supersedes(gw):
    """row: a re-admission of the same attempt supersedes the active one"""
    world()
    with given("attempt 1 of T admitted (unbound, no caller — policy-default observe)"):
        first = await open_session(gw, **REVIEWER)
    second = await _admit(gw, REVIEWER)
    with then("the first is released and its token refused (401 session-released); the second is active"):
        with quiet():  # one verdict carries the three observations
            g1 = (await gw.get(f"/sessions/{first['session']['id']}")).json()
            g2 = (await gw.get(f"/sessions/{second['session']['id']}")).json()
            r = await gw.post("/anthropic/v1/messages", headers=bearer(first), json={"max_tokens": 8, "messages": []})
        check("first released · second released_at · first token's answer",
              (g1["released_at"] is not None, g2["released_at"], r.status_code, r.json()["error"]["code"]),
              (True, None, 401, "session-released"))


ACTIVE_ROWS = [
    ("the next attempt does not supersede", {}, {"attempt": 2}),
    ("another pod's same attempt is not superseded",
     {"role": "worker", "task": T, "bind": {"namespace": "platform-agents", "serviceaccount": "agentstack-worker", "pod": "fixer-1"}},
     {"role": "worker", "task": T, "bind": {"namespace": "platform-agents", "serviceaccount": "agentstack-worker", "pod": "fixer-2"}}),
]


@pytest.mark.parametrize(("first", "second"), [r[1:] for r in ACTIVE_ROWS], ids=[r[0] for r in ACTIVE_ROWS])
async def test_both_active(gw, store, first, second):
    world()
    with given(f"admitted: {first or 'T attempt 1'}"):
        a = await open_session(gw, **{**REVIEWER, **first})
    b = await _admit(gw, {**REVIEWER, **second})
    with then("both active"):
        check("released_at", [store.get_session(a["session"]["id"]).released_at, store.get_session(b["session"]["id"]).released_at], [None, None])


async def test_rerun_meets_strikes(gw, upstreams):
    """row: a re-run that restarts at attempt 1 still meets the task's strikes"""
    world()
    with given("attempt 1 of T ended no-verdict on claude/sonnet and was released"):
        await _strike(gw, upstreams, REVIEWER, "no-verdict")
    _verdict(await _admit(gw, REVIEWER), {"decision": "dispatch", "rail": "anthropic", "model": "claude/opus"})
