"""GW-SESSIONS-RELEASE — DELETE /sessions/{id}: the launcher's finalize hook (specs/endpoints/sessions.md).

| description | session state | action | status | result |
|---|---|---|---|---|
| release an active session | active | DELETE | 200 | released_at set; gateway_sessions_active{rail} - 1 |
| release twice | released | DELETE | 200 | same released_at, no second decrement |
| release an unknown id | — | DELETE /sessions/nope | 404 | session-not-found |
| a released token on the data plane | released | POST /openai/v1/chat/completions | 401 | session-released |
| an expired token on the data plane | expired | POST /anthropic/v1/messages | 401 | session-expired |
| an expired session releases its slot | expired, no DELETE | admission walk | — | the slot counts as free |
| release of an expired session | expired | DELETE | 200 | released_at set; the data-plane verdict stays session-expired |
"""

from __future__ import annotations

import re

from .conftest import attach_json, bearer, check, err, given, open_session, quiet, rule, then, when, world

pytestmark = rule("GW-SESSIONS-RELEASE")


async def _active(gw, rail: str) -> int:
    """The gauge value (muted read: the value lands in the caller's verdict, not the /metrics text)."""
    with quiet():
        text = (await gw.get("/metrics")).text
    return int(re.search(rf'^gateway_sessions_active\{{rail="{rail}"\}} (\d+)$', text, re.M).group(1))


async def test_release_active(gw):
    """row: release an active session"""
    world()
    with given("an active session on opencode (gateway_sessions_active{rail=opencode} = 1)"):
        doc = await open_session(gw)
        check("gateway_sessions_active{rail=opencode}", await _active(gw, "opencode"), 1)
    sid = doc["session"]["id"]
    with when(f"DELETE /sessions/{sid}"):
        r = await gw.delete(f"/sessions/{sid}")
    with then("status 200, body exactly {id, released_at} with the session's id, released_at in Z"):
        body = r.json()
        check("(status, body keys, id, released_at ends Z)", (r.status_code, sorted(body), body["id"], body["released_at"].endswith("Z")),
              (200, ["id", "released_at"], sid, True))
    with then("after: gateway_sessions_active{rail=opencode} = 0"):
        check("gateway_sessions_active{rail=opencode}", await _active(gw, "opencode"), 0)
    with then("GET /sessions/{id} shows the same released_at"):
        check("released_at", (await gw.get(f"/sessions/{sid}")).json()["released_at"], r.json()["released_at"])


async def test_release_twice(gw, clock):
    """row: release twice"""
    world()
    with given("a session released once, then the clock +5 s"):
        doc = await open_session(gw)
        first = (await gw.delete(f"/sessions/{doc['session']['id']}")).json()
        clock.advance(5)
    with when(f"DELETE /sessions/{doc['session']['id']} a second time"):
        second = await gw.delete(f"/sessions/{doc['session']['id']}")
    with then("status 200 with the FIRST released_at", released_at={"expected": first["released_at"], "actual": second.json().get("released_at")}):
        assert second.status_code == 200 and second.json()["released_at"] == first["released_at"]
    with then("after: gateway_sessions_active{rail=opencode} = 0"):
        check("gateway_sessions_active{rail=opencode}", await _active(gw, "opencode"), 0)


async def test_release_unknown(gw):
    """row: release an unknown id"""
    world()
    with when("DELETE /sessions/nope"):
        r = await gw.delete("/sessions/nope")
    with then("status 404 with code session-not-found"):
        check("(status, code)", (r.status_code, err(r)), (404, "session-not-found"))


async def test_released_token_on_data_plane(gw):
    """row: a released token on the data plane"""
    world()
    with given("a session, released (DELETE)"):
        doc = await open_session(gw)
        await gw.delete(f"/sessions/{doc['session']['id']}")
    with when("POST /openai/v1/chat/completions with the released token"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    with then("status 401 with code session-released"):
        check("(status, code)", (r.status_code, err(r)), (401, "session-released"))


async def test_expired_token_on_data_plane(gw, policy, clock):
    """row: an expired token on the data plane"""
    world()
    with given(f"a session on rail anthropic (reviewer, harness claude), then the clock passes expires_at (+{policy.session_ttl_s + 1} s)"):
        doc = await open_session(gw, role="reviewer", harness="claude")
        clock.advance(policy.session_ttl_s + 1)
    with when("POST /anthropic/v1/messages with the expired token"):
        r = await gw.post("/anthropic/v1/messages", json={"messages": []}, headers=bearer(doc))
    with then("status 401 with code session-expired"):
        check("(status, code)", (r.status_code, err(r)), (401, "session-expired"))


async def test_expired_releases_slot(gw, policy, clock):
    """row: an expired session releases its slot"""
    world()
    cap = policy.rails["opencode"].max_sessions
    with given(f"state: rail opencode holds {cap} active sessions (its cap) and a further admission defers"):
        with quiet():
            for i in range(cap):
                await open_session(gw, task=f"fill-{i}")
        attach_json(f"filled: opencode × {cap}", {"rail": "opencode", "active_sessions_opened": cap})
        r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "t", "rail": "opencode"})
        check("decision", r.json()["decision"], "defer")
    with when(f"the clock passes expires_at (+{policy.session_ttl_s + 1} s), no DELETE"):
        clock.advance(policy.session_ttl_s + 1)
    with then("a new admission with rail=opencode dispatches on opencode"):
        check("rail", (await open_session(gw, task="t", rail="opencode"))["rail"], "opencode")


async def test_release_of_expired(gw, policy, clock):
    """row: release of an expired session"""
    world()
    with given(f"a session, then the clock passes expires_at (+{policy.session_ttl_s + 1} s)"):
        doc = await open_session(gw)
        clock.advance(policy.session_ttl_s + 1)
    with when(f"DELETE /sessions/{doc['session']['id']} (expired)"):
        r = await gw.delete(f"/sessions/{doc['session']['id']}")
    with then("status 200 with a released_at", released_at={"actual": r.json().get("released_at")}):
        assert r.status_code == 200 and r.json()["released_at"]
    with then("the token on the data plane stays code session-expired"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
        check("code", err(r), "session-expired")
