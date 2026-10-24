"""GW-CODEX-CAPTURE — the four-boundary capture of a scoped codex ride (specs/endpoints/openai-responses.md
§The four-boundary capture), driven through the gateway against the fake backend of the `policy-codex`
world with the recorder scoped to tasks `capture-*`.

| description | task | the ride || the bundle (GET /sessions/{id}/capture) |
|---|---|---||---|
| a scoped ride is recorded at the four boundaries, in order | capture-t1 | upstream-ok || client-request, upstream-request, upstream-response, upstream-event…, client-response; t_ms ascending |
| an unscoped session has no capture | oracle-562-probe | upstream-ok || 404 capture-not-found |
| the recorder off by default captures nothing | capture-t1 (policy-codex app, no prefix) | upstream-ok || 404 capture-not-found |
| credentials never land in the capture | capture-t1 | the backend echoes a DUMMY-SECRET cookie || the bearer, the account id, the session token and the cookie value are absent; their names present, withheld |
| strings are lengths, vocabulary is kept, identifiers are aliases | capture-t1 | input text "hi", a function_call_output || `{len: 2}`, `type`/`role` verbatim, `call_id` → `call#1` equal across boundaries |
| the stream's events are recorded in order with their usage | capture-t1 | upstream-ok || event types in relay order, the terminal's usage numbers, `relayed_bytes` = the client's bytes |
| the capture is bounded; overflow marks the bundle incomplete and the ride is unaffected | capture-t1 | max 600 bytes || `complete: false`, a `truncated` marker, the ride 200 with the whole stream |
| a refused answer is captured as a refusal | capture-t1 | upstream-wrong-type || upstream-response carries `refusal`, client-response status 502 `upstream-content-type` |
| a 429 is captured as the rate limit it is | capture-t1 | upstream-429 || upstream-response 429, client-response 429 outcome rate-limited |
| a gateway-side refusal is captured as a refusal | capture-t1 | a body naming another model || client-request then client-response 403 outcome model-not-session — the gateway's own NO leaves a record |
| two requests in flight in one session persist back to back | capture-t1 | the first held until the second completes || both requests' records present, `request` ordinals 1 and 2, nothing replaced |
| the bundle is read under the session's lookup rule | capture-t1 | an unknown id; a token GET /sessions/{id} refuses || 404 session-not-found; the same status and code GET /sessions/{id} answers |
"""

from __future__ import annotations

import asyncio
import dataclasses
import json

import httpx
import pytest

from agent_gateway.app import create_app
from agent_gateway.codex import CodexBackend

from ._codex_world import CODEX_BASE, admitted, body, ride
from .conftest import ObservedAsyncClient, check, err, given, quiet, rule, then, then_eq, when, world

pytestmark = rule("GW-CODEX-CAPTURE")

PREFIX = "capture-"


@pytest.fixture
async def cap_app(settings, codex_policy, secrets, store, codex_transport, clock, codex_store, exchange, request):
    """The policy-codex app with the recorder scoped to `capture-*` (and a byte bound a row may shrink)."""
    max_bytes = getattr(request, "param", 262144)
    client = httpx.AsyncClient(transport=codex_transport)
    s = dataclasses.replace(settings, upstreams={**settings.upstreams, "codex": CODEX_BASE},
                            codex_capture_task_prefix=PREFIX, codex_capture_max_bytes=max_bytes)
    a = create_app(s, policy=codex_policy, source=secrets, store=store, client=client, clock=clock,
                   codex_backend=CodexBackend(codex_store, exchange))
    yield a
    await client.aclose()


@pytest.fixture
async def cap_gw(cap_app):
    async with ObservedAsyncClient(transport=httpx.ASGITransport(app=cap_app), base_url="http://gw") as c:
        yield c


async def _bundle(gw, doc, token=None):
    with when(f"GET /sessions/{doc['session']['id']}/capture"):
        return await gw.get(f"/sessions/{doc['session']['id']}/capture",
                            headers={"authorization": f"Bearer {token or doc['session']['token']}"})


