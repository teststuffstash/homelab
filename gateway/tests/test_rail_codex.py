"""GW-RAIL-CODEX — the codex rail's wire on POST /openai/v1/responses (specs/endpoints/openai-responses.md
§GW-RAIL-CODEX: the request boundary, header replacement, streams and usage, upstream failures, the
boundary log line, the relay seam). World `policy-codex` (specs/worlds/policy-codex.json) with the codex
fake backend and the FAKE credential store (tests/_codex_world.py); the relay rows drive
`responses.relay` directly. Ported from experiments/codex-rail/test_adapter.py + test_composed.py
(FU-270). Each parametrize's argnames are its spec table's header, its ids the description cells
(tests/_codex_rows.py); the §Opaque turn state and §Live grammar tables live in their own modules.
"""

from __future__ import annotations

import json

import pytest

from agent_gateway import responses

from ._codex_rows import expect, row, verdicts
from ._codex_world import (
    ACCOUNT,
    BEHAVIOURS,
    admitted,
    ride,
)
from ._codex_world import body as request_body
from .conftest import err, given, open_session, rule, then, then_eq, when, world

pytestmark = rule("GW-RAIL-CODEX")


def _auth(doc) -> dict:
    return {"authorization": f"Bearer {doc['session']['token']}"}


def _code(r) -> str:
    """The error envelope's code, or `—` when the body is not an envelope (a 200, a relayed 429)."""
    try:
        return err(r)
    except (AssertionError, ValueError):
        return "—"


# -- the request boundary -------------------------------------------------------------------------

BODIES = {  # the `body` cell → the field that deviates from the accepted body ([] = not an object)
    "accepted": {},
    "model absent": {"model": None},
    "model: gpt-other": {"model": "gpt-other"},
    "stream: false": {"stream": False},
    "store: true": {"store": True},
    'input: "hi"': {"input": "hi"},
    "[]": None,
}


@pytest.mark.parametrize(("body", "expected_status", "expected_code", "expected_upstream_calls", "expected_upstream_model"), [
    pytest.param("accepted", 200, "—", 1, "fixture-model", id="a streaming, store-off, array-input request lands"),
    pytest.param("model absent", 200, "—", 1, "fixture-model", id="an absent model is filled with the wire id"),
    pytest.param("model: gpt-other", 403, "model-not-session", 0, "—", id="another model is refused"),
    pytest.param("stream: false", 400, "responses-mode-unsupported", 0, "—", id="a non-streaming request is refused"),
    pytest.param("store: true", 400, "responses-mode-unsupported", 0, "—", id="server-side storage is refused"),
    pytest.param('input: "hi"', 400, "responses-input-invalid", 0, "—", id="a string input is refused"),
    pytest.param("[]", 400, "malformed-body", 0, "—", id="a body that is not a JSON object"),
])
async def test_request_boundary(codex_app, codex_gw, codex_upstream, clock, body, expected_status, expected_code,
                                expected_upstream_calls, expected_upstream_model):
    world("policy-codex", "upstream-ok")
    row(body=body, expected_status=expected_status, expected_code=expected_code,
        expected_upstream_calls=expected_upstream_calls, expected_upstream_model=expected_upstream_model)
    doc = await admitted(codex_app, codex_gw, clock)
    over = BODIES[body]
    payload = [] if over is None else {k: v for k, v in request_body(**over).items() if v is not None}
    with when(f"POST /openai/v1/responses · body {body}"):
        r = await codex_gw.post("/openai/v1/responses", json=payload, headers=_auth(doc))
    verdicts(
        status=(r.status_code, expected_status),
        code=(_code(r), expected_code),
        upstream_calls=(len(codex_upstream.calls), expected_upstream_calls),
        upstream_model=(codex_upstream.calls[-1]["body"]["model"] if codex_upstream.calls else "—", expected_upstream_model),
    )


