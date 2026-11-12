"""GW-CODEX-CAPTURE — the four-boundary capture of a scoped codex ride (specs/endpoints/openai-responses.md
§GW-CODEX-CAPTURE), driven through the gateway against the fake backend of the `policy-codex` world with
the recorder scoped to tasks `capture-*`. Argnames = each table's header, ids = its description cells.
"""

from __future__ import annotations

import asyncio
import dataclasses
import json

import httpx
import pytest

from agent_gateway.app import create_app
from agent_gateway.codex import CodexBackend

from ._codex_rows import expect, row, verdicts
from ._codex_world import CODEX_BASE, admitted, body
from ._codex_world import ride as ride_
from .conftest import ObservedAsyncClient, attach_json, err, given, quiet, rule, then, when, world

pytestmark = rule("GW-CODEX-CAPTURE")

DEFAULT_PREFIX = "capture-"
DEFAULT_MAX = 262144


@pytest.fixture
def prefix(request) -> str:
    return getattr(request, "param", DEFAULT_PREFIX)


@pytest.fixture
def max_bytes(request) -> int:
    return getattr(request, "param", DEFAULT_MAX)


@pytest.fixture
async def cap_app(settings, codex_policy, secrets, store, codex_transport, clock, codex_store, exchange, prefix, max_bytes):
    """The policy-codex app with the recorder scoped to `prefix` (`(unset)` = off) and bounded at `max_bytes`."""
    client = httpx.AsyncClient(transport=codex_transport)
    s = dataclasses.replace(settings, upstreams={**settings.upstreams, "codex": CODEX_BASE},
                            codex_capture_task_prefix="" if prefix == "(unset)" else prefix, codex_capture_max_bytes=max_bytes)
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


def _failed(checks: dict[str, bool], ok: str) -> str:
    """The cell's text when every check holds, else the names of the checks that did not."""
    bad = [name for name, held in checks.items() if not held]
    return ok if not bad else "failed: " + ", ".join(bad)


# -- which rides are recorded ---------------------------------------------------------------------

FOUR = "client-request, upstream-request, upstream-response, upstream-event…, client-response"


@pytest.mark.parametrize(("task", "prefix", "expected_bundle", "expected_boundaries"), [
    pytest.param("capture-t1", "capture-", "200, complete, format codex-capture/1, t_ms ascending", FOUR,
                 id="a scoped ride is recorded at the four boundaries, in order"),
    pytest.param("oracle-562-probe", "capture-", "404 capture-not-found", "—", id="an unscoped session has no capture"),
    pytest.param("capture-t1", "(unset)", "404 capture-not-found", "—", id="the recorder off by default captures nothing ⚖"),
], indirect=["prefix"])
async def test_which_rides(cap_app, cap_gw, clock, task, prefix, expected_bundle, expected_boundaries):
    world("policy-codex")
    row(task=task, prefix=prefix, expected_bundle=expected_bundle, expected_boundaries=expected_boundaries)
    with given(f"the recorder's prefix {prefix}; a codex session on task {task}"):
        doc = await admitted(cap_app, cap_gw, clock, task=task)
    r = await ride_(cap_gw, doc, label=f"task {task}")
    assert r.status_code == 200
    b = await _bundle(cap_gw, doc)
    if b.status_code != 200:
        verdicts(
            bundle=(f"{b.status_code} {err(b)}", expected_bundle),
            boundaries=("—", expected_boundaries),
        )
        return
    doc_b = b.json()
    seq = [x["boundary"] for x in doc_b["records"]]
    ts = [x["t_ms"] for x in doc_b["records"]]
    expect("bundle", f"{b.status_code}, {'complete' if doc_b['complete'] else 'incomplete'}, format {doc_b['format']}, "
                     f"t_ms {'ascending' if ts == sorted(ts) else 'unordered'}", expected_bundle)
    four = (seq[:3] == ["client-request", "upstream-request", "upstream-response"] and seq[-1] == "client-response"
            and set(seq[3:-1]) == {"upstream-event"}
            and doc_b["boundaries"] == ["client-request", "upstream-request", "upstream-response", "upstream-event", "client-response"])
    expect("boundaries", FOUR if four else ", ".join(seq), expected_boundaries)


