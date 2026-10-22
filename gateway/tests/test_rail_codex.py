"""GW-RAIL-CODEX — the codex rail's wire on POST /openai/v1/responses (specs/endpoints/openai-responses.md).

World `policy-codex` (specs/worlds/policy-codex.json) with the codex fake upstream and the FAKE
credential store (tests/_codex_world.py); the relay rows drive `responses.relay` directly.
Ported from experiments/codex-rail/test_adapter.py + test_composed.py (FU-270).

The request boundary:

| description | inbound | status | code | upstream called |
|---|---|---|---|---|
| a streaming, store-off, array-input request lands | stream true, store false, input [..], model fixture-model | 200 | — | once |
| an absent model is filled with the wire id | no model | 200 | — | once, model fixture-model |
| another model is refused | model gpt-other | 403 | model-not-session | no |
| a non-streaming request is refused | stream false | 400 | responses-mode-unsupported | no |
| server-side storage is refused | store true | 400 | responses-mode-unsupported | no |
| a string input is refused | input "hi" | 400 | responses-input-invalid | no |
| a body that is not a JSON object | [] | 400 | malformed-body | no |
| no session token | no Authorization | 401 | session-unknown | no |
| a codex session on the chat path | POST /openai/v1/chat/completions | 501 | dialect-unsupported-on-rail | no |
| a non-codex session on the responses path | an opencode worker session | 501 | dialect-unsupported-on-rail | no |

Header replacement:

| description | inbound header | upstream header |
|---|---|---|
| the session token becomes the rail's access token | Authorization: Bearer gws_... | authorization: Bearer <rotated access token> |
| the account comes from the credential, never the caller | ChatGPT-Account-ID: attacker | chatgpt-account-id: dummy-account |
| no inbound header crosses | Cookie, x-api-key, x-foo, User-Agent, OpenAI-Beta | none; exactly the six (+ host, content-length, connection) |
| the stream is asked for unencoded | Accept-Encoding: gzip | accept-encoding: identity, accept: text/event-stream |

Streams and usage:

| description | upstream behaviour | client bytes | outcome | recorded (status, in, cache_read, cache_write, out) |
|---|---|---|---|---|
| a completed stream relays byte-unchanged and counts once | upstream-ok | identical | completed | (200, 7, 0, 0, 3) |
| cached input is its own class | upstream-ok-cached | identical | completed | (200, 12, 300, 0, 7) |
| a second terminal event never replaces usage | upstream-stream-duplicate | identical | completed | (200, 7, 0, 0, 3) |
| a failed terminal is not a completion | upstream-stream-failed | identical | failed | (200, 7, 0, 0, 3) |
| an incomplete terminal is not a completion | upstream-stream-incomplete | identical | incomplete | (200, 7, 0, 0, 3) |
| EOF without a terminal is truncation | upstream-stream-truncated | identical | truncated | (502, 0, 0, 0, 0) |
| an invalid event ends the stream before its bytes | upstream-stream-invalid | a prefix of the events before it, never it | protocol-error | (502, 0, 0, 0, 0) |

Upstream failures:

| description | upstream behaviour | status | body | upstream calls |
|---|---|---|---|---|
| an upstream 401 is typed and hidden | upstream-401 | 502 | upstream-auth | 1 |
| an upstream 403 is the same class | upstream-403 | 502 | upstream-auth | 1 |
| a rate limit passes through | upstream-429 | 429 | the upstream body, retry-after 30 | 1 |
| an upstream 5xx is typed | upstream-500 | 502 | upstream-http-error | 1 |
| a redirect is never followed | upstream-302 | 502 | upstream-http-error | 1 |
| a non-SSE 200 is refused | upstream-wrong-type | 502 | upstream-content-type | 1 |
| a refused answer is captured: content-type, header names, a bounded preview | upstream-wrong-type / upstream-500 | the ERROR line carries them | — | 1 |
| an auth refusal's body is never read, not even into the log | upstream-401 | the ERROR line says <not read: auth>; the body's marker is nowhere | — | 1 |
| an unreachable upstream is typed | upstream-down | 502 | upstream-unreachable | 0 |
| a read past the read timeout (WIP: clock-faked) | upstream-slow | 504 | upstream-timeout | 0 |

The relay seam:

| description | chunks | outcome | bytes out | upstream closes |
|---|---|---|---|---|
| every byte split of a CRLF stream parses | heartbeat + completed, CRLF, every split | completed 7/3 | identical | 1 |
| a multi-line data field is one event | two data: lines, one byte per chunk | completed | identical | 1 |
| terminal usage after 4 MiB of deltas is counted | 100000 deltas + terminal | completed 7/3 | identical | 1 |
| malformed usage is unknown, not zero | input_tokens true, output_tokens -1 | completed, unknown | identical | 1 |
| an oversized event is refused | one event over the bound | protocol-error | none | 1 |
| a completed event with another status is invalid | completed with status failed | protocol-error | none | 1 |
| [DONE] alone is truncation | data: [DONE] | truncated | identical | 1 |
| a non-object event is invalid | data: [] | protocol-error | none | 1 |
| a transport fault mid-stream is sanitised | chunk, then raise | transport-error | first chunk | 1 |
| a cancelled download closes upstream without draining | consumer stops after chunk 1 | cancelled | first chunk | 1 |
"""