@pytest.mark.parametrize(("session", "path", "expected_status", "expected_code", "expected_upstream_calls"), [
    pytest.param("none", "/openai/v1/responses", 401, "session-unknown", 0, id="no session token"),
    pytest.param("codex", "/openai/v1/chat/completions", 501, "dialect-unsupported-on-rail", 0, id="a codex session on the chat path"),
    pytest.param("opencode worker", "/openai/v1/responses", 501, "dialect-unsupported-on-rail", 0, id="a non-codex session on the responses path"),
])
async def test_path_and_token(codex_app, codex_gw, codex_upstream, clock, session, path, expected_status, expected_code,
                              expected_upstream_calls):
    world("policy-codex", "upstream-ok")
    row(session=session, path=path, expected_status=expected_status, expected_code=expected_code,
        expected_upstream_calls=expected_upstream_calls)
    headers: dict = {}
    if session == "codex":
        headers = _auth(await admitted(codex_app, codex_gw, clock))
    elif session == "opencode worker":
        with given(f"session {session}: a worker session on the opencode rail"):
            headers = _auth(await open_session(codex_gw, role="worker", harness="opencode"))
    else:
        with given(f"session {session}: no Authorization header"):
            pass
    payload = {"messages": []} if path.endswith("/chat/completions") else request_body()
    with when(f"POST {path} · session {session}"):
        r = await codex_gw.post(path, json=payload, headers=headers)
    verdicts(
        status=(r.status_code, expected_status),
        code=(_code(r), expected_code),
        upstream_calls=(len(codex_upstream.calls), expected_upstream_calls),
    )


# -- header replacement ---------------------------------------------------------------------------

EXACT_HEADERS = {"authorization", "chatgpt-account-id", "content-type", "accept", "accept-encoding", "user-agent",
                 "host", "content-length", "connection"}
INBOUND = {  # the `inbound` cell → the headers sent beside the session token
    "Authorization: Bearer gws_…": {},
    "ChatGPT-Account-ID: attacker": {"ChatGPT-Account-ID": "attacker"},
    "Cookie, x-api-key, x-foo, User-Agent: codex_exec/…, OpenAI-Beta": {
        "Cookie": "DUMMY-SECRET", "x-api-key": "DUMMY-SECRET", "x-foo": "bar", "User-Agent": "codex_exec/0.161.0", "OpenAI-Beta": "responses=v1"},
    "Accept-Encoding: gzip": {"Accept-Encoding": "gzip"},
}


def _upstream_shows(inbound: str, sent: dict[str, str], rotated_access: str) -> str:
    """What the backend received for the row's header(s), in the `upstream?` cell's vocabulary."""
    if inbound.startswith("Authorization"):
        got = sent.get("authorization")
        return "authorization: Bearer <the rotated access token>" if got == "Bearer " + rotated_access else f"authorization: {got}"
    if inbound.startswith("ChatGPT-Account-ID"):
        return f"chatgpt-account-id: {sent.get('chatgpt-account-id')}"
    if inbound.startswith("Cookie"):
        crossed = sorted(k for k in ("cookie", "x-api-key", "x-foo", "openai-beta") if k in sent)
        return f"none of them; user-agent: {sent.get('user-agent')}" if not crossed else f"crossed: {crossed}; user-agent: {sent.get('user-agent')}"
    return f"accept-encoding: {sent.get('accept-encoding')}; accept: {sent.get('accept')}"


@pytest.mark.parametrize(("inbound", "expected_upstream"), [
    pytest.param("Authorization: Bearer gws_…", "authorization: Bearer <the rotated access token>", id="the session token becomes the rail's access token"),
    pytest.param("ChatGPT-Account-ID: attacker", "chatgpt-account-id: dummy-account", id="the account comes from the credential, never the caller"),
    pytest.param("Cookie, x-api-key, x-foo, User-Agent: codex_exec/…, OpenAI-Beta", "none of them; user-agent: agent-gateway", id="no inbound header crosses ⚖"),
    pytest.param("Accept-Encoding: gzip", "accept-encoding: identity; accept: text/event-stream", id="the stream is asked for unencoded ⚖"),
])
async def test_header_replacement(codex_app, codex_gw, codex_upstream, exchange, clock, inbound, expected_upstream):
    world("policy-codex", "upstream-ok")
    row(inbound=inbound, expected_upstream=expected_upstream)
    doc = await admitted(codex_app, codex_gw, clock)
    r = await ride(codex_gw, doc, headers=INBOUND[inbound] or None, label=f"inbound {inbound}")
    then_eq("status", r.status_code, 200)
    sent = {k.lower(): v for k, v in codex_upstream.calls[-1]["headers"].items()}
    expect("upstream", _upstream_shows(inbound, sent, exchange.rotated.access_token), expected_upstream)
    with then(f"the upstream header set is exactly the six (+ transport): {sorted(EXACT_HEADERS)}",
              names={"expected": sorted(EXACT_HEADERS), "actual": sorted(sent)}):
        assert set(sent) == EXACT_HEADERS
    assert ACCOUNT == sent["chatgpt-account-id"]


