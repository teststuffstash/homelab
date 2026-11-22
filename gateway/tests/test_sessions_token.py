"""GW-SESSIONS-TOKEN — the session token: shape, storage, lifetime (specs/endpoints/sessions.md
§The session → GW-SESSIONS-TOKEN). Header == argnames, description == id (tests/_rows.py)."""

from __future__ import annotations

import datetime as dt
import hashlib
import re
import sqlite3

import pytest

from ._rows import enter_world, expect, inputs
from .conftest import bearer, err, open_session, rule, when

pytestmark = rule("GW-SESSIONS-TOKEN")

TOKEN_RE = re.compile(r"^gws_[A-Za-z0-9_-]{32}$")
FIELDS = {"id", "stack", "role", "task", "round", "rail", "harness", "model", "created_at", "expires_at", "released_at", "requests",
          "tokens_in", "tokens_out", "tokens_cache_read", "tokens_cache_write", "caller", "requests_incomplete", "outcome", "attempt",
          "state", "release_reason"}

ROWS = [
    pytest.param("policy-default", "dispatch", "token matches ^gws_[A-Za-z0-9_-]{32}$", id="the token has the fixed shape"),
    pytest.param("policy-default", "dispatch twice", "tokens differ, ids differ", id="two dispatches never share a token"),
    pytest.param("policy-default", "dispatch, read the DB", "token_hash = sha256(token); the token nowhere in the dump", id="the row holds a hash, not the token"),
    pytest.param("policy-default", "dispatch, GET", "200; the 22 row fields; no token, no token_hash", id="GET returns the row without the token"),
    pytest.param("policy-default", "GET /sessions/nope", "404 session-not-found", id="GET on an unknown id"),
    pytest.param("policy-default", "dispatch, GET", "expires_at = created_at + 14400 s", id="expiry is the policy TTL"),
    pytest.param("policy-default · upstream-ok", "dispatch, one upstream-ok call, GET", "requests 1, tokens_in 7, tokens_out 3",
                 id="a request through the data plane is counted on the row"),
    pytest.param("policy-default · upstream-ok", "dispatch, x-api-key: the token on the data plane", "200",
                 id="the x-api-key form is accepted on the data plane"),
]


def _iso(s: str) -> dt.datetime:
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


@pytest.mark.parametrize(("world", "action", "expected_result"), ROWS)
async def test_the_token_and_the_row(gw, settings, store, policy, clock, world, action, expected_result):
    enter_world(world)
    inputs(action=action)
    if action == "dispatch":
        with when("POST /sessions (platform worker) → dispatch"):
            doc = await open_session(gw)
        tok = doc["session"]["token"]
        result = "token matches ^gws_[A-Za-z0-9_-]{32}$" if TOKEN_RE.match(tok) else f"token {tok!r} does not match"
    elif action == "dispatch twice":
        with when("POST /sessions twice (tasks a, b) → two dispatches"):
            a = await open_session(gw, task="a")
            b = await open_session(gw, task="b")
        result = ("tokens differ, ids differ" if a["session"]["token"] != b["session"]["token"] and a["session"]["id"] != b["session"]["id"]
                  else "a token or an id is shared")
    elif action == "dispatch, read the DB":
        with when("POST /sessions → dispatch; read the sessions row and the sqlite dump"):
            doc = await open_session(gw)
            tok = doc["session"]["token"]
            row = store.get_session(doc["session"]["id"])
            dump = "\n".join(sqlite3.connect(settings.db_path).iterdump())
        result = ("token_hash = sha256(token); the token nowhere in the dump"
                  if row.token_hash == hashlib.sha256(tok.encode()).hexdigest() and tok not in dump
                  else f"token_hash {row.token_hash!r}; token in dump: {tok in dump}")
    elif action == "dispatch, GET" and expected_result.startswith("200"):
        with when("POST /sessions → dispatch, then GET /sessions/{id}"):
            doc = await open_session(gw)
            r = await gw.get(f"/sessions/{doc['session']['id']}")
        body = r.json()
        result = (f"{r.status_code}; the {len(body)} row fields; no token, no token_hash"
                  if set(body) == FIELDS and doc["session"]["token"] not in r.text and "token_hash" not in body
                  else f"{r.status_code}; fields {sorted(body)}; token in body: {doc['session']['token'] in r.text}")
    elif action == "dispatch, GET":
        with when("POST /sessions → dispatch, then GET /sessions/{id}"):
            doc = await open_session(gw)
            row = (await gw.get(f"/sessions/{doc['session']['id']}")).json()
        ttl = (_iso(row["expires_at"]) - _iso(row["created_at"])).total_seconds()
        result = (f"expires_at = created_at + {ttl:.0f} s" if ttl == policy.session_ttl_s and doc["session"]["expires_at"] == row["expires_at"]
                  and _iso(row["created_at"]).timestamp() == clock() else f"ttl {ttl}; dispatch expires_at {doc['session']['expires_at']} vs row {row['expires_at']}")
    elif action == "GET /sessions/nope":
        with when("GET /sessions/nope"):
            r = await gw.get("/sessions/nope")
        result = f"{r.status_code} {err(r)}"
    elif action == "dispatch, one upstream-ok call, GET":
        with when("POST /sessions → dispatch; POST /openai/v1/chat/completions with the token (upstream-ok); GET /sessions/{id}"):
            doc = await open_session(gw)
            r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
            assert r.status_code == 200, r.text
            row = (await gw.get(f"/sessions/{doc['session']['id']}")).json()
        result = f"requests {row['requests']}, tokens_in {row['tokens_in']}, tokens_out {row['tokens_out']}"
    else:
        with when("POST /sessions → dispatch; POST /openai/v1/chat/completions with x-api-key: <the session token>"):
            doc = await open_session(gw)
            r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers={"x-api-key": doc["session"]["token"]})
        result = str(r.status_code)
    expect({"result": result}, result=expected_result)