from __future__ import annotations

import json

import pytest

from agent_gateway import responses

from ._codex_world import (
    ACCOUNT,
    WIRE_MODEL,
    admitted,
    body,
    ride,
)
from .conftest import check, err, given, open_session, rule, then, then_eq, when, world

pytestmark = rule("GW-RAIL-CODEX")

BOUNDARY_ROWS = [
    ("a streaming, store-off, array-input request lands", {}, 200, None, 1),
    ("an absent model is filled with the wire id", {"model": None}, 200, None, 1),
    ("another model is refused", {"model": "gpt-other"}, 403, "model-not-session", 0),
    ("a non-streaming request is refused", {"stream": False}, 400, "responses-mode-unsupported", 0),
    ("server-side storage is refused", {"store": True}, 400, "responses-mode-unsupported", 0),
    ("a string input is refused", {"input": "hi"}, 400, "responses-input-invalid", 0),
]


async def _admitted(app, gw, clock) -> dict:
    return await admitted(app, gw, clock)


@pytest.mark.parametrize(("over", "status", "code", "calls"), [r[1:] for r in BOUNDARY_ROWS], ids=[r[0] for r in BOUNDARY_ROWS])
async def test_request_boundary(codex_app, codex_gw, codex_upstream, clock, over, status, code, calls):
    world("policy-codex", "upstream-ok")
    doc = await _admitted(codex_app, codex_gw, clock)
    payload = {k: v for k, v in body(**over).items() if v is not None}
    r = await ride(codex_gw, doc, payload, label=f"over={over}")
    then_eq("status", r.status_code, status)
    if code:
        then_eq("code", err(r), code, claim=f"error code = {code}")
    then_eq("upstream calls", len(codex_upstream.calls), calls)
    if calls:
        then_eq("upstream body model", codex_upstream.calls[-1]["body"]["model"], WIRE_MODEL)


async def test_not_an_object(codex_app, codex_gw, codex_upstream, clock):
    """row: a body that is not a JSON object"""
    world("policy-codex", "upstream-ok")
    doc = await _admitted(codex_app, codex_gw, clock)
    with when("POST /openai/v1/responses body []"):
        r = await codex_gw.post("/openai/v1/responses", json=[], headers={"authorization": f"Bearer {doc['session']['token']}"})
    then_eq("(status, code)", (r.status_code, err(r)), (400, "malformed-body"))
    then_eq("upstream calls", len(codex_upstream.calls), 0)


async def test_no_token(codex_gw, codex_upstream):
    """row: no session token"""
    world("policy-codex", "upstream-ok")
    with when("POST /openai/v1/responses with no Authorization"):
        r = await codex_gw.post("/openai/v1/responses", json=body())
    then_eq("(status, code)", (r.status_code, err(r)), (401, "session-unknown"))
    then_eq("upstream calls", len(codex_upstream.calls), 0)


async def test_codex_session_on_chat(codex_app, codex_gw, codex_upstream, clock):
    """row: a codex session on the chat path"""
    world("policy-codex", "upstream-ok")
    doc = await _admitted(codex_app, codex_gw, clock)
    with when("POST /openai/v1/chat/completions with the codex session token"):
        r = await codex_gw.post("/openai/v1/chat/completions", json={"messages": []}, headers={"authorization": f"Bearer {doc['session']['token']}"})
    then_eq("(status, code)", (r.status_code, err(r)), (501, "dialect-unsupported-on-rail"))
    then_eq("upstream calls", len(codex_upstream.calls), 0)