def _by(records, boundary):
    return [r for r in records if r["boundary"] == boundary]


async def test_four_boundaries(cap_app, cap_gw, codex_upstream, clock):
    """row: a scoped ride is recorded at the four boundaries, in order"""
    world("policy-codex")
    doc = await admitted(cap_app, cap_gw, clock, task="capture-t1")
    r = await ride(cap_gw, doc, label="a scoped ride")
    assert r.status_code == 200
    b = (await _bundle(cap_gw, doc)).json()
    seq = [x["boundary"] for x in b["records"]]
    with then("the four boundaries in order, every event between upstream-response and client-response",
              boundaries=seq, complete=b["complete"], t_ms=[x["t_ms"] for x in b["records"]]):
        assert seq[0] == "client-request" and seq[1] == "upstream-request" and seq[2] == "upstream-response"
        assert seq[-1] == "client-response" and set(seq[3:-1]) == {"upstream-event"}
        assert b["complete"] is True and b["format"] == "codex-capture/1"
        ts = [x["t_ms"] for x in b["records"]]
        assert ts == sorted(ts)
        assert b["boundaries"] == ["client-request", "upstream-request", "upstream-response", "upstream-event", "client-response"]


async def test_unscoped(cap_app, cap_gw, clock):
    """row: an unscoped session has no capture"""
    world("policy-codex")
    doc = await admitted(cap_app, cap_gw, clock)  # the world's probe task — not capture-*
    await ride(cap_gw, doc, label="an unscoped ride")
    r = await _bundle(cap_gw, doc)
    with then("404 capture-not-found", status=r.status_code):
        then_eq("status", r.status_code, 404)
        then_eq("code", err(r), "capture-not-found")


async def test_off_by_default(codex_app, codex_gw, clock):
    """row: the recorder off by default captures nothing"""
    world("policy-codex")
    doc = await admitted(codex_app, codex_gw, clock, task="capture-t1")
    await ride(codex_gw, doc, label="a capture-* task under an app with no prefix")
    r = await _bundle(codex_gw, doc)
    with then("404 capture-not-found", status=r.status_code):
        then_eq("code", err(r), "capture-not-found")


async def test_no_credentials(cap_app, cap_gw, codex_upstream, clock):
    """row: credentials never land in the capture"""
    world("policy-codex")
    codex_upstream.response_headers = {"set-cookie": "sid=DUMMY-SECRET-cookie; Path=/", "x-request-id": "DUMMY-SECRET-reqid"}
    with given("the backend answers with a cookie and a request id (DUMMY-SECRET canaries)"):
        pass
    doc = await admitted(cap_app, cap_gw, clock, task="capture-t1")
    await ride(cap_gw, doc, label="the ride")
    text = (await _bundle(cap_gw, doc)).text
    b = json.loads(text)
    up = _by(b["records"], "upstream-request")[0]["headers"]
    down = _by(b["records"], "upstream-response")[0]["headers"]
    with then("names present, values withheld; no canary, no token anywhere in the bundle",
              upstream_request_headers=up, upstream_response_headers=down):
        assert "DUMMY-SECRET" not in text
        assert doc["session"]["token"] not in text
        assert up["authorization"]["withheld"] is True and up["chatgpt-account-id"]["withheld"] is True
        assert down["set-cookie"]["withheld"] is True and down["x-request-id"]["withheld"] is True
        assert up["content-type"] == "application/json" and up["accept"] == "text/event-stream"