# -- streams and usage ----------------------------------------------------------------------------

@pytest.mark.parametrize(("upstream", "expected_client_bytes", "expected_outcome", "expected_status", "expected_tokens"), [
    pytest.param("upstream-ok", "identical", "completed", 200, "7 / 0 / 0 / 3", id="a completed stream relays byte-unchanged and counts once"),
    pytest.param("upstream-ok-cached", "identical", "completed", 200, "12 / 300 / 0 / 7", id="cached input is its own class ⚖"),
    pytest.param("upstream-stream-duplicate", "identical", "completed", 200, "7 / 0 / 0 / 3", id="a second terminal event never replaces usage"),
    pytest.param("upstream-stream-failed", "identical", "failed", 200, "7 / 0 / 0 / 3", id="a failed terminal is not a completion ⚖"),
    pytest.param("upstream-stream-incomplete", "identical", "incomplete", 200, "7 / 0 / 0 / 3", id="an incomplete terminal is not a completion ⚖"),
    pytest.param("upstream-stream-truncated", "identical", "truncated", 502, "0 / 0 / 0 / 0", id="EOF without a terminal is truncation ⚖"),
    pytest.param("upstream-stream-invalid", "a prefix of the events before it, never it", "protocol-error", 502, "0 / 0 / 0 / 0",
                 id="an invalid event ends the stream before its bytes ⚖"),
])
async def test_streams(codex_app, codex_gw, codex_upstream, store, clock, caplog, upstream, expected_client_bytes, expected_outcome,
                       expected_status, expected_tokens):
    world("policy-codex", upstream)
    row(upstream=upstream, expected_client_bytes=expected_client_bytes, expected_outcome=expected_outcome,
        expected_status=expected_status, expected_tokens=expected_tokens)
    _, _, _, chunks = BEHAVIOURS[upstream]()
    full = b"".join(chunks)
    doc = await admitted(codex_app, codex_gw, clock)
    codex_upstream.behaviour = upstream
    caplog.set_level("INFO", logger="gateway.codex")
    r = await ride(codex_gw, doc, label=upstream)
    with then("the client's status is 200 (the stream was opened); one request recorded on the session"):
        assert r.status_code == 200
        assert store.get_session(doc["session"]["id"]).requests == 1
    if r.content == full:
        client_bytes = "identical"
    elif b"".join(chunks[:2]).startswith(r.content) and b"not-json" not in r.content:
        # the invalid stream: whatever the chunking, the client gets a prefix of the two valid events
        # before the bad one, and never the bad one's bytes (it is fed to the parser before it is sent)
        client_bytes = "a prefix of the events before it, never it"
    else:
        client_bytes = f"{len(r.content)} bytes, differing"
    lines = [rec.getMessage() for rec in caplog.records if rec.name == "gateway.codex" and "outcome=" in rec.getMessage()]
    req = store.requests_for(doc["session"]["id"])[-1]
    verdicts(
        client_bytes=(client_bytes, expected_client_bytes),
        outcome=(lines[-1].split("outcome=")[1].split()[0] if lines else "(no outcome line)", expected_outcome),
        status=(req["status"], expected_status),
        tokens=(f"{req['tokens_in']} / {req['tokens_cache_read']} / {req['tokens_cache_write']} / {req['tokens_out']}", expected_tokens),
    )


# -- upstream failures ----------------------------------------------------------------------------

