"""GW-RAIL-ANTHROPIC — the subscription OAuth rail's wire (specs/endpoints/anthropic-messages.md).

| description | inbound header | upstream header |
|---|---|---|
| the credential is the OAuth token as a bearer | Authorization: Bearer gws_... | Authorization: Bearer <AUTH_TOKEN> |
| no x-api-key reaches upstream | x-api-key: gws_... | no x-api-key |
| the OAuth beta is added | no anthropic-beta | anthropic-beta: oauth-2025-04-20 |
| the OAuth beta is merged, not replaced | anthropic-beta: interleaved-thinking-2025-05-14 | anthropic-beta: interleaved-thinking-2025-05-14,oauth-2025-04-20 |
| the OAuth beta is never duplicated | anthropic-beta: oauth-2025-04-20 | anthropic-beta: oauth-2025-04-20 |
| anthropic-version passes through | anthropic-version: 2023-06-01 | anthropic-version: 2023-06-01 |
| the claude-code session id passes through | X-Claude-Code-Session-Id: <uuid> | X-Claude-Code-Session-Id: <uuid> |
| the user agent passes through | User-Agent: claude-cli/2.1.281 | User-Agent: claude-cli/2.1.281 |

| description | inbound path | upstream behaviour | status | body | recorded on the session |
|---|---|---|---|---|---|
| a messages call lands | POST /anthropic/v1/messages | upstream-ok | 200 | the upstream body, byte-identical | requests +1, tokens_in = usage.input_tokens, tokens_out = usage.output_tokens |
| a streamed call streams | POST /anthropic/v1/messages, stream: true | upstream-stream | 200 | the SSE bytes, unchanged | requests +1; tokens from the final message_delta usage |
| cache classes are recorded apart | POST /anthropic/v1/messages | upstream-ok-cached | 200 | the upstream body, byte-identical | (requests, tokens_in, tokens_cache_read, tokens_cache_write, tokens_out) = (1, 12, 300, 40, 7) |
| a gzipped stream still counts | POST /anthropic/v1/messages, stream: true | upstream-stream-gzip | 200 | the gzip bytes, unchanged, content-encoding: gzip kept | requests +1; tokens from the decoded message_delta usage |
| a rate limit passes through | POST /anthropic/v1/messages | upstream-429 | 429 | the upstream body, retry-after kept | requests +1 |
| an upstream auth failure is typed and hidden | POST /anthropic/v1/messages | upstream-401 | 424 | upstream-auth envelope | requests +1 |
| the openai dialect is not served on the subscription | POST /openai/v1/chat/completions | (no upstream call) | 501 | dialect-unsupported-on-rail | nothing |
| the models list is not served on the subscription | GET /openai/v1/models | (no upstream call) | 501 | dialect-unsupported-on-rail | nothing |
| an unreachable upstream is typed | POST /anthropic/v1/messages | upstream-down | 502 | upstream-unreachable envelope | requests +1 |
| a read past 600 s (WIP: clock-faked) | POST /anthropic/v1/messages | upstream-slow | 504 | upstream-timeout | requests +1 |
| the upstream URL is api.anthropic.com/v1/messages | — | — | — | — | — |

Stream completeness (anthropic dialect; terminal event = `message_stop`):

| description | upstream behaviour | recorded on the session | gateway_requests_incomplete_total{rail="anthropic",dialect="anthropic",reason} |
|---|---|---|---|
| a stream that ends without message_stop is recorded incomplete | upstream-stream-truncated | requests_incomplete 1; the request row's incomplete = no-terminal | no-terminal = 1 |
| a gzipped stream's message_stop is seen through the encoding | upstream-stream-gzip | requests_incomplete 0; incomplete = null | no-terminal = 0 |
| the client going away mid-stream is recorded incomplete | upstream-stream, the client closes after the first chunk | requests_incomplete 1; incomplete = client-closed | client-closed = 1 |
"""

from __future__ import annotations

import time

import httpx
import pytest

from agent_gateway.rails import OAUTH_BETA, upstream_url

from ._rail_rows import expected_bytes, ride
from ._stream_rows import incomplete_series, recorded_incomplete
from .conftest import (
    ANTHROPIC_TOKEN,
    UPSTREAM_BASES,
    attach_json,
    bearer,
    check,
    err,
    given,
    open_session,
    rule,
    then,
    then_eq,
    when,
    world,
)