async def test_sanitized_bodies(cap_app, cap_gw, codex_upstream, clock):
    """row: strings are lengths, vocabulary is kept, identifiers are aliases"""
    world("policy-codex")
    doc = await admitted(cap_app, cap_gw, clock, task="capture-t1")
    payload = body(input=[{"role": "user", "content": [{"type": "input_text", "text": "hi"}]},
                         {"type": "function_call_output", "call_id": "call_SECRETish123", "output": "the tool said this"}],
                   tools=[{"type": "function", "name": "rg", "parameters": {"type": "object", "properties": {"q": {"type": "string"}}}}])
    await ride(cap_gw, doc, payload, label="a continuation input with a function_call_output")
    b = (await _bundle(cap_gw, doc)).json()
    creq = _by(b["records"], "client-request")[0]["body"]
    ureq = _by(b["records"], "upstream-request")[0]["body"]
    with then("lengths for text, vocabulary verbatim, the call id aliased identically at both request boundaries",
              client_request_body=creq, upstream_request_body=ureq):
        assert creq["input"][0]["content"][0] == {"type": "input_text", "text": {"len": 2}}
        assert creq["input"][0]["role"] == "user"
        assert creq["input"][1]["call_id"] == "call#1" and creq["input"][1]["output"] == {"len": 18}
        assert ureq["input"][1]["call_id"] == "call#1"
        assert creq["tools"][0]["name"] == "rg" and creq["tools"][0]["parameters"]["properties"]["q"]["type"] == "string"
        assert "call_SECRETish123" not in json.dumps(b)
        assert creq["stream"] is True and creq["store"] is False and ureq["model"] == creq["model"]


async def test_events_in_order(cap_app, cap_gw, codex_upstream, clock):
    """row: the stream's events are recorded in order with their usage"""
    world("policy-codex")
    doc = await admitted(cap_app, cap_gw, clock, task="capture-t1")
    r = await ride(cap_gw, doc, label="the ride")
    b = (await _bundle(cap_gw, doc)).json()
    events = _by(b["records"], "upstream-event")
    types = [e["event"]["type"] for e in events if "event" in e]
    last = _by(b["records"], "client-response")[0]
    with then("event types in relay order, the terminal's usage kept as numbers, relayed bytes = the client's",
              types=types, client_response=last):
        assert types[0] == "response.created" and types[-1] == "response.completed"
        terminal = [e for e in events if e.get("event", {}).get("type") == "response.completed"][0]
        assert isinstance(terminal["event"]["response"]["usage"]["input_tokens"], int)
        assert last["relayed_bytes"] == len(r.content) and last["events"] == len(events)
        assert last["outcome"] == "completed" and last["status"] == 200 and last["usage"]["out"] >= 0
        assert [e["n"] for e in events] == list(range(1, len(events) + 1))


@pytest.mark.parametrize("cap_app", [600], indirect=True)
async def test_bounded(cap_app, cap_gw, codex_upstream, clock):
    """row: the capture is bounded; overflow marks the bundle incomplete and the ride is unaffected"""
    world("policy-codex")
    with given("the recorder bounded at 600 bytes per request"):
        pass
    doc = await admitted(cap_app, cap_gw, clock, task="capture-t1")
    r = await ride(cap_gw, doc, label="the ride")
    b = (await _bundle(cap_gw, doc)).json()
    with then("complete: false with one truncated marker; the ride relayed whole", complete=b["complete"],
              records=len(b["records"]), ride_status=r.status_code):
        assert r.status_code == 200 and "response.completed" in r.text
        assert b["complete"] is False
        assert sum(1 for x in b["records"] if x.get("truncated")) == 1


@pytest.mark.parametrize(("behaviour", "status", "outcome"), [("upstream-wrong-type", 502, "upstream-content-type"), ("upstream-429", 429, "rate-limited")],
                         ids=["a refused answer is captured as a refusal", "a 429 is captured as the rate limit it is"])
async def test_refusals_captured(cap_app, cap_gw, codex_upstream, clock, behaviour, status, outcome):
    world("policy-codex")
    doc = await admitted(cap_app, cap_gw, clock, task="capture-t1")
    codex_upstream.behaviour = behaviour
    r = await ride(cap_gw, doc, label=behaviour)
    b = (await _bundle(cap_gw, doc)).json()
    up = _by(b["records"], "upstream-response")[0]
    last = _by(b["records"], "client-response")[0]
    with then(f"upstream-response and client-response carry the {status}, outcome {outcome}", upstream_response=up, client_response=last, ride_status=r.status_code):
        assert r.status_code == status
        assert last["status"] == status and last["outcome"] == outcome
        assert up["refusal"] == (outcome if status == 502 else None)


