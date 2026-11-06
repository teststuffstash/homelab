"""GW-CRED-BOUNDARY — inbound auth stops here; the upstream credential starts here
(specs/endpoints/anthropic-messages.md).

One parametrized case per table row: the argnames are the table's header cells (`name?` is
`expected_name`), the ids its description cells, the literals the page's Legend lines. World
`policy-default`, the fake upstream in the behaviour the `upstream` column names; unless a `rail`
column says otherwise the session is a goose worker's on the openrouter rail, and `<A>` / `<B>` are
the tokens of two such sessions A and B.
"""

from __future__ import annotations

import logging

import pytest

from ._rail_rows import NONE, headers_seen, inputs, oracle, parse_pairs
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

pytestmark = rule("GW-CRED-BOUNDARY")
RAIL = "openrouter"
PATH = "/openai/v1/chat/completions"
REF = "platform-agents/platform-openrouter"


async def _sessions_ab(gw) -> tuple[dict, dict]:
    with given("sessions A and B on rail openrouter (worker, harness goose)"):
        with quiet():  # arrange only — one summary instead of two exchanges
            a = await open_session(gw, role="worker", harness="goose", rail=RAIL, task="A")
            b = await open_session(gw, role="worker", harness="goose", rail=RAIL, task="B")
        attach_json("sessions A and B", {"A": a["session"]["id"], "B": b["session"]["id"], "rail": a["rail"]})
    return a, b


def _auth_headers(cell: str, a: dict, b: dict, header: str) -> dict:
    if cell == NONE:
        return {}
    value = cell.replace("<A>", a["session"]["token"]).replace("<B>", b["session"]["token"])
    return {header: value}


async def _served(gw, a: dict, b: dict) -> str:
    with quiet():  # the two GET /sessions reads; the verdict carries their requests values
        ra = (await gw.get(f"/sessions/{a['session']['id']}")).json()["requests"]
        rb = (await gw.get(f"/sessions/{b['session']['id']}")).json()["requests"]
    return "A" if (ra, rb) == (1, 0) else "B" if (ra, rb) == (0, 1) else NONE if (ra, rb) == (0, 0) else f"A {ra}, B {rb}"


# -- Which header carries the session token -------------------------------------------------------
TOKEN_ROWS = [  # description | upstream | authorization | x_api_key | status? | code? | served?
    ("a bearer session token", "upstream-ok", "Bearer <A>", NONE, 200, NONE, "A"),
    ("an x-api-key session token", "upstream-ok", NONE, "<A>", 200, NONE, "A"),
    ("the bearer is consulted first ⚖", "upstream-ok", "Bearer <A>", "<B>", 200, NONE, "A"),
    ("no credential", "upstream-ok", NONE, NONE, 401, "session-unknown", NONE),
    ("a token nobody minted", "upstream-ok", "Bearer gws_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", NONE, 401, "session-unknown", NONE),
    ("a real-looking key is not a session", "upstream-ok", "Bearer sk-or-v1-FAKEFAKEFAKE", NONE, 401, "session-unknown", NONE),
]


@pytest.mark.parametrize(("upstream", "authorization", "x_api_key", "expected_status", "expected_code", "expected_served"),
                         [r[1:] for r in TOKEN_ROWS], ids=[r[0] for r in TOKEN_ROWS])
async def test_inbound_token(gw, upstreams, caplog, upstream, authorization, x_api_key, expected_status, expected_code, expected_served):
    world(upstream=upstream)
    caplog.set_level(logging.INFO)
    a, b = await _sessions_ab(gw)
    headers = {**_auth_headers(authorization, a, b, "authorization"), **_auth_headers(x_api_key, a, b, "x-api-key")}
    with when(f"POST {PATH} · {inputs(upstream=upstream, authorization=authorization, x_api_key=x_api_key)}"):
        r = await gw.post(PATH, json={"messages": []}, headers=headers)
    then_eq("expected_status", r.status_code, expected_status, claim=f"status? = {expected_status}")
    then_eq("expected_code", err(r) if r.status_code != 200 else NONE, expected_code, claim=f"code? = {expected_code}")
    then_eq("expected_served", await _served(gw, a, b), expected_served, claim=f"served? = {expected_served}")
    if "sk-or-v1-FAKE" in authorization:
        msgs = [rec.getMessage() for rec in caplog.records]
        with then("the foreign key never reaches upstream; logged as session-unknown, its value never logged",
                  upstream_calls={"expected": 0, "actual": len(upstreams[RAIL].calls)}, log_lines=msgs):
            assert upstreams[RAIL].calls == []
            assert any("session-unknown" in m for m in msgs)
            assert not any("FAKEFAKEFAKE" in m for m in msgs)


