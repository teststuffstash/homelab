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
| an upstream 401 never leaks | upstream-401 (body names the key) | 424 | upstream-auth envelope | upstream-auth <rail> 401, no body |
| an upstream 403 naming a credential reason is the same class | upstream-403 (permission_error) | 424 | upstream-auth envelope | upstream-auth <rail> 403 |

| description | rail | upstream behaviour | status | code | the rail's credential |
|---|---|---|---|---|---|
| an expired key is a credential verdict | opencode | upstream-401-key-expired | 424 | upstream-auth | rejected (gateway_credentials_rejected{rail="opencode"} = 1) |
| a policy refusal is not a credential verdict | openrouter | upstream-403-refused | 403 | upstream-refused | not rejected (gateway_credentials_rejected{rail="openrouter"} = 0) |
| a refusal's body is not relayed either | openrouter | upstream-403-refused | 403 | upstream-refused | the body names neither the model's gate text nor the routing step |
| an edge's error-code 403 is not a credential verdict | opencode | upstream-403-edge | 403 | upstream-edge-refused | not rejected (gateway_credentials_rejected{rail="opencode"} = 0) |
| an edge's HTML 403 is not a credential verdict | opencode | upstream-403-html | 403 | upstream-edge-refused | not rejected (gateway_credentials_rejected{rail="opencode"} = 0) |
"""

from __future__ import annotations

import logging
import re

import pytest

from .conftest import (
    ANTHROPIC_TOKEN,
    GO_KEY,
    OPENROUTER_KEY,
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

HOW = {
    "bearer": "Authorization: Bearer <A's token>",
    "x-api-key": "x-api-key: <A's token>",
    "both": "Authorization: Bearer <A's token> + x-api-key: <B's token>",
    "none": "no credential header",
    "unminted": "Authorization: Bearer gws_AAAA… (never minted)",
    "foreign": "Authorization: Bearer sk-or-v1-FAKEFAKEFAKE",
}


@pytest.mark.parametrize(("how", "state", "status", "code"), [r[1:] for r in AUTH_ROWS], ids=[r[0] for r in AUTH_ROWS])
async def test_inbound_auth(gw, app, upstreams, secrets, policy, clock, caplog, how, state, status, code):
    world(upstream="upstream-ok")
    caplog.set_level(logging.INFO)
    with given("sessions A and B on rail openrouter (worker, harness goose)"):
        with quiet():  # arrange only — one summary instead of two exchanges
            a = await open_session(gw, role="worker", harness="goose", rail="openrouter", task="A")
            b = await open_session(gw, role="worker", harness="goose", rail="openrouter", task="B")
        attach_json("sessions A and B", {"A": a["session"]["id"], "B": b["session"]["id"], "rail": a["rail"]})
    with given(f"state: session A is {state}"):
        if state == "released":
            await gw.delete(f"/sessions/{a['session']['id']}")
        elif state == "expired":
            clock.advance(policy.session_ttl_s + 1)
            attach_json("clock advanced past expires_at", {"advanced_s": policy.session_ttl_s + 1})
        elif state == "cred-missing":
            secrets.secrets.pop(REF)
            app.state.resolver.forget()
            attach_json(f"secrets after: {REF} removed", sorted(secrets.secrets))
        elif state == "cred-transient":
            secrets.transient.add(REF)
            app.state.resolver.forget()
            attach_json(f"secrets transient: {REF}", sorted(secrets.transient))
    headers = {
        "bearer": bearer(a),
        "x-api-key": {"x-api-key": a["session"]["token"]},
        "both": {**bearer(a), "x-api-key": b["session"]["token"]},
        "none": {},
        "unminted": {"authorization": "Bearer gws_" + "A" * 32},
        "foreign": {"authorization": "Bearer sk-or-v1-FAKEFAKEFAKE"},
    }[how]
    with when(f"POST /openai/v1/chat/completions how={how} ({HOW[how]})"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=headers)
    then_eq("status", r.status_code, status, claim=f"status = {status}" + ("" if code else " (code None: served, no error envelope)"))
    if code:
        then_eq("code", err(r), code, claim=f"error code = {code}")
        if how == "foreign":
            msgs = [rec.getMessage() for rec in caplog.records]
            with then("the foreign key never reaches upstream; logged as session-unknown, its value never logged",
                      upstream_calls={"expected": 0, "actual": len(upstreams["openrouter"].calls)}, log_lines=msgs):
                assert upstreams["openrouter"].calls == []
                assert any("session-unknown" in m for m in msgs)
                assert not any("FAKEFAKEFAKE" in m for m in msgs)
    else:
        with then("session A served the request, never B: (A requests, B requests) = (1, 0)"):
            with quiet():  # the two GET /sessions reads; the verdict carries their requests values
                served_a = (await gw.get(f"/sessions/{a['session']['id']}")).json()["requests"]
                served_b = (await gw.get(f"/sessions/{b['session']['id']}")).json()["requests"]
            check("(A requests, B requests)", (served_a, served_b), (1, 0))


HEADER_ROWS = [
    ("the inbound bearer is stripped", {}, {"authorization": f"Bearer {OPENROUTER_KEY}"}, []),
    ("the inbound x-api-key is stripped", {"x-api-key": "<token>"}, {}, ["x-api-key"]),
    ("hop-by-hop headers are stripped", {"connection": "close", "keep-alive": "timeout=5", "te": "trailers", "trailer": "x", "upgrade": "h2c", "proxy-authorization": "Basic x"}, {}, ["keep-alive", "te", "trailer", "upgrade", "proxy-authorization", "transfer-encoding"]),
    ("content-type passes through", {"content-type": "application/json"}, {"content-type": "application/json"}, []),
    ("an unknown vendor header passes through", {"x-foo": "bar"}, {"x-foo": "bar"}, []),
]


@pytest.mark.parametrize(("inbound", "present", "absent"), [r[1:] for r in HEADER_ROWS], ids=[r[0] for r in HEADER_ROWS])
async def test_header_boundary(gw, upstreams, inbound, present, absent):
    world(upstream="upstream-ok")
    with given("a session on rail openrouter (worker, harness goose)"):
        doc = await open_session(gw, role="worker", harness="goose", rail="openrouter")
    token = doc["session"]["token"]
    headers = {**bearer(doc), **{k: (token if v == "<token>" else v) for k, v in inbound.items()}}
    with when(f"POST /openai/v1/chat/completions · inbound {inbound or '(bearer only)'}"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=headers)
    then_eq("status", r.status_code, 200)
    seen = upstreams["openrouter"].calls[-1]["headers"]
    with then(f"present upstream: {present or 'nothing extra'}; absent upstream: {absent or 'nothing listed'}",
              present={"expected": present, "actual": {k: seen.get(k) for k in present}},
              absent={"expected": absent, "actual_present": [k for k in absent if k in seen]}):
        for k, v in present.items():
            assert seen.get(k) == v, (k, seen.get(k))
        for k in absent:
            assert k not in seen, (k, seen.get(k))
    with then("the inbound Connection is not forwarded and no session token (gws_) reaches upstream",
              connection={"actual": seen.get("connection")}):
        assert seen.get("connection") != "close", "the inbound Connection header is the gateway's, not forwarded (the client stack owns its own)"
        assert token not in str(seen) and "gws_" not in str(seen)


async def test_credential_shaped_vendor_header_refused(gw, upstreams):
    """row: a credential-shaped value in a vendor header is refused"""
    world(upstream="upstream-ok")
    with given("a session on rail openrouter (worker, harness goose)"):
        doc = await open_session(gw, role="worker", harness="goose", rail="openrouter")
    with when("POST /openai/v1/chat/completions · inbound x-foo: Bearer sk-ant-oat-x"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers={**bearer(doc), "x-foo": "Bearer sk-ant-oat-x"})
    then_eq("status", r.status_code, 502)
    then_eq("code", err(r), "header-refused", claim="error code = header-refused")
    then_eq("upstream calls", len(upstreams["openrouter"].calls), 0, claim="no upstream call")


UPSTREAM_ROWS = [("an upstream 401 never leaks", "upstream-401", 401),
                 ("an upstream 403 naming a credential reason is the same class", "upstream-403", 403)]


@pytest.mark.parametrize(("behaviour", "upstream_status"), [r[1:] for r in UPSTREAM_ROWS], ids=[r[0] for r in UPSTREAM_ROWS])
async def test_upstream_auth_never_leaks(gw, upstreams, caplog, behaviour, upstream_status):
    world(upstream=behaviour)
    caplog.set_level(logging.INFO)
    upstreams["openrouter"].behaviour = behaviour
    with given("a session on rail openrouter (worker, harness goose)"):
        doc = await open_session(gw, role="worker", harness="goose", rail="openrouter")
    with when(f"POST /openai/v1/chat/completions (upstream answers {behaviour}, upstream_status {upstream_status})"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 424)
    with then("body = the upstream-auth envelope; no upstream body, no credential value", body={"actual": r.text}):
        assert err(r) == "upstream-auth"
        assert "sk-ant-oat" not in r.text and "LEAK" not in r.text
        for secret in (ANTHROPIC_TOKEN, OPENROUTER_KEY, GO_KEY):
            assert secret not in r.text
    with then(f"the log line reads upstream-auth openrouter {upstream_status}, summarised"):
        line = next(rec.getMessage() for rec in caplog.records if rec.getMessage().startswith("upstream-auth"))
        attach_json(f"verdict: log line upstream_status {upstream_status}", {"upstream_status": {"expected": upstream_status, "actual": line}})
        assert line.startswith(f"upstream-auth openrouter {upstream_status}")
        assert "LEAK" not in line and "sk-ant-oat" not in line


async def _rejected_gauge(gw, rail: str) -> float:
    text = (await gw.get("/metrics")).text
    m = re.search(rf'^gateway_credentials_rejected\{{rail="{rail}"\}} (\S+)$', text, re.M)
    attach_json(f"sample: gateway_credentials_rejected{{rail={rail}}}", {"line": m.group(0) if m else None})
    return float(m.group(1)) if m else -1


KIND_ROWS = [
    ("an expired key is a credential verdict", "opencode", "upstream-401-key-expired", 424, "upstream-auth", 1),
    ("a policy refusal is not a credential verdict", "openrouter", "upstream-403-refused", 403, "upstream-refused", 0),
    ("an edge's error-code 403 is not a credential verdict", "opencode", "upstream-403-edge", 403, "upstream-edge-refused", 0),
    ("an edge's HTML 403 is not a credential verdict", "opencode", "upstream-403-html", 403, "upstream-edge-refused", 0),
]


@pytest.mark.parametrize(("rail", "behaviour", "status", "code", "rejected"), [r[1:] for r in KIND_ROWS], ids=[r[0] for r in KIND_ROWS])
async def test_upstream_401_403_kind(gw, upstreams, rail, behaviour, status, code, rejected):
    world(upstream=behaviour)
    upstreams[rail].behaviour = behaviour
    with given(f"rail = {rail}: a worker session there (harness goose)"):
        doc = await open_session(gw, role="worker", harness="goose", rail=rail)
    with when(f"POST /openai/v1/chat/completions (upstream answers {behaviour})"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, status)
    then_eq("code", err(r), code, claim=f"error code = {code}")
    with then(f"the rail's credential: gateway_credentials_rejected{{rail=\"{rail}\"}} = {rejected}"):
        check(f"gateway_credentials_rejected{{rail={rail}}}", await _rejected_gauge(gw, rail), rejected)


async def test_refusal_body_not_relayed(gw, upstreams):
    """row: a refusal's body is not relayed either"""
    world(upstream="upstream-403-refused")
    upstreams["openrouter"].behaviour = "upstream-403-refused"
    with given("a worker session on openrouter (harness goose)"):
        doc = await open_session(gw, role="worker", harness="goose", rail="openrouter")
    with when("POST /openai/v1/chat/completions (upstream answers upstream-403-refused)"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 403)
    with then("the body is the upstream-refused envelope; neither the gate text nor the routing step crosses back", body={"actual": r.text}):
        assert err(r) == "upstream-refused"
        assert "agentic harnesses" not in r.text and "Gate Free Endpoints" not in r.text