pytestmark = rule("GW-RAIL-ANTHROPIC")
RAIL = "anthropic"

HEADER_ROWS = [
    ("the credential is the OAuth token as a bearer", {}, {"authorization": f"Bearer {ANTHROPIC_TOKEN}"}),
    ("no x-api-key reaches upstream", {"x-api-key": "<token>"}, {"x-api-key": None}),
    ("the OAuth beta is added", {}, {"anthropic-beta": OAUTH_BETA}),
    ("the OAuth beta is merged, not replaced", {"anthropic-beta": "interleaved-thinking-2025-05-14"}, {"anthropic-beta": f"interleaved-thinking-2025-05-14,{OAUTH_BETA}"}),
    ("the OAuth beta is never duplicated", {"anthropic-beta": OAUTH_BETA}, {"anthropic-beta": OAUTH_BETA}),
    ("anthropic-version passes through", {"anthropic-version": "2023-06-01"}, {"anthropic-version": "2023-06-01"}),
    ("the claude-code session id passes through", {"x-claude-code-session-id": "7b1e-uuid"}, {"x-claude-code-session-id": "7b1e-uuid"}),
    ("the user agent passes through", {"user-agent": "claude-cli/2.1.281"}, {"user-agent": "claude-cli/2.1.281"}),
]


@pytest.mark.parametrize(("inbound", "expect"), [r[1:] for r in HEADER_ROWS], ids=[r[0] for r in HEADER_ROWS])
async def test_headers(gw, upstreams, inbound, expect):
    world(upstream="upstream-ok")
    doc, r = await ride(gw, RAIL, "messages", headers=inbound)
    then_eq("status", r.status_code, 200)
    call = upstreams[RAIL].calls[-1]
    then_eq("upstream path", call["path"], "/v1/messages")
    for k, v in expect.items():
        then_eq(f"expect upstream header {k}", call["headers"].get(k), v)


def test_upstream_url(settings):
    """row: the upstream URL is api.anthropic.com/v1/messages"""
    world()
    from agent_gateway.config import UPSTREAM_DEFAULTS

    with when("upstream_url(anthropic, messages) for the test base and the production default"):
        test_url = upstream_url(RAIL, settings.upstreams[RAIL], "anthropic", "messages")
        prod_url = upstream_url(RAIL, UPSTREAM_DEFAULTS[RAIL], "anthropic", "messages")
    then_eq("upstream URL (test base)", test_url, UPSTREAM_BASES[RAIL] + "/v1/messages")
    then_eq("upstream URL (production default)", prod_url, "https://api.anthropic.com/v1/messages")


def _recorded(store, doc, want: tuple, what: str = "(requests, tokens_in, tokens_out)"):
    with then(f"recorded on the session: {what} = {want}"):
        row = store.get_session(doc["session"]["id"])
        got = (row.requests, row.tokens_in, row.tokens_out) if len(want) == 3 else (row.requests,)
        check(what, got, want)


async def test_messages_call_lands(gw, upstreams, policy, store):
    """row: a messages call lands"""
    world(upstream="upstream-ok")
    status, body, headers = await expected_bytes(upstreams[RAIL], "messages", "claude-sonnet-4-6", "upstream-ok")
    doc, r = await ride(gw, RAIL, "messages", body={"model": "claude-sonnet-4-6"})
    then_eq("status", (r.status_code, status), (200, 200), claim="status = 200 (= the upstream's)")
    with then("body = the upstream body, byte-identical, same content-type",
              body={"expected_len": len(body), "actual_len": len(r.content)},
              content_type={"expected": headers["content-type"], "actual": r.headers["content-type"]}):
        assert r.content == body
        assert r.headers["content-type"] == headers["content-type"]
    _recorded(store, doc, (1, 12, 7))


