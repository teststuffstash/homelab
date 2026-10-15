"""GW-SESSIONS-TOKEN — the session token: shape, storage, lifetime (specs/endpoints/sessions.md).

| description | action | result |
|---|---|---|
| the token has the fixed shape | dispatch | token matches ^gws_[A-Za-z0-9_-]{32}$ |
| two dispatches never share a token | dispatch twice | tokens differ |
| the row holds a hash, not the token | dispatch, read the DB | token_hash = sha256 hex of the token; no column equals the token |
| GET returns the row without the token | dispatch -> GET /sessions/{id} | 200; exactly the 14 schema fields; no token, no token_hash |
| GET on an unknown id | GET /sessions/nope | 404 session-not-found |
| expiry is the policy TTL | dispatch at T | expires_at = T + 14400 s |
| a request through the data plane is counted on the row | dispatch -> one upstream-ok call -> GET | requests = 1, tokens_in/tokens_out = the upstream usage |
| the x-api-key form is accepted on the data plane | x-api-key: gws_... | 200 |
"""

from __future__ import annotations

import hashlib
import re
import sqlite3

from .conftest import bearer, err, open_session, rule

pytestmark = rule("GW-SESSIONS-TOKEN")

TOKEN_RE = re.compile(r"^gws_[A-Za-z0-9_-]{32}$")
FIELDS = {"id", "stack", "role", "task", "round", "rail", "harness", "model", "created_at", "expires_at", "released_at", "requests", "tokens_in", "tokens_out"}


async def test_token_shape(gw):
    """row: the token has the fixed shape"""
    doc = await open_session(gw)
    assert TOKEN_RE.match(doc["session"]["token"]), doc["session"]["token"]


async def test_tokens_differ(gw):
    """row: two dispatches never share a token"""
    a = await open_session(gw, task="a")
    b = await open_session(gw, task="b")
    assert a["session"]["token"] != b["session"]["token"] and a["session"]["id"] != b["session"]["id"]


async def test_db_holds_hash_only(gw, settings, store):
    """row: the row holds a hash, not the token"""
    doc = await open_session(gw)
    token = doc["session"]["token"]
    row = store.get_session(doc["session"]["id"])
    assert row.token_hash == hashlib.sha256(token.encode()).hexdigest()
    dump = "\n".join(sqlite3.connect(settings.db_path).iterdump())
    assert token not in dump


async def test_get_session_excludes_token(gw):
    """row: GET returns the row without the token"""
    doc = await open_session(gw)
    r = await gw.get(f"/sessions/{doc['session']['id']}")
    assert r.status_code == 200
    body = r.json()
    assert set(body) == FIELDS, body
    assert doc["session"]["token"] not in r.text
    assert body["released_at"] is None and body["rail"] == doc["rail"] and body["requests"] == 0


async def test_get_unknown(gw):
    """row: GET on an unknown id"""
    r = await gw.get("/sessions/nope")
    assert r.status_code == 404 and err(r) == "session-not-found"


async def test_expiry_is_ttl(gw, policy, clock):
    """row: expiry is the policy TTL"""
    import datetime as dt

    doc = await open_session(gw)
    row = (await gw.get(f"/sessions/{doc['session']['id']}")).json()
    created = dt.datetime.fromisoformat(row["created_at"].replace("Z", "+00:00"))
    expires = dt.datetime.fromisoformat(row["expires_at"].replace("Z", "+00:00"))
    assert (expires - created).total_seconds() == policy.session_ttl_s == 14400
    assert doc["session"]["expires_at"] == row["expires_at"]
    assert created.timestamp() == clock()


async def test_data_plane_request_counted(gw):
    """row: a request through the data plane is counted on the row"""
    doc = await open_session(gw)
    r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    assert r.status_code == 200
    row = (await gw.get(f"/sessions/{doc['session']['id']}")).json()
    assert (row["requests"], row["tokens_in"], row["tokens_out"]) == (1, 7, 3)


async def test_x_api_key_form(gw):
    """row: the x-api-key form is accepted on the data plane"""
    doc = await open_session(gw)
    r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers={"x-api-key": doc["session"]["token"]})
    assert r.status_code == 200