async def test_other_session_on_responses(codex_gw, codex_upstream):
    """row: a non-codex session on the responses path"""
    world("policy-codex", "upstream-ok")
    with given("an opencode worker session"):
        doc = await open_session(codex_gw, role="worker", harness="opencode")
    r = await ride(codex_gw, doc)
    then_eq("(status, code)", (r.status_code, err(r)), (501, "dialect-unsupported-on-rail"))
    then_eq("upstream calls", len(codex_upstream.calls), 0)


EXACT_HEADERS = {"authorization", "chatgpt-account-id", "content-type", "accept", "accept-encoding", "user-agent",
                 "host", "content-length", "connection"}


async def test_headers(codex_app, codex_gw, codex_upstream, exchange, clock):
    """row: the session token becomes the rail's access token"""
    world("policy-codex", "upstream-ok")
    doc = await _admitted(codex_app, codex_gw, clock)
    r = await ride(codex_gw, doc)
    then_eq("status", r.status_code, 200)
    sent = codex_upstream.calls[-1]["headers"]
    # expected: the rotation the fake exchange returns (the stored token is 1 s from expiry, margin 30 s)
    then_eq("upstream authorization", sent.get("authorization"), "Bearer " + exchange.rotated.access_token)
    then_eq("exchanges", exchange.calls, 1)


HEADER_ROWS = [
    ("the account comes from the credential, never the caller", {"ChatGPT-Account-ID": "attacker"}, {"chatgpt-account-id": ACCOUNT}),
    ("no inbound header crosses", {"Cookie": "DUMMY-SECRET", "x-api-key": "DUMMY-SECRET", "x-foo": "bar", "User-Agent": "codex_exec/0.161.0", "OpenAI-Beta": "responses=v1"},
     {"cookie": None, "x-api-key": None, "x-foo": None, "user-agent": "agent-gateway", "openai-beta": None}),
    ("the stream is asked for unencoded", {"Accept-Encoding": "gzip"}, {"accept-encoding": "identity", "accept": "text/event-stream"}),
]


@pytest.mark.parametrize(("inbound", "expect"), [r[1:] for r in HEADER_ROWS], ids=[r[0] for r in HEADER_ROWS])
async def test_header_rows(codex_app, codex_gw, codex_upstream, clock, inbound, expect):
    world("policy-codex", "upstream-ok")
    doc = await _admitted(codex_app, codex_gw, clock)
    r = await ride(codex_gw, doc, headers=inbound)
    then_eq("status", r.status_code, 200)
    sent = {k.lower(): v for k, v in codex_upstream.calls[-1]["headers"].items()}
    got = {k: sent.get(k) for k in expect}
    with then("upstream headers " + ", ".join(f"{k} = {v}" for k, v in expect.items()), expect={"expected": expect, "actual": got}):
        assert got == expect
    with then(f"the upstream header set is exactly {sorted(EXACT_HEADERS)}", names={"expected": sorted(EXACT_HEADERS), "actual": sorted(sent)}):
        assert set(sent) == EXACT_HEADERS


STREAM_ROWS = [
    # expected recorded tuples from the fake's usage (tests/_codex_world.py): ok = 7 in / 3 out, cached 0;
    # cached = input 312 incl. cached 300 → in 12, cache_read 300, out 7; no cache-write class on this wire.
    ("a completed stream relays byte-unchanged and counts once", "upstream-ok", "completed", (200, 7, 0, 0, 3)),
    ("cached input is its own class", "upstream-ok-cached", "completed", (200, 12, 300, 0, 7)),
    ("a second terminal event never replaces usage", "upstream-stream-duplicate", "completed", (200, 7, 0, 0, 3)),
    ("a failed terminal is not a completion", "upstream-stream-failed", "failed", (200, 7, 0, 0, 3)),
    ("an incomplete terminal is not a completion", "upstream-stream-incomplete", "incomplete", (200, 7, 0, 0, 3)),
    ("EOF without a terminal is truncation", "upstream-stream-truncated", "truncated", (502, 0, 0, 0, 0)),
    ("an invalid event ends the stream before its bytes", "upstream-stream-invalid", "protocol-error", (502, 0, 0, 0, 0)),
]