# -- what a record holds --------------------------------------------------------------------------

CREDS_CELL = ("authorization, chatgpt-account-id, set-cookie, x-request-id: names kept, values withheld; "
              "content-type and accept kept; no canary, no session token anywhere")
STRINGS_CELL = 'text → {"len": 2}; type, role, name verbatim; call_id → call#1 at both request boundaries, the raw id nowhere'
EVENTS_CELL = ("event n 1…N in relay order, response.created … response.completed, the terminal's usage as numbers; "
               "client-response relayed_bytes = the client's bytes, events = N")
BOUNDED_CELL = "complete: false, one truncated marker; the ride 200 with the whole stream"


@pytest.mark.parametrize(("ride", "max_bytes", "expected_record"), [
    pytest.param("the backend echoes a DUMMY-SECRET cookie and request id", DEFAULT_MAX, CREDS_CELL, id="credentials never land in the capture ⚖"),
    pytest.param("input text hi, a function_call_output with call_id, a tool rg", DEFAULT_MAX, STRINGS_CELL,
                 id="strings are lengths, vocabulary is kept, identifiers are aliases ⚖"),
    pytest.param("upstream-ok", DEFAULT_MAX, EVENTS_CELL, id="the stream's events are recorded in order with their usage"),
    pytest.param("upstream-ok", 600, BOUNDED_CELL, id="the capture is bounded; overflow marks the bundle incomplete and the ride is unaffected ⚖"),
], indirect=["max_bytes"])
async def test_what_a_record_holds(cap_app, cap_gw, codex_upstream, clock, ride, max_bytes, expected_record):
    world("policy-codex")
    row(ride=ride, max_bytes=max_bytes, expected_record=expected_record)
    payload = None
    if ride.startswith("the backend echoes"):
        codex_upstream.response_headers = {"set-cookie": "sid=DUMMY-SECRET-cookie; Path=/", "x-request-id": "DUMMY-SECRET-reqid"}
    elif ride.startswith("input text hi"):
        payload = body(input=[{"role": "user", "content": [{"type": "input_text", "text": "hi"}]},
                              {"type": "function_call_output", "call_id": "call_SECRETish123", "output": "the tool said this"}],
                       tools=[{"type": "function", "name": "rg", "parameters": {"type": "object", "properties": {"q": {"type": "string"}}}}])
    with given(f"ride {ride}; the recorder bounded at max_bytes {max_bytes}"):
        doc = await admitted(cap_app, cap_gw, clock, task="capture-t1")
    r = await ride_(cap_gw, doc, payload, label=ride)
    text = (await _bundle(cap_gw, doc)).text
    b = json.loads(text)
    if ride.startswith("the backend echoes"):
        up = _by(b["records"], "upstream-request")[0]["headers"]
        down = _by(b["records"], "upstream-response")[0]["headers"]
        with then("the header records", upstream_request_headers=up, upstream_response_headers=down):
            pass
        record = _failed({
            "no canary": "DUMMY-SECRET" not in text, "no session token": doc["session"]["token"] not in text,
            "authorization withheld": up["authorization"]["withheld"] is True, "account id withheld": up["chatgpt-account-id"]["withheld"] is True,
            "set-cookie withheld": down["set-cookie"]["withheld"] is True, "x-request-id withheld": down["x-request-id"]["withheld"] is True,
            "content-type kept": up["content-type"] == "application/json", "accept kept": up["accept"] == "text/event-stream",
        }, CREDS_CELL)
    elif ride.startswith("input text hi"):
        creq = _by(b["records"], "client-request")[0]["body"]
        ureq = _by(b["records"], "upstream-request")[0]["body"]
        with then("the two request bodies as recorded", client_request_body=creq, upstream_request_body=ureq):
            pass
        record = _failed({
            "text is a length": creq["input"][0]["content"][0] == {"type": "input_text", "text": {"len": 2}},
            "role verbatim": creq["input"][0]["role"] == "user",
            "call_id aliased in the client request": creq["input"][1]["call_id"] == "call#1" and creq["input"][1]["output"] == {"len": 18},
            "call_id aliased in the upstream request": ureq["input"][1]["call_id"] == "call#1",
            "tool name and schema verbatim": creq["tools"][0]["name"] == "rg" and creq["tools"][0]["parameters"]["properties"]["q"]["type"] == "string",
            "the raw id nowhere": "call_SECRETish123" not in json.dumps(b),
            "booleans and the model stay": creq["stream"] is True and creq["store"] is False and ureq["model"] == creq["model"],
        }, STRINGS_CELL)
    elif max_bytes == 600:
        with then("the bundle", complete=b["complete"], records=len(b["records"]), ride_status=r.status_code):
            pass
        record = _failed({
            "the ride 200 with the whole stream": r.status_code == 200 and "response.completed" in r.text,
            "complete: false": b["complete"] is False,
            "one truncated marker": sum(1 for x in b["records"] if x.get("truncated")) == 1,
        }, BOUNDED_CELL)
    else:
        events = _by(b["records"], "upstream-event")
        types = [e["event"]["type"] for e in events if "event" in e]
        last = _by(b["records"], "client-response")[0]
        terminal = [e for e in events if e.get("event", {}).get("type") == "response.completed"]
        with then("the event records", types=types, client_response=last):
            pass
        record = _failed({
            "created first, completed last": bool(types) and types[0] == "response.created" and types[-1] == "response.completed",
            "usage as numbers": bool(terminal) and isinstance(terminal[0]["event"]["response"]["usage"]["input_tokens"], int),
            "relayed_bytes = the client's bytes": last["relayed_bytes"] == len(r.content),
            "events = N": last["events"] == len(events),
            "completed 200": last["outcome"] == "completed" and last["status"] == 200 and last["usage"]["out"] >= 0,
            "n 1…N": [e["n"] for e in events] == list(range(1, len(events) + 1)),
        }, EVENTS_CELL)
    expect("record", record, expected_record)