TRANSPORT = {"upstream-down": "unreachable", "upstream-slow": "slow"}  # RailTransport knobs (no backend call)


@pytest.mark.parametrize(("upstream", "expected_status", "expected_code", "expected_retry_after", "expected_upstream_calls"), [
    pytest.param("upstream-401", 502, "upstream-auth", "—", 1, id="an upstream 401 is typed and hidden"),
    pytest.param("upstream-403", 502, "upstream-auth", "—", 1, id="an upstream 403 is the same class"),
    pytest.param("upstream-429", 429, "—", 30, 1, id="a rate limit passes through ⚖"),
    pytest.param("upstream-500", 502, "upstream-http-error", "—", 1, id="an upstream 5xx is typed ⚖"),
    pytest.param("upstream-302", 502, "upstream-http-error", "—", 1, id="a redirect is never followed"),
    pytest.param("upstream-wrong-type", 502, "upstream-content-type", "—", 1, id="a non-SSE 200 is refused ⚖"),
    pytest.param("upstream-down", 502, "upstream-unreachable", "—", 0, id="an unreachable upstream is typed"),
    pytest.param("upstream-slow", 504, "upstream-timeout", "—", 0, id="🚧 WIP: a read past the read timeout"),
])
async def test_upstream_failures(codex_app, codex_gw, codex_upstream, codex_transport, store, clock, upstream, expected_status,
                                 expected_code, expected_retry_after, expected_upstream_calls):
    world("policy-codex", upstream)
    row(upstream=upstream, expected_status=expected_status, expected_code=expected_code,
        expected_retry_after=expected_retry_after, expected_upstream_calls=expected_upstream_calls)
    doc = await admitted(codex_app, codex_gw, clock)
    if upstream in TRANSPORT:
        getattr(codex_transport, TRANSPORT[upstream]).add("codex")
    else:
        codex_upstream.behaviour = upstream
    r = await ride(codex_gw, doc, label=upstream)
    verdicts(
        status=(r.status_code, expected_status),
        code=(_code(r), expected_code),
    )
    retry = r.headers.get("retry-after")
    verdicts(
        retry_after=(int(retry) if retry else "—", expected_retry_after),
        upstream_calls=(len(codex_upstream.calls), expected_upstream_calls),
    )
    with then(f"the upstream body never reaches the client (no LEAK / DUMMY-SECRET marker); the recorded status is {expected_status}"):
        assert "LEAK" not in r.text and "DUMMY-SECRET" not in r.text
        assert store.requests_for(doc["session"]["id"])[-1]["status"] == expected_status
    if upstream == "upstream-429":
        with then("the body is the upstream body (error.type usage_limit_reached)"):
            assert r.json()["error"]["type"] == "usage_limit_reached"


# -- the boundary log line ------------------------------------------------------------------------

@pytest.mark.parametrize(("upstream", "expected_status", "expected_log_line_contains"), [
    pytest.param("upstream-ok-no-ctype", 200, "codex upstream 200 without a content-type — relayed as a stream",
                 id="a 200 with no content-type is relayed as a stream ⚖"),
    pytest.param("upstream-wrong-type", 502, "upstream-content-type codex 200 · content-type='application/json' · headers=[ · body='{\"output\":[]}'",
                 id="a refused answer is captured: content-type, header names, a bounded preview ⚖"),
    pytest.param("upstream-500", 502, "upstream-http-error codex 500 · body='{\"error\":\"boom\"}'", id="a 5xx body is previewed too"),
    pytest.param("upstream-401", 502, "upstream-auth codex 401 · <not read: auth>", id="an auth refusal's body is never read, not even into the log"),
])
async def test_boundary_log_line(codex_app, codex_gw, codex_upstream, clock, caplog, upstream, expected_status, expected_log_line_contains):
    world("policy-codex", upstream)
    row(upstream=upstream, expected_status=expected_status, expected_log_line_contains=expected_log_line_contains)
    doc = await admitted(codex_app, codex_gw, clock)
    codex_upstream.behaviour = upstream
    with caplog.at_level("DEBUG", logger="gateway"):
        r = await ride(codex_gw, doc, label=upstream)
    fragments = expected_log_line_contains.split(" · ")
    messages = [rec.getMessage() for rec in caplog.records]
    line = next((m for m in messages if fragments[0] in m), "")
    with then(f"the boundary line: {line[:160]}", line={"actual": line}):
        pass
    verdicts(
        status=(r.status_code, expected_status),
        log_line_contains=(" · ".join(f for f in fragments if f in line), expected_log_line_contains),
    )
    if upstream == "upstream-401":
        with then("the body's marker appears in no log line (not read, not previewed)"):
            assert not any("DUMMY-SECRET-LEAK" in m for m in messages)
    if upstream == "upstream-wrong-type":
        with then("the header NAMES are listed (content-type among them)"):
            assert "content-type" in line.split("headers=[", 1)[1].split("]", 1)[0]
    if upstream == "upstream-ok-no-ctype":
        terminal = [ln for ln in r.text.splitlines() if ln.startswith("event: ")][-1] if "event: " in r.text else ""
        then_eq("terminal event", terminal, "event: response.completed", claim="the stream is relayed to its completion")


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