@pytest.mark.parametrize(("behaviour", "outcome", "recorded"), [r[1:] for r in STREAM_ROWS], ids=[r[0] for r in STREAM_ROWS])
async def test_streams(codex_app, codex_gw, codex_upstream, store, clock, caplog, behaviour, outcome, recorded):
    world("policy-codex", behaviour)
    from ._codex_world import BEHAVIOURS

    _, _, _, chunks = BEHAVIOURS[behaviour]()
    full = b"".join(chunks)
    invalid = behaviour == "upstream-stream-invalid"
    # the invalid stream: whatever the transport's chunking, the client gets a prefix of the two valid
    # events before the bad one, and never the bad one's bytes (it is fed to the parser before it is sent)
    expected_bytes = b"".join(chunks[:2]) if invalid else full
    doc = await _admitted(codex_app, codex_gw, clock)
    codex_upstream.behaviour = behaviour
    caplog.set_level("INFO", logger="gateway.codex")
    r = await ride(codex_gw, doc, label=behaviour)
    with then(f"status 200; client bytes = {'a prefix of the events before the invalid one, never it' if invalid else 'the upstream bytes, identical'}",
              status={"expected": 200, "actual": r.status_code},
              bytes={"expected_len": len(expected_bytes), "actual_len": len(r.content)}):
        assert r.status_code == 200
        if invalid:
            assert expected_bytes.startswith(r.content) and b"not-json" not in r.content
        else:
            assert r.content == expected_bytes
    with then(f"outcome = {outcome} (the log line)"):
        lines = [rec.getMessage() for rec in caplog.records if rec.name == "gateway.codex" and "outcome=" in rec.getMessage()]
        check("outcome", lines[-1].split("outcome=")[1].split()[0], outcome)
    with then(f"recorded (status, in, cache_read, cache_write, out) = {recorded}, on the session's one request"):
        req = store.requests_for(doc["session"]["id"])[-1]
        row = store.get_session(doc["session"]["id"])
        check("recorded", (req["status"], req["tokens_in"], req["tokens_cache_read"], req["tokens_cache_write"], req["tokens_out"], row.requests),
              (*recorded, 1))


FAILURE_ROWS = [
    ("an upstream 401 is typed and hidden", "upstream-401", 502, "upstream-auth", 1),
    ("an upstream 403 is the same class", "upstream-403", 502, "upstream-auth", 1),
    ("an upstream 5xx is typed", "upstream-500", 502, "upstream-http-error", 1),
    ("a redirect is never followed", "upstream-302", 502, "upstream-http-error", 1),
    ("a non-SSE 200 is refused", "upstream-wrong-type", 502, "upstream-content-type", 1),
]


@pytest.mark.parametrize(("behaviour", "status", "code", "calls"), [r[1:] for r in FAILURE_ROWS], ids=[r[0] for r in FAILURE_ROWS])
async def test_upstream_failures(codex_app, codex_gw, codex_upstream, store, clock, behaviour, status, code, calls):
    world("policy-codex", behaviour)
    doc = await _admitted(codex_app, codex_gw, clock)
    codex_upstream.behaviour = behaviour
    r = await ride(codex_gw, doc, label=behaviour)
    then_eq("(status, code)", (r.status_code, err(r)), (status, code))
    with then("the upstream body never reaches the client (no LEAK / DUMMY-SECRET marker)", body={"actual": r.text}):
        assert "LEAK" not in r.text and "DUMMY-SECRET" not in r.text
    then_eq("(upstream calls, recorded status)", (len(codex_upstream.calls), store.requests_for(doc["session"]["id"])[-1]["status"]),
            (calls, status))


async def test_rate_limit(codex_app, codex_gw, codex_upstream, clock):
    """row: a rate limit passes through"""
    world("policy-codex", "upstream-429")
    doc = await _admitted(codex_app, codex_gw, clock)
    codex_upstream.behaviour = "upstream-429"
    r = await ride(codex_gw, doc, label="upstream-429")
    then_eq("status", r.status_code, 429)
    then_eq("retry-after", r.headers.get("retry-after"), "30")
    then_eq("body error.type", r.json()["error"]["type"], "usage_limit_reached", claim="body = the upstream body")


@pytest.mark.parametrize(("knob", "status", "code"), [("unreachable", 502, "upstream-unreachable"), ("slow", 504, "upstream-timeout")],
                         ids=["an unreachable upstream is typed", "a read past the read timeout"])