# -- A session that can no longer serve -----------------------------------------------------------
STATE_ROWS = [  # description | upstream | state | status? | code?
    ("a released session's token", "upstream-ok", "released", 401, "session-released"),
    ("an expired session's token", "upstream-ok", "expired", 401, "session-expired"),
    ("a session whose credential went away", "upstream-ok", "credential ref a definitive miss", 401, "credential-unresolved"),
    ("a session whose credential read is failing", "upstream-ok", "credential read transient", 503, "credential-transient"),
]


@pytest.mark.parametrize(("upstream", "state", "expected_status", "expected_code"), [r[1:] for r in STATE_ROWS], ids=[r[0] for r in STATE_ROWS])
async def test_session_state(gw, app, secrets, policy, clock, upstream, state, expected_status, expected_code):
    world(upstream=upstream)
    a, _b = await _sessions_ab(gw)
    with given(f"state = {state}: session A"):
        if state == "released":
            await gw.delete(f"/sessions/{a['session']['id']}")
        elif state == "expired":
            clock.advance(policy.session_ttl_s + 1)
            attach_json("clock advanced past expires_at", {"advanced_s": policy.session_ttl_s + 1})
        elif state == "credential ref a definitive miss":
            secrets.secrets.pop(REF)
            app.state.resolver.forget()
            attach_json(f"secrets after: {REF} removed", sorted(secrets.secrets))
        else:
            secrets.transient.add(REF)
            app.state.resolver.forget()
            attach_json(f"secrets transient: {REF}", sorted(secrets.transient))
    with when(f"POST {PATH} with Authorization: Bearer <A> · {inputs(upstream=upstream, state=state)}"):
        r = await gw.post(PATH, json={"messages": []}, headers=bearer(a))
    then_eq("expected_status", r.status_code, expected_status, claim=f"status? = {expected_status}")
    then_eq("expected_code", err(r), expected_code, claim=f"code? = {expected_code}")


# -- What of the inbound reaches upstream ---------------------------------------------------------
HEADER_ROWS = [  # description | upstream | inbound | upstream_header?
    ("the inbound bearer is stripped", "upstream-ok", NONE, "Authorization: Bearer <OPENROUTER_API_KEY>"),
    ("the inbound x-api-key is stripped", "upstream-ok", "x-api-key: <session token>", "x-api-key: (absent)"),
    ("hop-by-hop headers are stripped", "upstream-ok",
     "Connection: close; Keep-Alive: timeout=5; TE: trailers; Trailer: x; Upgrade: h2c; Proxy-Authorization: Basic x",
     "Connection: (the gateway's own); Keep-Alive: (absent); TE: (absent); Trailer: (absent); Upgrade: (absent); Proxy-Authorization: (absent); Transfer-Encoding: (absent)"),
    ("content-type passes through", "upstream-ok", "Content-Type: application/json", "Content-Type: application/json"),
    ("an unknown vendor header passes through", "upstream-ok", "x-foo: bar", "x-foo: bar"),
]