async def test_streamed_call_streams(gw, upstreams, store):
    """row: a streamed call streams"""
    world(upstream="upstream-stream")
    status, body, headers = await expected_bytes(upstreams[RAIL], "messages", "claude-sonnet-4-6", "upstream-stream")
    upstreams[RAIL].behaviour = "upstream-stream"
    doc, r = await ride(gw, RAIL, "messages", body={"model": "claude-sonnet-4-6", "stream": True})
    then_eq("status", r.status_code, 200)
    with then("body = the SSE bytes, unchanged, content-type text/event-stream",
              body={"expected_len": len(body), "actual_len": len(r.content)}, content_type={"actual": r.headers["content-type"]}):
        assert r.content == body
        assert r.headers["content-type"].startswith("text/event-stream")
    _recorded(store, doc, (1, 23, 9))


async def test_cache_classes_recorded_apart(gw, upstreams, store):
    """row: cache classes are recorded apart"""
    world(upstream="upstream-ok-cached")
    status, body, headers = await expected_bytes(upstreams[RAIL], "messages", "claude-sonnet-4-6", "upstream-ok-cached")
    upstreams[RAIL].behaviour = "upstream-ok-cached"
    doc, r = await ride(gw, RAIL, "messages", body={"model": "claude-sonnet-4-6"})
    then_eq("status", r.status_code, 200)
    with then("body = the upstream body, byte-identical", body={"expected_len": len(body), "actual_len": len(r.content)}):
        assert r.content == body
    what = "(requests, tokens_in, tokens_cache_read, tokens_cache_write, tokens_out)"
    with then(f"recorded on the session: {what} = (1, 12, 300, 40, 7)"):
        row = store.get_session(doc["session"]["id"])
        check(what, (row.requests, row.tokens_in, row.tokens_cache_read, row.tokens_cache_write, row.tokens_out), (1, 12, 300, 40, 7))


async def test_gzipped_stream_still_counts(gw, upstreams, store):
    """row: a gzipped stream still counts"""
    world(upstream="upstream-stream-gzip")
    status, body, headers = await expected_bytes(upstreams[RAIL], "messages", "claude-sonnet-4-6", "upstream-stream-gzip")
    upstreams[RAIL].behaviour = "upstream-stream-gzip"
    doc, r = await ride(gw, RAIL, "messages", body={"model": "claude-sonnet-4-6", "stream": True})
    then_eq("status", r.status_code, 200)
    with then("body = the gzip bytes unchanged (decoded by the client), content-encoding gzip kept",
              body={"expected_len": len(body), "actual_len": len(r.content)},
              content_encoding={"actual": r.headers.get("content-encoding")}):
        assert r.content == body
        assert r.headers.get("content-encoding") == "gzip"
    _recorded(store, doc, (1, 23, 9))


async def test_rate_limit_passes_through(gw, upstreams, store):
    """row: a rate limit passes through"""
    world(upstream="upstream-429")
    upstreams[RAIL].behaviour = "upstream-429"
    doc, r = await ride(gw, RAIL, "messages")
    got = {"status": r.status_code, "retry-after": r.headers.get("retry-after"), "body error.type": r.json()["error"]["type"]}
    want = {"status": 429, "retry-after": "30", "body error.type": "rate_limit_error"}
    with then("status 429, retry-after = '30', body = the upstream body (error.type = rate_limit_error)",
              **{k: {"expected": want[k], "actual": got[k]} for k in want}):  # one verdict attachment for the three claims
        assert got["status"] == 429, f"status: got {got['status']!r}"
        assert got["retry-after"] == "30", f"retry-after: got {got['retry-after']!r}"
        assert got["body error.type"] == "rate_limit_error", f"body error.type: got {got['body error.type']!r}"
    _recorded(store, doc, (1,), "requests")


async def test_upstream_auth_hidden(gw, upstreams, store):
    """row: an upstream auth failure is typed and hidden"""
    world(upstream="upstream-401")
    upstreams[RAIL].behaviour = "upstream-401"
    doc, r = await ride(gw, RAIL, "messages")
    then_eq("status", r.status_code, 424)
    with then("body = the upstream-auth envelope, not the upstream body (no LEAK marker)", body={"actual": r.text}):
        assert err(r) == "upstream-auth"
        assert "LEAK" not in r.text
    _recorded(store, doc, (1,), "requests")


DIALECT_ROWS = [("the openai dialect is not served on the subscription", "chat"), ("the models list is not served on the subscription", "models")]