async def test_transport_failures(codex_app, codex_gw, codex_upstream, codex_transport, clock, knob, status, code):
    world("policy-codex", "upstream-down" if knob == "unreachable" else "upstream-slow")
    doc = await _admitted(codex_app, codex_gw, clock)
    getattr(codex_transport, knob).add("codex")
    r = await ride(codex_gw, doc)
    then_eq("(status, code)", (r.status_code, err(r)), (status, code))
    then_eq("upstream calls", len(codex_upstream.calls), 0)


# -- the relay seam ------------------------------------------------------------------------------

def _event(kind="response.completed", **response) -> bytes:
    response = {"status": "completed", "usage": {"input_tokens": 7, "output_tokens": 3}, **response}
    return b"data: " + json.dumps({"type": kind, "response": response}).encode() + b"\n\n"


async def _drive(chunks, max_event_bytes=responses.MAX_EVENT_BYTES, stop_after: int | None = None):
    obs, closes, out, pulled = responses.Observation(), [], [], []

    async def source():
        for i, c in enumerate(chunks):
            pulled.append(i)
            if isinstance(c, BaseException):
                raise c
            yield c

    async def close():
        closes.append(1)

    stream = responses.relay(source(), obs, close, max_event_bytes)
    async for chunk in stream:
        out.append(chunk)
        if stop_after is not None and len(out) >= stop_after:
            await stream.aclose()
            break
    return obs, b"".join(out), len(closes), pulled


async def test_every_split():
    """row: every byte split of a CRLF stream parses"""
    world("policy-codex")
    raw = b": heartbeat\r\n\r\n" + _event().replace(b"\n", b"\r\n")
    with when(f"relay {len(raw) + 1} two-chunk splits of a {len(raw)}-byte CRLF stream"):
        results = [await _drive([raw[:i], raw[i:]]) for i in range(len(raw) + 1)]
    with then("every split: completed, usage 7/3, bytes identical, one close"):
        for i, (obs, out, closes, _) in enumerate(results):
            assert (obs.outcome, obs.input_tokens, obs.output_tokens, out, closes) == ("completed", 7, 3, raw, 1), i


async def test_multiline():
    """row: a multi-line data field is one event"""
    world("policy-codex")
    raw = b'data: {"type":"response.completed",\ndata: "response":{"status":"completed"}}\n\n'
    with when("relay one byte per chunk"):
        obs, out, closes, _ = await _drive([bytes([b]) for b in raw])
    then_eq("(outcome, bytes, closes)", (obs.outcome, out, closes), ("completed", raw, 1))


async def test_large_stream():
    """row: terminal usage after 4 MiB of deltas is counted"""
    world("policy-codex")
    delta = b'data: {"type":"response.output_text.delta","delta":"hello"}\n\n'
    chunks = [delta] * 100000 + [_event(), _event(usage={"input_tokens": 99})]
    with when("relay 100000 delta events, a terminal, and a second terminal"):
        obs, out, closes, _ = await _drive(chunks)
    then_eq("bytes > 4 MiB", len(out) > 4 * 1024 * 1024, True)
    then_eq("(outcome, in, out, closes)", (obs.outcome, obs.input_tokens, obs.output_tokens, closes), ("completed", 7, 3, 1))


async def test_unknown_usage():
    """row: malformed usage is unknown, not zero"""
    world("policy-codex")
    with when("relay a terminal whose usage is input_tokens true, output_tokens -1"):
        obs, _, _, _ = await _drive([_event(usage={"input_tokens": True, "output_tokens": -1})])
    then_eq("(outcome, in, out)", (obs.outcome, obs.input_tokens, obs.output_tokens), ("completed", None, None))


# chunks = the spec cell; the bytes are built from it in CHUNKS (a short param, not a 1 KiB blob)
CHUNKS = {
    "one event over the bound": ([b":" + b"a" * 1024], 512),
    "`response.completed` with `status: failed`": ([_event(status="failed")], None),
    "`data: [DONE]`": ([b"data: [DONE]\n\n"], None),
    "`data: []`": ([b"data: []\n\n"], None),
}
PROTOCOL_ROWS = [
    ("an oversized event is refused", "one event over the bound", "protocol-error", "none of it"),
    ("a completed event with another status is invalid", "`response.completed` with `status: failed`", "protocol-error", "none of it"),
    ("[DONE] alone is truncation", "`data: [DONE]`", "truncated", "identical"),
    ("a non-object event is invalid", "`data: []`", "protocol-error", "none of it"),
]


