"""GW-CRED-BOUNDARY — inbound auth stops here; the upstream credential starts here (specs/endpoints/anthropic-messages.md).

| description | Authorization | x-api-key | verdict |
|---|---|---|---|
| a bearer session token | Bearer gws_<valid> | — | session resolved |
| an x-api-key session token | — | gws_<valid> | session resolved |
| the bearer is consulted first | Bearer gws_<valid A> | gws_<valid B> | session A |
| no credential | — | — | 401 session-unknown |
| a token nobody minted | Bearer gws_AAAA... | — | 401 session-unknown |
| a real-looking key is not a session | Bearer sk-or-v1-FAKE... | — | 401 session-unknown; never forwarded; logged redacted |
| a released session's token | Bearer gws_<released> | — | 401 session-released |
| an expired session's token | Bearer gws_<expired> | — | 401 session-expired |
| a session whose credential went away | Bearer gws_<valid>, ref now a definitive miss | — | 401 credential-unresolved |
| a session whose credential read is failing | Bearer gws_<valid>, ref transient | — | 503 credential-transient |

| description | inbound header | reaches upstream |
|---|---|---|
| the inbound bearer is stripped | Authorization: Bearer gws_... | no (replaced by the rail credential) |
| the inbound x-api-key is stripped | x-api-key: gws_... | no (replaced on the Go anthropic leg; absent elsewhere) |
| hop-by-hop headers are stripped | Connection, Keep-Alive, Transfer-Encoding, TE, Trailer, Upgrade, Proxy-Authorization | no |
| content-type passes through | Content-Type: application/json | yes |
| an unknown vendor header passes through | x-foo: bar | yes |
| a credential-shaped value in a vendor header is refused | x-foo: Bearer sk-ant-oat-x | 502 header-refused, upstream not called |

| description | upstream behaviour | status | body | log |
|---|---|---|---|---|
| an upstream 401 never leaks | upstream-401 (body names the key) | 502 | upstream-auth envelope | upstream-auth <rail> 401, no body |
| an upstream 403 is the same class | upstream-403 | 502 | upstream-auth envelope | upstream-auth <rail> 403 |
"""

from __future__ import annotations

import logging

import pytest

from .conftest import ANTHROPIC_TOKEN, GO_KEY, OPENROUTER_KEY, bearer, err, open_session, rule

pytestmark = rule("GW-CRED-BOUNDARY")
REF = "platform-agents/platform-openrouter"

AUTH_ROWS = [
    ("a bearer session token", "bearer", "active", 200, None),
    ("an x-api-key session token", "x-api-key", "active", 200, None),
    ("the bearer is consulted first", "both", "active", 200, None),
    ("no credential", "none", "active", 401, "session-unknown"),
    ("a token nobody minted", "unminted", "active", 401, "session-unknown"),
    ("a real-looking key is not a session", "foreign", "active", 401, "session-unknown"),
    ("a released session's token", "bearer", "released", 401, "session-released"),
    ("an expired session's token", "bearer", "expired", 401, "session-expired"),
    ("a session whose credential went away", "bearer", "cred-missing", 401, "credential-unresolved"),
    ("a session whose credential read is failing", "bearer", "cred-transient", 503, "credential-transient"),
]


@pytest.mark.parametrize(("how", "state", "status", "code"), [r[1:] for r in AUTH_ROWS], ids=[r[0] for r in AUTH_ROWS])
async def test_inbound_auth(gw, app, upstreams, secrets, policy, clock, caplog, how, state, status, code):
    caplog.set_level(logging.INFO)
    a = await open_session(gw, role="worker", harness="goose", rail="openrouter", task="A")
    b = await open_session(gw, role="worker", harness="goose", rail="openrouter", task="B")
    if state == "released":
        await gw.delete(f"/sessions/{a['session']['id']}")
    elif state == "expired":
        clock.advance(policy.session_ttl_s + 1)
    elif state == "cred-missing":
        secrets.secrets.pop(REF)
        app.state.resolver.forget()
    elif state == "cred-transient":
        secrets.transient.add(REF)
        app.state.resolver.forget()
    headers = {
        "bearer": bearer(a),
        "x-api-key": {"x-api-key": a["session"]["token"]},
        "both": {**bearer(a), "x-api-key": b["session"]["token"]},
        "none": {},
        "unminted": {"authorization": "Bearer gws_" + "A" * 32},
        "foreign": {"authorization": "Bearer sk-or-v1-FAKEFAKEFAKE"},
    }[how]
    r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=headers)
    assert r.status_code == status, r.text
    if code:
        assert err(r) == code
        if how == "foreign":
            assert upstreams["openrouter"].calls == []
            assert any("session-unknown" in rec.getMessage() for rec in caplog.records)
            assert not any("FAKEFAKEFAKE" in rec.getMessage() for rec in caplog.records)
    else:
        served_a = (await gw.get(f"/sessions/{a['session']['id']}")).json()["requests"]
        served_b = (await gw.get(f"/sessions/{b['session']['id']}")).json()["requests"]
        assert (served_a, served_b) == (1, 0), "session A must have served, never B"


