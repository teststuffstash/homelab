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

from .conftest import bearer, err, open_session, rule

pytestmark = rule("GW-SESSIONS-RELEASE")


async def _active(gw, rail: str) -> int:
    text = (await gw.get("/metrics")).text
    return int(re.search(rf'^gateway_sessions_active\{{rail="{rail}"\}} (\d+)$', text, re.M).group(1))


async def test_release_active(gw):
    """row: release an active session"""
    doc = await open_session(gw)
    assert await _active(gw, "opencode") == 1
    r = await gw.delete(f"/sessions/{doc['session']['id']}")
    assert r.status_code == 200
    assert set(r.json()) == {"id", "released_at"} and r.json()["id"] == doc["session"]["id"]
    assert r.json()["released_at"].endswith("Z")
    assert await _active(gw, "opencode") == 0
    assert (await gw.get(f"/sessions/{doc['session']['id']}")).json()["released_at"] == r.json()["released_at"]


async def test_release_twice(gw, clock):
    """row: release twice"""
    doc = await open_session(gw)
    first = (await gw.delete(f"/sessions/{doc['session']['id']}")).json()
    clock.advance(5)
    second = await gw.delete(f"/sessions/{doc['session']['id']}")
    assert second.status_code == 200 and second.json()["released_at"] == first["released_at"]
    assert await _active(gw, "opencode") == 0


async def test_release_unknown(gw):
    """row: release an unknown id"""
    r = await gw.delete("/sessions/nope")
    assert r.status_code == 404 and err(r) == "session-not-found"


async def test_released_token_on_data_plane(gw):
    """row: a released token on the data plane"""
    doc = await open_session(gw)
    await gw.delete(f"/sessions/{doc['session']['id']}")
    r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    assert r.status_code == 401 and err(r) == "session-released"


async def test_expired_token_on_data_plane(gw, policy, clock):
    """row: an expired token on the data plane"""
    doc = await open_session(gw, role="reviewer", harness="claude")
    clock.advance(policy.session_ttl_s + 1)
    r = await gw.post("/anthropic/v1/messages", json={"messages": []}, headers=bearer(doc))
    assert r.status_code == 401 and err(r) == "session-expired"


async def test_expired_releases_slot(gw, policy, clock):
    """row: an expired session releases its slot"""
    for i in range(policy.rails["opencode"].max_sessions):
        await open_session(gw, task=f"fill-{i}")
    r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "t", "rail": "opencode"})
    assert r.json()["decision"] == "defer"
    clock.advance(policy.session_ttl_s + 1)
    assert (await open_session(gw, task="t", rail="opencode"))["rail"] == "opencode"


async def test_release_of_expired(gw, policy, clock):
    """row: release of an expired session"""
    doc = await open_session(gw)
    clock.advance(policy.session_ttl_s + 1)
    r = await gw.delete(f"/sessions/{doc['session']['id']}")
    assert r.status_code == 200 and r.json()["released_at"]
    r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    assert err(r) == "session-expired"