@pytest.mark.parametrize("op", [r[1] for r in DIALECT_ROWS], ids=[r[0] for r in DIALECT_ROWS])
async def test_openai_dialect_501(gw, upstreams, store, op):
    world()
    with given("a session on rail anthropic (reviewer, harness claude)"):
        doc = await open_session(gw, role="reviewer", harness="claude")
    path = "/openai/v1/models" if op == "models" else "/openai/v1/chat/completions"
    with when(f"{'GET' if op == 'models' else 'POST'} {path} op={op}"):
        r = await (gw.get("/openai/v1/models", headers=bearer(doc)) if op == "models" else gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc)))
    then_eq("status", r.status_code, 501)
    then_eq("code", err(r), "dialect-unsupported-on-rail", claim="error code = dialect-unsupported-on-rail")
    then_eq("upstream calls", len(upstreams[RAIL].calls), 0, claim="no upstream call")
    _recorded(store, doc, (0,), "requests")


async def test_upstream_unreachable(gw, transport, store):
    """row: an unreachable upstream is typed"""
    world(upstream="upstream-down")
    transport.unreachable.add(RAIL)
    doc, r = await ride(gw, RAIL, "messages")
    then_eq("status", r.status_code, 502)
    then_eq("code", err(r), "upstream-unreachable", claim="error code = upstream-unreachable")
    _recorded(store, doc, (1,), "requests")


async def test_read_past_600s(gw, transport, store):
    """row: a read past 600 s (WIP: clock-faked)"""
    world(upstream="upstream-slow")
    transport.slow.add(RAIL)
    doc, r = await ride(gw, RAIL, "messages")
    then_eq("status", r.status_code, 504)
    then_eq("code", err(r), "upstream-timeout", claim="error code = upstream-timeout")
    _recorded(store, doc, (1,), "requests")


ANTHROPIC_COMPLETENESS_ROWS = [
    ("a stream that ends without message_stop is recorded incomplete", "upstream-stream-truncated", 1, "no-terminal"),
    ("a gzipped stream's message_stop is seen through the encoding", "upstream-stream-gzip", 0, None),
]


@pytest.mark.parametrize(("behaviour", "count", "reason"), [r[1:] for r in ANTHROPIC_COMPLETENESS_ROWS], ids=[r[0] for r in ANTHROPIC_COMPLETENESS_ROWS])
async def test_stream_completeness(gw, upstreams, store, behaviour, count, reason):
    world(upstream=behaviour)
    upstreams[RAIL].behaviour = behaviour
    doc, r = await ride(gw, RAIL, "messages", body={"stream": True})
    then_eq("status", r.status_code, 200)
    recorded_incomplete(store, doc, count, reason)
    with then(f"gateway_requests_incomplete_total{{rail=anthropic,dialect=anthropic,reason=no-terminal}} = {count}"):
        check("series", await incomplete_series(gw, RAIL, "anthropic", "no-terminal"), count)


async def test_client_closed_mid_stream(gw, app, store, upstreams):
    """row: the client going away mid-stream is recorded incomplete"""
    world(upstream="upstream-stream", note="the gateway's stream is driven directly: the in-process client buffers whole bodies, so a hang-up is the iterator closed early")
    with given("a session on rail anthropic (reviewer, harness claude)"):
        doc = await open_session(gw, role="reviewer", harness="claude")
    row = store.get_session(doc["session"]["id"])

    class _Events(httpx.AsyncByteStream):
        async def __aiter__(self):
            yield b'event: message_start\ndata: {"type":"message_start"}\n\n'
            yield b'event: content_block_delta\ndata: {"type":"content_block_delta"}\n\n'

    resp = httpx.Response(200, headers={"content-type": "text/event-stream"}, stream=_Events())
    with when("the upstream stream's first chunk is relayed, then the client hangs up (the body iterator is closed)"):
        sr = app.state.proxy._stream(resp, row, "anthropic", 200, {}, True, time.monotonic(), "")
        it = sr.body_iterator
        first = await it.__anext__()
        await it.aclose()
        attach_json("relayed before the hang-up", {"first_chunk": first.decode()})
    recorded_incomplete(store, doc, 1, "client-closed")
    with then("gateway_requests_incomplete_total{rail=anthropic,dialect=anthropic,reason=client-closed} = 1"):
        check("series", await incomplete_series(gw, RAIL, "anthropic", "client-closed"), 1)