HEADER_ROWS = [
    ("the inbound bearer is stripped", {}, {"authorization": f"Bearer {OPENROUTER_KEY}"}, []),
    ("the inbound x-api-key is stripped", {"x-api-key": "<token>"}, {}, ["x-api-key"]),
    ("hop-by-hop headers are stripped", {"connection": "close", "keep-alive": "timeout=5", "te": "trailers", "trailer": "x", "upgrade": "h2c", "proxy-authorization": "Basic x"}, {}, ["keep-alive", "te", "trailer", "upgrade", "proxy-authorization", "transfer-encoding"]),
    ("content-type passes through", {"content-type": "application/json"}, {"content-type": "application/json"}, []),
    ("an unknown vendor header passes through", {"x-foo": "bar"}, {"x-foo": "bar"}, []),
]


@pytest.mark.parametrize(("inbound", "present", "absent"), [r[1:] for r in HEADER_ROWS], ids=[r[0] for r in HEADER_ROWS])
async def test_header_boundary(gw, upstreams, inbound, present, absent):
    doc = await open_session(gw, role="worker", harness="goose", rail="openrouter")
    token = doc["session"]["token"]
    headers = {**bearer(doc), **{k: (token if v == "<token>" else v) for k, v in inbound.items()}}
    r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=headers)
    assert r.status_code == 200, r.text
    seen = upstreams["openrouter"].calls[-1]["headers"]
    for k, v in present.items():
        assert seen.get(k) == v, (k, seen.get(k))
    for k in absent:
        assert k not in seen, (k, seen.get(k))
    assert seen.get("connection") != "close", "the inbound Connection header is the gateway's, not forwarded (the client stack owns its own)"
    assert token not in str(seen) and "gws_" not in str(seen)


async def test_credential_shaped_vendor_header_refused(gw, upstreams):
    """row: a credential-shaped value in a vendor header is refused"""
    doc = await open_session(gw, role="worker", harness="goose", rail="openrouter")
    r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers={**bearer(doc), "x-foo": "Bearer sk-ant-oat-x"})
    assert r.status_code == 502 and err(r) == "header-refused"
    assert upstreams["openrouter"].calls == []


UPSTREAM_ROWS = [("an upstream 401 never leaks", "upstream-401", 401), ("an upstream 403 is the same class", "upstream-403", 403)]


@pytest.mark.parametrize(("behaviour", "upstream_status"), [r[1:] for r in UPSTREAM_ROWS], ids=[r[0] for r in UPSTREAM_ROWS])
async def test_upstream_auth_never_leaks(gw, upstreams, caplog, behaviour, upstream_status):
    caplog.set_level(logging.INFO)
    upstreams["openrouter"].behaviour = behaviour
    doc = await open_session(gw, role="worker", harness="goose", rail="openrouter")
    r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    assert r.status_code == 502 and err(r) == "upstream-auth"
    assert "sk-ant-oat" not in r.text and "LEAK" not in r.text
    line = next(rec.getMessage() for rec in caplog.records if rec.getMessage().startswith("upstream-auth"))
    assert line.startswith(f"upstream-auth openrouter {upstream_status}")
    assert "LEAK" not in line and "sk-ant-oat" not in line
    for secret in (ANTHROPIC_TOKEN, OPENROUTER_KEY, GO_KEY):
        assert secret not in r.text