@pytest.mark.parametrize(("upstream", "inbound", "expected_upstream_header"), [r[1:] for r in HEADER_ROWS], ids=[r[0] for r in HEADER_ROWS])
async def test_header_boundary(gw, upstreams, upstream, inbound, expected_upstream_header):
    world(upstream=upstream)
    with given("a session on rail openrouter (worker, harness goose)"):
        doc = await open_session(gw, role="worker", harness="goose", rail=RAIL)
    token = doc["session"]["token"]
    headers = {**bearer(doc), **{k.lower(): (token if v == "<session token>" else v) for k, v in parse_pairs(inbound)}}
    with when(f"POST {PATH} · {inputs(upstream=upstream, inbound=inbound)} (beside Authorization: Bearer <session token>)"):
        r = await gw.post(PATH, json={"messages": []}, headers=headers)
    then_eq("status", r.status_code, 200)
    seen = upstreams[RAIL].calls[-1]
    then_eq("expected_upstream_header", headers_seen(seen, expected_upstream_header, doc, inbound), expected_upstream_header,
            claim=f"upstream_header? = {expected_upstream_header}")
    with then("no session token (gws_) reaches upstream", upstream_headers={"actual": sorted(seen["headers"])}):
        assert token not in str(seen["headers"]) and "gws_" not in str(seen["headers"])


# -- A credential-shaped vendor header ------------------------------------------------------------
TRIPWIRE_ROWS = [  # description | upstream | inbound | status? | code? | upstream_calls?
    ("a credential-shaped value in a vendor header is refused", "upstream-ok", "x-foo: Bearer sk-ant-oat-x", 502, "header-refused", 0),
]


@pytest.mark.parametrize(("upstream", "inbound", "expected_status", "expected_code", "expected_upstream_calls"),
                         [r[1:] for r in TRIPWIRE_ROWS], ids=[r[0] for r in TRIPWIRE_ROWS])
async def test_credential_shaped_vendor_header_refused(gw, upstreams, upstream, inbound, expected_status, expected_code, expected_upstream_calls):
    world(upstream=upstream)
    with given("a session on rail openrouter (worker, harness goose)"):
        doc = await open_session(gw, role="worker", harness="goose", rail=RAIL)
    with when(f"POST {PATH} · {inputs(upstream=upstream, inbound=inbound)}"):
        r = await gw.post(PATH, json={"messages": []}, headers={**bearer(doc), **{k.lower(): v for k, v in parse_pairs(inbound)}})
    then_eq("expected_status", r.status_code, expected_status, claim=f"status? = {expected_status}")
    then_eq("expected_code", err(r), expected_code, claim=f"code? = {expected_code}")
    then_eq("expected_upstream_calls", len(upstreams[RAIL].calls), expected_upstream_calls, claim=f"upstream_calls? = {expected_upstream_calls}")


# -- An upstream 401/403 never relays its body ----------------------------------------------------
LEAK_ROWS = [  # description | upstream | status? | code? | upstream_body_relayed? | log_line_prefix?
    ("an upstream 401 never leaks", "upstream-401", 424, "upstream-auth", "no", "upstream-auth openrouter 401"),
    ("an upstream 403 naming a credential reason is the same class", "upstream-403", 424, "upstream-auth", "no", "upstream-auth openrouter 403"),
]


def _relayed(r, got) -> str:
    """`upstream_body_relayed?`: `yes` when the answer's body is the upstream's own bytes, else `no`."""
    return "yes" if got is not None and r.content == got[1] else "no"


@pytest.mark.parametrize(("upstream", "expected_status", "expected_code", "expected_upstream_body_relayed", "expected_log_line_prefix"),
                         [r[1:] for r in LEAK_ROWS], ids=[r[0] for r in LEAK_ROWS])
