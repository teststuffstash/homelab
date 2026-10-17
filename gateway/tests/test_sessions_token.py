"""GW-SESSIONS-TOKEN — the session token: shape, storage, lifetime (specs/endpoints/sessions.md).

| description | action | result |
|---|---|---|
| the token has the fixed shape | dispatch | token matches ^gws_[A-Za-z0-9_-]{32}$ |
| two dispatches never share a token | dispatch twice | tokens differ |
| the row holds a hash, not the token | dispatch, read the DB | token_hash = sha256 hex of the token; no column equals the token |
| GET returns the row without the token | dispatch -> GET /sessions/{id} | 200; exactly the 22 schema fields (caller, requests_incomplete, outcome, attempt, state and release_reason included); no token, no token_hash |
| GET on an unknown id | GET /sessions/nope | 404 session-not-found |
| expiry is the policy TTL | dispatch at T | expires_at = T + 14400 s |
| a request through the data plane is counted on the row | dispatch -> one upstream-ok call -> GET | requests = 1, tokens_in/tokens_out = the upstream usage |
| the x-api-key form is accepted on the data plane | x-api-key: gws_... | 200 |
"""

from __future__ import annotations

import hashlib
import re
import sqlite3

from .conftest import bearer, check, err, given, open_session, rule, then, when, world

pytestmark = rule("GW-SESSIONS-TOKEN")

TOKEN_RE = re.compile(r"^gws_[A-Za-z0-9_-]{32}$")
FIELDS = {"id", "stack", "role", "task", "round", "rail", "harness", "model", "created_at", "expires_at", "released_at", "requests", "tokens_in", "tokens_out", "tokens_cache_read", "tokens_cache_write", "caller", "requests_incomplete", "outcome", "attempt", "state", "release_reason"}


async def test_token_shape(gw):
    """row: the token has the fixed shape"""
    world()
    with when("POST /sessions (platform worker) → dispatch"):
        doc = await open_session(gw)
    with then(f"the token matches {TOKEN_RE.pattern}", token={"expected": TOKEN_RE.pattern, "actual": doc["session"]["token"]}):
        assert TOKEN_RE.match(doc["session"]["token"]), doc["session"]["token"]


async def test_tokens_differ(gw):
    """row: two dispatches never share a token"""
    world()
    with given("a first dispatch (task a)"):
        a = await open_session(gw, task="a")
    with when("POST /sessions a second dispatch (task b)"):
        b = await open_session(gw, task="b")
    with then("token and id differ between the two dispatches",
              token={"a": a["session"]["token"], "b": b["session"]["token"]}, id={"a": a["session"]["id"], "b": b["session"]["id"]}):
        assert a["session"]["token"] != b["session"]["token"] and a["session"]["id"] != b["session"]["id"]


async def test_db_holds_hash_only(gw, settings, store):
    """row: the row holds a hash, not the token"""
    world()
    with when("POST /sessions (platform worker) → dispatch"):
        doc = await open_session(gw)
    token = doc["session"]["token"]
    with then("the row's token_hash = sha256(token)"):
        check("token_hash", store.get_session(doc["session"]["id"]).token_hash, hashlib.sha256(token.encode()).hexdigest())
    with then("the token appears nowhere in the sqlite dump"):
        dump = "\n".join(sqlite3.connect(settings.db_path).iterdump())
        check("token in dump", token in dump, False)


async def test_get_session_excludes_token(gw):
    """row: GET returns the row without the token"""
    world()
    with given("a dispatched session"):
        doc = await open_session(gw)
    with when(f"GET /sessions/{doc['session']['id']}"):
        r = await gw.get(f"/sessions/{doc['session']['id']}")
    body = r.json()
    with then("status 200, body = exactly the row fields, no token in it"):
        check("status", r.status_code, 200)
        check("fields", sorted(body), sorted(FIELDS))
        check("token in body", doc["session"]["token"] in r.text, False)
    with then(f"released_at null, rail {doc['rail']}, requests 0"):
        check("(released_at, rail, requests)", (body["released_at"], body["rail"], body["requests"]), (None, doc["rail"], 0))


async def test_get_unknown(gw):
    """row: GET on an unknown id"""
    world()
    with when("GET /sessions/nope"):
        r = await gw.get("/sessions/nope")
    with then("status 404 with code session-not-found"):
        check("(status, code)", (r.status_code, err(r)), (404, "session-not-found"))


async def test_expiry_is_ttl(gw, policy, clock):
    """row: expiry is the policy TTL"""
    import datetime as dt

    world()
    with given("a dispatched session"):
        doc = await open_session(gw)
    with when(f"GET /sessions/{doc['session']['id']}"):
        row = (await gw.get(f"/sessions/{doc['session']['id']}")).json()
    created = dt.datetime.fromisoformat(row["created_at"].replace("Z", "+00:00"))
    expires = dt.datetime.fromisoformat(row["expires_at"].replace("Z", "+00:00"))
    with then("expires_at - created_at = policy session_ttl_s = 14400 s",
              ttl={"expected": 14400, "actual": (expires - created).total_seconds(), "policy": policy.session_ttl_s}):
        assert (expires - created).total_seconds() == policy.session_ttl_s == 14400
    with then("the dispatch's expires_at = the row's"):
        check("expires_at", doc["session"]["expires_at"], row["expires_at"])
    with then("created_at = the gateway clock"):
        check("created_at", created.timestamp(), clock())


async def test_data_plane_request_counted(gw):
    """row: a request through the data plane is counted on the row"""
    world(upstream="upstream-ok")
    with given("a session on rail opencode (platform worker)"):
        doc = await open_session(gw)
    with when("POST /openai/v1/chat/completions with the session token"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    with then("status = 200"):
        check("status", r.status_code, 200)
    with then("the row's (requests, tokens_in, tokens_out) = (1, 7, 3)"):
        row = (await gw.get(f"/sessions/{doc['session']['id']}")).json()
        check("(requests, tokens_in, tokens_out)", (row["requests"], row["tokens_in"], row["tokens_out"]), (1, 7, 3))


async def test_x_api_key_form(gw):
    """row: the x-api-key form is accepted on the data plane"""
    world(upstream="upstream-ok")
    with given("a session on rail opencode (platform worker)"):
        doc = await open_session(gw)
    with when("POST /openai/v1/chat/completions with x-api-key: <session token>"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers={"x-api-key": doc["session"]["token"]})
    with then("status = 200"):
        check("status", r.status_code, 200)