def _tokens(obs) -> str:
    return "unknown" if obs.input_tokens is None or obs.output_tokens is None else f"{obs.input_tokens} / {obs.output_tokens}"


def _bytes_out(out: bytes, chunks: list) -> str:
    full = b"".join(c for c in chunks if isinstance(c, bytes))
    if not out:
        return "none"
    if len(chunks) > 1 and out == chunks[0]:
        return "the completed event" if out == _event() else "the first chunk"
    if out == full:
        return "identical"
    return f"{len(out)} bytes"


def _pulled(pulled: list[int], chunks: list) -> str:
    return "all" if pulled == list(range(len(chunks))) else "the first chunk only" if pulled == [0] else str(pulled)


EVERY_SPLIT = "a heartbeat + one completed event in CRLF, split at every offset"
GRAMMAR = {  # the `chunks` cell → (chunks, event bound)
    "one completed event with no usage over two data: lines, one byte per chunk":
        ([bytes([b]) for b in b'data: {"type":"response.completed",\ndata: "response":{"status":"completed"}}\n\n'], None),
    "100000 delta events, a terminal, a second terminal":
        ([b'data: {"type":"response.output_text.delta","delta":"hello"}\n\n'] * 100000 + [_event(), _event(usage={"input_tokens": 99})], None),
    "a terminal with input_tokens: true, output_tokens: -1": ([_event(usage={"input_tokens": True, "output_tokens": -1})], None),
    "data: [DONE]": ([b"data: [DONE]\n\n"], None),
}


@pytest.mark.parametrize(("chunks", "expected_outcome", "expected_tokens", "expected_bytes_out", "expected_closes"), [
    pytest.param(EVERY_SPLIT, "completed", "7 / 3", "identical", 1, id="every byte split of a CRLF stream parses"),
    pytest.param("one completed event with no usage over two data: lines, one byte per chunk", "completed", "unknown", "identical", 1,
                 id="a multi-line data field is one event"),
    pytest.param("100000 delta events, a terminal, a second terminal", "completed", "7 / 3", "identical", 1,
                 id="terminal usage after 4 MiB of deltas is counted"),
    pytest.param("a terminal with input_tokens: true, output_tokens: -1", "completed", "unknown", "identical", 1,
                 id="malformed usage is unknown, not zero"),
    pytest.param("data: [DONE]", "truncated", "unknown", "identical", 1, id="[DONE] alone is truncation"),
])
async def test_relay_grammar(chunks, expected_outcome, expected_tokens, expected_bytes_out, expected_closes):
    world("policy-codex")
    row(chunks=chunks, expected_outcome=expected_outcome, expected_tokens=expected_tokens,
        expected_bytes_out=expected_bytes_out, expected_closes=expected_closes)
    if chunks == EVERY_SPLIT:
        raw = b": heartbeat\r\n\r\n" + _event().replace(b"\n", b"\r\n")
        with when(f"relay chunks {chunks}: {len(raw) + 1} two-chunk splits of the {len(raw)}-byte stream"):
            results = [await _drive([raw[:i], raw[i:]]) for i in range(len(raw) + 1)]
        outcomes = {r[0].outcome for r in results}
        tokens = {_tokens(r[0]) for r in results}
        outs = {_bytes_out(r[1], [raw]) for r in results}
        closes = {r[2] for r in results}
        one = lambda s: next(iter(s)) if len(s) == 1 else f"mixed: {sorted(map(str, s))}"  # noqa: E731
        verdicts(
            outcome=(one(outcomes), expected_outcome),
            tokens=(one(tokens), expected_tokens),
            bytes_out=(one(outs), expected_bytes_out),
            closes=(one(closes), expected_closes),
        )
        return
    raw, bound = GRAMMAR[chunks]
    with when(f"relay chunks {chunks} ({len(raw)} chunks)"):
        obs, out, closes, _ = await _drive(raw, bound or responses.MAX_EVENT_BYTES)
    verdicts(
        outcome=(obs.outcome, expected_outcome),
        tokens=(_tokens(obs), expected_tokens),
        bytes_out=(_bytes_out(out, raw), expected_bytes_out),
        closes=(closes, expected_closes),
    )
    if chunks.startswith("100000"):
        then_eq("bytes > 4 MiB", len(out) > 4 * 1024 * 1024, True)