async def test_upstream_auth_never_leaks(gw, upstreams, caplog, upstream, expected_status, expected_code, expected_upstream_body_relayed,
                                         expected_log_line_prefix):
    world(upstream=upstream)
    caplog.set_level(logging.INFO)
    got = await oracle(upstreams[RAIL], "chat", "deepseek/deepseek-v4-flash", upstream)
    upstreams[RAIL].behaviour = upstream
    with given("a session on rail openrouter (worker, harness goose)"):
        doc = await open_session(gw, role="worker", harness="goose", rail=RAIL)
    with when(f"POST {PATH} · {inputs(upstream=upstream)}"):
        r = await gw.post(PATH, json={"messages": []}, headers=bearer(doc))
    then_eq("expected_status", r.status_code, expected_status, claim=f"status? = {expected_status}")
    then_eq("expected_code", err(r), expected_code, claim=f"code? = {expected_code}")
    with then(f"upstream_body_relayed? = {expected_upstream_body_relayed} (the envelope carries no upstream body and no credential value)",
              expected_upstream_body_relayed={"expected": expected_upstream_body_relayed, "actual": _relayed(r, got)}, body={"actual": r.text}):
        assert _relayed(r, got) == expected_upstream_body_relayed
        assert "sk-ant-oat" not in r.text and "LEAK" not in r.text
    line = next((rec.getMessage() for rec in caplog.records if rec.getMessage().startswith("upstream-auth")), "")
    with then(f"log_line_prefix? = {expected_log_line_prefix} (summarised: no body, no credential value)",
              expected_log_line_prefix={"expected": expected_log_line_prefix, "actual": line[: len(expected_log_line_prefix)]}, log_line={"actual": line}):
        assert line.startswith(expected_log_line_prefix)
        assert "LEAK" not in line and "sk-ant-oat" not in line


# -- A credential verdict against a refusal -------------------------------------------------------
async def _rejected_gauge(gw, rail: str) -> int:
    import re

    with quiet():
        text = (await gw.get("/metrics")).text
    m = re.search(rf'^gateway_credentials_rejected\{{rail="{rail}"\}} (\S+)$', text, re.M)
    return int(float(m.group(1))) if m else -1


KIND_ROWS = [  # description | rail | upstream | status? | code? | credentials_rejected? | upstream_body_relayed?
    ("an expired key is a credential verdict ⚖", "opencode", "upstream-401-key-expired", 424, "upstream-auth", 1, "no"),
    ("a policy refusal is not a credential verdict ⚖", "openrouter", "upstream-403-refused", 403, "upstream-refused", 0, "no"),
    ("an edge's error-code 403 is not a credential verdict ⚖", "opencode", "upstream-403-edge", 403, "upstream-edge-refused", 0, "no"),
    ("an edge's HTML 403 is not a credential verdict", "opencode", "upstream-403-html", 403, "upstream-edge-refused", 0, "no"),
]


@pytest.mark.parametrize(("rail", "upstream", "expected_status", "expected_code", "expected_credentials_rejected", "expected_upstream_body_relayed"),
                         [r[1:] for r in KIND_ROWS], ids=[r[0] for r in KIND_ROWS])
async def test_upstream_401_403_kind(gw, upstreams, rail, upstream, expected_status, expected_code, expected_credentials_rejected,
                                     expected_upstream_body_relayed):
    world(upstream=upstream)
    got = await oracle(upstreams[rail], "chat", "fixture/model", upstream)
    upstreams[rail].behaviour = upstream
    with given(f"rail = {rail}: a worker session there (harness goose)"):
        with quiet():
            doc = await open_session(gw, role="worker", harness="goose", rail=rail)
    with when(f"POST {PATH} · {inputs(rail=rail, upstream=upstream)}"):
        with quiet():
            r = await gw.post(PATH, json={"messages": []}, headers=bearer(doc))
        attach_json(f"gateway answer → {r.status_code}", {"status": r.status_code, "body": r.json()})
    then_eq("expected_status", r.status_code, expected_status, claim=f"status? = {expected_status}")
    then_eq("expected_code", err(r), expected_code, claim=f"code? = {expected_code}")
    with then(f"credentials_rejected? = {expected_credentials_rejected}: gateway_credentials_rejected{{rail=\"{rail}\"}}"):
        check("expected_credentials_rejected", await _rejected_gauge(gw, rail), expected_credentials_rejected)
    with then(f"upstream_body_relayed? = {expected_upstream_body_relayed} (neither the gate text nor the routing step crosses back)",
              expected_upstream_body_relayed={"expected": expected_upstream_body_relayed, "actual": _relayed(r, got)}, body={"actual": r.text}):
        assert _relayed(r, got) == expected_upstream_body_relayed
        assert "agentic harnesses" not in r.text and "Gate Free Endpoints" not in r.text and "Access denied" not in r.text