async def test_lookup_rule(cap_app, cap_gw, clock):
    """row: the bundle is read under the session's lookup rule"""
    world("policy-codex")
    doc = await admitted(cap_app, cap_gw, clock, task="capture-t1")
    with quiet():
        await ride(cap_gw, doc, label="the ride")
    with when("GET /sessions/nope/capture; GET /sessions/{id} and GET /sessions/{id}/capture with a token that is no caller's (the world's control plane: observe)"):
        with quiet():  # three exchanges, one summary below (report hygiene)
            unknown = await cap_gw.get("/sessions/nope/capture", headers={"authorization": f"Bearer {doc['session']['token']}"})
            probe = await cap_gw.get(f"/sessions/{doc['session']['id']}", headers={"authorization": "Bearer not-a-caller-token"})
            bundle = await cap_gw.get(f"/sessions/{doc['session']['id']}/capture", headers={"authorization": "Bearer not-a-caller-token"})
    with then("an unknown id is 404 session-not-found; the capture answers exactly as the lookup does",
              unknown={"status": unknown.status_code, "code": err(unknown)},
              lookup=probe.status_code, capture=bundle.status_code):
        then_eq("unknown id", (unknown.status_code, err(unknown)), (404, "session-not-found"))
        check("same status as GET /sessions/{id}", bundle.status_code, probe.status_code)


async def test_gateway_refusal_captured(cap_app, cap_gw, codex_upstream, clock):
    """row: a gateway-side refusal is captured as a refusal"""
    world("policy-codex")
    doc = await admitted(cap_app, cap_gw, clock, task="capture-t1")
    r = await ride(cap_gw, doc, body(model="some-other-model"), label="a body naming another model")
    b = (await _bundle(cap_gw, doc)).json()
    seq = [x["boundary"] for x in b["records"]]
    last = b["records"][-1]
    with then("the gateway's own 403 leaves client-request + client-response, nothing upstream", ride_status=r.status_code,
              boundaries=seq, client_response=last):
        assert r.status_code == 403 and err(r) == "model-not-session"
        assert seq == ["client-request", "client-response"]
        assert last["status"] == 403 and last["outcome"] == "model-not-session"
        assert codex_upstream.calls == []


async def test_concurrent_requests(cap_app, cap_gw, codex_upstream, clock):
    """row: two requests in flight in one session persist back to back"""
    world("policy-codex")
    doc = await admitted(cap_app, cap_gw, clock, task="capture-t1")
    codex_upstream.hold_first = asyncio.Event()
    with given("the backend holds the FIRST request's answer until released"):
        pass
    with when("request 1 starts and waits; request 2 runs to completion; request 1 is released"):
        first = asyncio.ensure_future(ride(cap_gw, doc, label="request 1 (held)"))
        await asyncio.sleep(0)
        for _ in range(50):
            if len(codex_upstream.calls) >= 1:
                break
            await asyncio.sleep(0.01)
        second = await ride(cap_gw, doc, label="request 2 (completes first)")
        codex_upstream.hold_first.set()
        r1 = await first
    b = (await _bundle(cap_gw, doc)).json()
    by_req = {}
    for x in b["records"]:
        by_req.setdefault(x["request"], []).append(x["boundary"])
    with then("both requests' four boundaries are in the bundle under their own ordinal; nothing replaced",
              requests=b["requests"], per_request={k: {"records": len(v), "first": v[0], "last": v[-1]} for k, v in by_req.items()}):
        assert r1.status_code == 200 and second.status_code == 200
        assert sorted(by_req) == [1, 2]
        for v in by_req.values():
            assert v[0] == "client-request" and v[-1] == "client-response" and "upstream-response" in v
        assert b["complete"] is True and b["requests"] == 2