ENDS = {  # the `chunks` cell → (chunks, event bound, stop_after)
    "one 1025-byte event, bound 512": ([b":" + b"a" * 1024], 512, None),
    "response.completed with status: failed": ([_event(status="failed")], None, None),
    "data: []": ([b"data: []\n\n"], None, None),
    "one chunk, then the transport raises with secret text": ([b": first\n\n", TimeoutError("DUMMY-SECRET upstream details")], None, None),
    "the consumer stops after the first chunk": ([b": first\n\n", _event()], None, 1),
    "the consumer stops after the completed event, a trailer still queued": ([_event(), b": trailer\n\n"], None, 1),
}


@pytest.mark.parametrize(("chunks", "expected_outcome", "expected_bytes_out", "expected_pulled", "expected_closes"), [
    pytest.param("one 1025-byte event, bound 512", "protocol-error", "none", "all", 1, id="an oversized event is refused ⚖"),
    pytest.param("response.completed with status: failed", "protocol-error", "none", "all", 1, id="a completed event with another status is invalid"),
    pytest.param("data: []", "protocol-error", "none", "all", 1, id="a non-object event is invalid"),
    pytest.param("one chunk, then the transport raises with secret text", "transport-error", "the first chunk", "all", 1,
                 id="a transport fault mid-stream is sanitised"),
    pytest.param("the consumer stops after the first chunk", "cancelled", "the first chunk", "the first chunk only", 1,
                 id="a cancelled download closes upstream without draining"),
    pytest.param("the consumer stops after the completed event, a trailer still queued", "completed", "the completed event", "the first chunk only", 1,
                 id="a consumer that stops after the terminal event keeps the terminal outcome ⚖"),
])
async def test_relay_ends(chunks, expected_outcome, expected_bytes_out, expected_pulled, expected_closes):
    world("policy-codex")
    row(chunks=chunks, expected_outcome=expected_outcome, expected_bytes_out=expected_bytes_out,
        expected_pulled=expected_pulled, expected_closes=expected_closes)
    raw, bound, stop_after = ENDS[chunks]
    with when(f"relay chunks {chunks} (event bound {bound or responses.MAX_EVENT_BYTES}" + (f", the consumer stops after {stop_after}" if stop_after else "") + ")"):
        obs, out, closes, pulled = await _drive(raw, bound or responses.MAX_EVENT_BYTES, stop_after)
    verdicts(
        outcome=(obs.outcome, expected_outcome),
        bytes_out=(_bytes_out(out, raw), expected_bytes_out),
        pulled=(_pulled(pulled, raw), expected_pulled),
        closes=(closes, expected_closes),
    )
    if chunks.startswith("one chunk, then"):
        then_eq("observation carries no secret", "DUMMY-SECRET" in repr(obs), False)
    if chunks.startswith("the consumer stops after the completed"):
        then_eq("usage counted", (obs.input_tokens, obs.output_tokens), (7, 3))