# -- refusals and concurrency ---------------------------------------------------------------------

@pytest.mark.parametrize(("ride", "expected_boundaries", "expected_client_response"), [
    pytest.param("upstream-wrong-type", "all four; upstream-response.refusal = upstream-content-type", "502 upstream-content-type",
                 id="a refused answer is captured as a refusal"),
    pytest.param("upstream-429", "all four", "429 rate-limited", id="a 429 is captured as the rate limit it is"),
    pytest.param("a body naming another model", "client-request, client-response; nothing upstream", "403 model-not-session",
                 id="a gateway-side refusal is captured as a refusal ⚖"),
    pytest.param("two requests, the first held until the second completes", "both requests' four, under request 1 and 2; requests: 2, complete",
                 "200, 200", id="two requests in flight in one session persist back to back"),
])
async def test_refusals_and_concurrency(cap_app, cap_gw, codex_upstream, clock, ride, expected_boundaries, expected_client_response):
    world("policy-codex")
    row(ride=ride, expected_boundaries=expected_boundaries, expected_client_response=expected_client_response)
    doc = await admitted(cap_app, cap_gw, clock, task="capture-t1")
    if ride.startswith("two requests"):
        codex_upstream.hold_first = asyncio.Event()
        with when(f"ride {ride}: request 1 starts and waits; request 2 runs to completion; request 1 is released"):
            with quiet():  # two rides, one summary attachment
                first = asyncio.ensure_future(ride_(cap_gw, doc, label="request 1 (held)"))
                await asyncio.sleep(0)
                for _ in range(50):
                    if len(codex_upstream.calls) >= 1:
                        break
                    await asyncio.sleep(0.01)
                second = await ride_(cap_gw, doc, label="request 2 (completes first)")
                codex_upstream.hold_first.set()
                r1 = await first
            attach_json("the two rides", {"request 1 (held)": r1.status_code, "request 2 (completed first)": second.status_code,
                                          "backend calls": len(codex_upstream.calls)})
        b = (await _bundle(cap_gw, doc)).json()
        by_req: dict[int, list[str]] = {}
        for x in b["records"]:
            by_req.setdefault(x["request"], []).append(x["boundary"])
        with then("both requests' records", requests=b["requests"], per_request={k: {"records": len(v), "first": v[0], "last": v[-1]} for k, v in by_req.items()}):
            pass
        both = sorted(by_req) == [1, 2] and all(v[0] == "client-request" and v[-1] == "client-response" and "upstream-response" in v for v in by_req.values())
        verdicts(
            boundaries=(f"both requests' four, under request 1 and 2; requests: {b['requests']}, {'complete' if b['complete'] else 'incomplete'}"
                              if both else f"per request: {by_req}", expected_boundaries),
            client_response=(f"{r1.status_code}, {second.status_code}", expected_client_response),
        )
        return
    payload = body(model="some-other-model") if ride.startswith("a body naming") else None
    if ride.startswith("upstream-"):
        codex_upstream.behaviour = ride
    r = await ride_(cap_gw, doc, payload, label=ride)
    b = (await _bundle(cap_gw, doc)).json()
    seq = [x["boundary"] for x in b["records"]]
    last = _by(b["records"], "client-response")[0]
    with then("the records", boundaries=seq, client_response=last, ride_status=r.status_code):
        pass
    if seq == ["client-request", "client-response"]:
        boundaries = "client-request, client-response; nothing upstream" if codex_upstream.calls == [] else "client-request, client-response; an upstream call"
    else:
        up = _by(b["records"], "upstream-response")[0]
        four = seq[:3] == ["client-request", "upstream-request", "upstream-response"] and seq[-1] == "client-response"
        boundaries = ("all four" if four else ", ".join(seq)) + (f"; upstream-response.refusal = {up['refusal']}" if up.get("refusal") else "")
    expect("boundaries", boundaries, expected_boundaries)
    assert last["status"] == r.status_code
    expect("client_response", f"{last['status']} {last['outcome']}", expected_client_response)