@pytest.mark.parametrize(("chunks", "outcome", "out"), [r[1:] for r in PROTOCOL_ROWS], ids=[r[0] for r in PROTOCOL_ROWS])
async def test_protocol(chunks, outcome, out):
    world("policy-codex")
    raw, bound = CHUNKS[chunks]
    with when(f"relay chunks {chunks} (event bound {bound or responses.MAX_EVENT_BYTES})"):
        obs, got, closes, _ = await _drive(raw, bound or responses.MAX_EVENT_BYTES)
    then_eq("(outcome, bytes out, closes)", (obs.outcome, got, closes), (outcome, b"".join(raw) if out == "identical" else b"", 1))


async def test_transport_fault():
    """row: a transport fault mid-stream is sanitised"""
    world("policy-codex")
    with when("relay one chunk, then the transport raises TimeoutError('DUMMY-SECRET upstream details')"):
        obs, out, closes, _ = await _drive([b": first\n\n", TimeoutError("DUMMY-SECRET upstream details")])
    then_eq("(outcome, bytes out, closes)", (obs.outcome, out, closes), ("transport-error", b": first\n\n", 1))
    then_eq("observation carries no secret", "DUMMY-SECRET" in repr(obs), False)


async def test_cancellation():
    """row: a cancelled download closes upstream without draining"""
    world("policy-codex")
    with when("the consumer stops after the first chunk"):
        obs, out, closes, pulled = await _drive([b": first\n\n", _event()], stop_after=1)
    then_eq("(outcome, bytes out, closes)", (obs.outcome, out, closes), ("cancelled", b": first\n\n", 1))
    then_eq("chunks pulled from upstream", pulled, [0], claim="the second chunk is never pulled")


async def test_refused_answer_captured(codex_app, codex_gw, codex_upstream, clock, caplog):
    """row: a refused answer is captured: content-type, header names, a bounded preview"""
    world("policy-codex", "upstream-wrong-type")
    codex_upstream.behaviour = "upstream-wrong-type"
    with given("a codex session"):
        doc = await _admitted(codex_app, codex_gw, clock)
    with when("POST /openai/v1/responses — the upstream answers 200 application/json"), caplog.at_level("ERROR", logger="gateway.codex"):
        r = await ride(codex_gw, doc, body(), label="wrong-type")
    then_eq("status", r.status_code, 502)
    line = next((rec.getMessage() for rec in caplog.records if "upstream-content-type codex 200" in rec.getMessage()), "")
    with then("the ERROR line names the content-type, the header names and a preview of the body", line={"actual": line}):
        assert "content-type='application/json'" in line
        assert "headers=[" in line and "content-type" in line.split("headers=[", 1)[1].split("]", 1)[0]
        assert "body='{\"output\":[]}'" in line
    codex_upstream.behaviour = "upstream-500"
    with when("the next request, the upstream answering 500"), caplog.at_level("ERROR", logger="gateway.codex"):
        r = await ride(codex_gw, doc, body(), label="500")
    then_eq("status", r.status_code, 502)
    line = next((rec.getMessage() for rec in caplog.records if "upstream-http-error codex 500" in rec.getMessage()), "")
    with then("the 5xx body is previewed too", line={"actual": line}):
        assert "body='{\"error\":\"boom\"}'" in line


async def test_auth_refusal_body_never_read(codex_app, codex_gw, codex_upstream, clock, caplog):
    """row: an auth refusal's body is never read, not even into the log"""
    world("policy-codex", "upstream-401")
    codex_upstream.behaviour = "upstream-401"
    with given("a codex session"):
        doc = await _admitted(codex_app, codex_gw, clock)
    with when("POST /openai/v1/responses — the upstream answers 401 with a marker in its body"), caplog.at_level("DEBUG"):
        r = await ride(codex_gw, doc, body(), label="401")
    then_eq("status", r.status_code, 502)
    line = next((rec.getMessage() for rec in caplog.records if "upstream-auth codex 401" in rec.getMessage()), "")
    with then("the ERROR line says the body was not read; the marker appears in no log line", line={"actual": line}):
        assert "<not read: auth>" in line
        assert not any("DUMMY-SECRET-LEAK" in rec.getMessage() for rec in caplog.records)
