"""GW-SESSIONS-RELEASE — DELETE /sessions/{id}: the launcher's finalize hook, and expiry
(specs/endpoints/sessions.md §The session → GW-SESSIONS-RELEASE). Header == argnames, description ==
id (tests/_rows.py)."""

from __future__ import annotations

import re

import pytest

from ._rows import DASH, enter_world, expect, inputs
from .conftest import attach_json, bearer, err, given, open_session, quiet, rule, when

pytestmark = rule("GW-SESSIONS-RELEASE")

GAUGE = 'gateway_sessions_active{rail="opencode"}'

ROWS = [
    pytest.param("policy-default", "active", "DELETE", 200, f"released_at set; {GAUGE} 0", id="release an active session"),
    pytest.param("policy-default", "released", "DELETE", 200, f"the same released_at; {GAUGE} 0", id="release twice"),
    pytest.param("policy-default", DASH, "DELETE /sessions/nope", 404, "session-not-found", id="release an unknown id"),
    pytest.param("policy-default", "released", "POST /openai/v1/chat/completions", 401, "session-released", id="a released token on the data plane"),
    pytest.param("policy-default", "expired", "POST /anthropic/v1/messages", 401, "session-expired", id="an expired token on the data plane"),
    pytest.param("policy-default", "expired, no DELETE, the rail at its cap", "POST /sessions rail opencode", 200, "dispatch opencode",
                 id="an expired session releases its slot"),
    pytest.param("policy-default", "expired", "DELETE", 200, "released_at set; the data plane stays session-expired",
                 id="release of an expired session: expiry is the older fact ⚖"),
]


async def _active(gw) -> int:
    with quiet():
        text = (await gw.get("/metrics")).text
    return int(re.search(r'^gateway_sessions_active\{rail="opencode"\} (\d+)$', text, re.M).group(1))


@pytest.mark.parametrize(("world", "session_state", "action", "expected_status", "expected_result"), ROWS)
async def test_release_and_expiry(gw, policy, clock, world, session_state, action, expected_status, expected_result):
    enter_world(world)
    inputs(session_state=session_state, action=action)
    doc = first = None
    with given(f"session_state = {session_state}"):
        if session_state != DASH:
            anthropic = action == "POST /anthropic/v1/messages"
            with quiet():
                doc = await open_session(gw, **({"role": "reviewer", "harness": "claude"} if anthropic else {}))
            if session_state == "released":
                first = (await gw.delete(f"/sessions/{doc['session']['id']}")).json()
                clock.advance(5)
            elif session_state.startswith("expired"):
                if "at its cap" in session_state:
                    with quiet():
                        for i in range(policy.rails["opencode"].max_sessions - 1):
                            await open_session(gw, task=f"fill-{i}")
                    r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "t", "rail": "opencode"})
                    attach_json("a further admission at the cap", r.json())
                    assert r.json()["decision"] == "defer", r.text
                clock.advance(policy.session_ttl_s + 1)
    sid = doc["session"]["id"] if doc else "nope"
    with when(f"action = {action}"):
        if action.startswith("DELETE"):
            r = await gw.delete(f"/sessions/{sid}")
        elif action.startswith("POST /sessions "):
            r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "t", "rail": "opencode"})
        else:
            r = await gw.post(action.split(" ", 1)[1], json={"messages": []}, headers=bearer(doc))
    body = r.json()
    if r.status_code >= 400:
        result = err(r)
    elif action.startswith("POST /sessions "):
        result = f"{body['decision']} {body.get('rail') or body.get('reason')}"
    elif session_state == "released":
        result = ("the same released_at" if body.get("released_at") == first["released_at"] else f"released_at {body.get('released_at')} ≠ {first['released_at']}") + f"; {GAUGE} {await _active(gw)}"
    elif session_state == "active":
        result = ("released_at set" if body.get("released_at") else "no released_at") + f"; {GAUGE} {await _active(gw)}"
    else:
        with quiet():
            dp = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
        result = ("released_at set" if body.get("released_at") else "no released_at") + f"; the data plane stays {err(dp)}"
    expect({"status": r.status_code, "result": result}, status=expected_status, result=expected_result)