# -- who reads the bundle -------------------------------------------------------------------------

@pytest.mark.parametrize(("reads", "expected_answer"), [
    pytest.param("GET /sessions/nope/capture; GET /sessions/{id} and its /capture with a token that is no caller's",
                 "404 session-not-found; the capture's status = the lookup's status", id="the bundle is read under the session's lookup rule"),
])
async def test_who_reads(cap_app, cap_gw, clock, reads, expected_answer):
    world("policy-codex")
    row(reads=reads, expected_answer=expected_answer)
    doc = await admitted(cap_app, cap_gw, clock, task="capture-t1")
    with quiet():
        await ride_(cap_gw, doc, label="the ride")
    with when(f"reads {reads} (the world's control plane: observe)"):
        with quiet():  # three exchanges, one summary below (report hygiene)
            unknown = await cap_gw.get("/sessions/nope/capture", headers={"authorization": f"Bearer {doc['session']['token']}"})
            probe = await cap_gw.get(f"/sessions/{doc['session']['id']}", headers={"authorization": "Bearer not-a-caller-token"})
            bundle = await cap_gw.get(f"/sessions/{doc['session']['id']}/capture", headers={"authorization": "Bearer not-a-caller-token"})
    with then("the three answers", unknown={"status": unknown.status_code, "code": err(unknown)}, lookup=probe.status_code, capture=bundle.status_code):
        pass
    expect("answer", f"{unknown.status_code} {err(unknown)}; " + ("the capture's status = the lookup's status" if bundle.status_code == probe.status_code
                                                                  else f"capture {bundle.status_code} ≠ lookup {probe.status_code}"), expected_answer)
