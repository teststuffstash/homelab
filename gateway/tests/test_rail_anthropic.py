"""GW-RAIL-ANTHROPIC — the subscription OAuth rail's wire (specs/endpoints/anthropic-messages.md).

One parametrized case per table row: the argnames are the table's header cells (`name?` is
`expected_name`), the ids its description cells, the literals the page's Legend lines. World
`policy-default`, the fake anthropic upstream in the behaviour the `upstream` column names; the
session is a reviewer's (harness claude), opened by `ride()`.
"""

from __future__ import annotations

import time

import httpx
import pytest

from agent_gateway.config import UPSTREAM_DEFAULTS
from agent_gateway.rails import upstream_url

from ._rail_rows import NONE, apply_transport_world, body_class, headers_seen, inputs, oracle, recorded, ride
from ._stream_rows import incomplete_recorded, incomplete_series
from .conftest import attach_json, given, open_session, rule, then, then_eq, when, world

pytestmark = rule("GW-RAIL-ANTHROPIC")
RAIL = "anthropic"
MODEL = "claude-sonnet-4-6"  # the dated id the claude CLI resolves `claude/sonnet` to (GW-MODEL-RESOLVE)


# -- The subscription credential and the header rewrites ------------------------------------------
HEADER_ROWS = [  # description | upstream | inbound | upstream_header?
    ("the credential is the OAuth token as a bearer", "upstream-ok", NONE, "Authorization: Bearer <AUTH_TOKEN>"),
    ("no x-api-key reaches upstream", "upstream-ok", "x-api-key: <session token>", "x-api-key: (absent)"),
    ("the OAuth beta is added", "upstream-ok", NONE, "anthropic-beta: oauth-2025-04-20"),
    ("the OAuth beta is merged, not replaced", "upstream-ok", "anthropic-beta: interleaved-thinking-2025-05-14",
     "anthropic-beta: interleaved-thinking-2025-05-14,oauth-2025-04-20"),
    ("the OAuth beta is never duplicated", "upstream-ok", "anthropic-beta: oauth-2025-04-20", "anthropic-beta: oauth-2025-04-20"),
    ("anthropic-version passes through", "upstream-ok", "anthropic-version: 2023-06-01", "anthropic-version: 2023-06-01"),
    ("the claude-code session id passes through", "upstream-ok", "X-Claude-Code-Session-Id: 7b1e-uuid", "X-Claude-Code-Session-Id: 7b1e-uuid"),
    ("the user agent passes through (user_agent: forward) ⚖", "upstream-ok", "User-Agent: claude-cli/2.1.281", "User-Agent: claude-cli/2.1.281"),
]


@pytest.mark.parametrize(("upstream", "inbound", "expected_upstream_header"), [r[1:] for r in HEADER_ROWS], ids=[r[0] for r in HEADER_ROWS])
async def test_headers(gw, upstreams, upstream, inbound, expected_upstream_header):
    world(upstream=upstream)
    doc, r = await ride(gw, RAIL, "messages", inbound=inbound, name=inputs(upstream=upstream, inbound=inbound))
    then_eq("status", r.status_code, 200)
    then_eq("expected_upstream_header", headers_seen(upstreams[RAIL].calls[-1], expected_upstream_header, doc, inbound), expected_upstream_header,
            claim=f"upstream_header? = {expected_upstream_header}")


# -- What a 2xx carries back and records ----------------------------------------------------------
OK_ROWS = [  # description | upstream | stream | status? | body? | content_encoding? | recorded?
    ("a messages call lands", "upstream-ok", "false", 200, "the upstream bytes", NONE, "1 · 12 · 0 · 0 · 7"),
    ("a streamed call streams", "upstream-stream", "true", 200, "the upstream bytes", NONE, "1 · 23 · 0 · 0 · 9"),
    ("cache classes are recorded apart", "upstream-ok-cached", "false", 200, "the upstream bytes", NONE, "1 · 12 · 300 · 40 · 7"),
    ("a gzipped stream still counts", "upstream-stream-gzip", "true", 200, "the upstream bytes", "gzip", "1 · 23 · 0 · 0 · 9"),
]


@pytest.mark.parametrize(("upstream", "stream", "expected_status", "expected_body", "expected_content_encoding", "expected_recorded"),
                         [r[1:] for r in OK_ROWS], ids=[r[0] for r in OK_ROWS])
async def test_2xx(gw, upstreams, store, upstream, stream, expected_status, expected_body, expected_content_encoding, expected_recorded):
    world(upstream=upstream)
    got = await oracle(upstreams[RAIL], "messages", MODEL, upstream)
    upstreams[RAIL].behaviour = upstream
    doc, r = await ride(gw, RAIL, "messages", body={"model": MODEL, **({"stream": True} if stream == "true" else {})},
                        name=inputs(upstream=upstream, stream=stream))
    then_eq("expected_status", r.status_code, expected_status, claim=f"status? = {expected_status}")
    with then(f"body? = {expected_body} (same content-type as the upstream's own answer)",
              expected_body={"expected": expected_body, "actual": body_class(r, got[1])},
              content_type={"expected": got[2]["content-type"], "actual": r.headers.get("content-type")}):
        assert body_class(r, got[1]) == expected_body
        assert r.headers.get("content-type") == got[2]["content-type"]
    then_eq("expected_content_encoding", r.headers.get("content-encoding") or NONE, expected_content_encoding,
            claim=f"content_encoding? = {expected_content_encoding}")
    then_eq("expected_recorded", recorded(store, doc), expected_recorded, claim=f"recorded? = {expected_recorded}")


# -- Upstream answers that are not a 2xx ---------------------------------------------------------
ERR_ROWS = [  # description | upstream | status? | body? | retry_after? | requests?
    ("a rate limit passes through", "upstream-429", 429, "the upstream bytes", "30", 1),
    ("an upstream auth failure is typed and hidden", "upstream-401", 424, "upstream-auth envelope", NONE, 1),
    ("an unreachable upstream is typed", "upstream-down", 502, "upstream-unreachable envelope", NONE, 1),
    ("a read past 600 s is a typed timeout", "upstream-slow", 504, "upstream-timeout envelope", NONE, 1),
]


@pytest.mark.parametrize(("upstream", "expected_status", "expected_body", "expected_retry_after", "expected_requests"),
                         [r[1:] for r in ERR_ROWS], ids=[r[0] for r in ERR_ROWS])
async def test_not_2xx(gw, upstreams, transport, store, upstream, expected_status, expected_body, expected_retry_after, expected_requests):
    world(upstream=upstream)
    got = await oracle(upstreams[RAIL], "messages", MODEL, upstream)
    upstreams[RAIL].behaviour = upstream
    apply_transport_world(transport, RAIL, upstream)
    doc, r = await ride(gw, RAIL, "messages", body={"model": MODEL}, name=inputs(upstream=upstream))
    then_eq("expected_status", r.status_code, expected_status, claim=f"status? = {expected_status}")
    with then(f"body? = {expected_body} (no upstream credential hint crosses back)",
              expected_body={"expected": expected_body, "actual": body_class(r, got[1] if got else None)}, body_text={"actual": r.text[:200]}):
        assert body_class(r, got[1] if got else None) == expected_body
        assert "LEAK" not in r.text
    then_eq("expected_retry_after", r.headers.get("retry-after") or NONE, expected_retry_after, claim=f"retry_after? = {expected_retry_after}")
    then_eq("expected_requests", store.get_session(doc["session"]["id"]).requests, expected_requests, claim=f"requests? = {expected_requests}")


# -- The dialect this rail does not speak ---------------------------------------------------------
DIALECT_ROWS = [  # description | upstream | op | status? | code? | upstream_calls?
    ("the openai dialect is not served on the subscription", "upstream-ok", "chat", 501, "dialect-unsupported-on-rail", 0),
    ("the models list is not served on the subscription", "upstream-ok", "models", 501, "dialect-unsupported-on-rail", 0),
]


@pytest.mark.parametrize(("upstream", "op", "expected_status", "expected_code", "expected_upstream_calls"),
                         [r[1:] for r in DIALECT_ROWS], ids=[r[0] for r in DIALECT_ROWS])
async def test_openai_dialect_501(gw, upstreams, store, upstream, op, expected_status, expected_code, expected_upstream_calls):
    world(upstream=upstream)
    path = "/openai/v1/models" if op == "models" else "/openai/v1/chat/completions"
    with given("a session on rail anthropic (reviewer, harness claude)"):
        doc = await open_session(gw, role="reviewer", harness="claude")
    h = {"authorization": f"Bearer {doc['session']['token']}"}
    with when(f"{'GET' if op == 'models' else 'POST'} {path} · {inputs(upstream=upstream, op=op)}"):
        r = await (gw.get(path, headers=h) if op == "models" else gw.post(path, json={"messages": []}, headers=h))
    then_eq("expected_status", r.status_code, expected_status, claim=f"status? = {expected_status}")
    then_eq("expected_code", r.json()["error"]["code"], expected_code, claim=f"code? = {expected_code}")
    then_eq("expected_upstream_calls", len(upstreams[RAIL].calls), expected_upstream_calls, claim=f"upstream_calls? = {expected_upstream_calls}")
    then_eq("requests", store.get_session(doc["session"]["id"]).requests, 0, claim="nothing recorded on the session: requests = 0")


# -- The upstream ---------------------------------------------------------------------------------
URL_ROWS = [  # description | upstream | op | upstream_path? | production_url?
    ("the subscription upstream is api.anthropic.com/v1/messages", "upstream-ok", "messages", "/v1/messages", "https://api.anthropic.com/v1/messages"),
]


@pytest.mark.parametrize(("upstream", "op", "expected_upstream_path", "expected_production_url"), [r[1:] for r in URL_ROWS], ids=[r[0] for r in URL_ROWS])
async def test_upstream_url(gw, upstreams, upstream, op, expected_upstream_path, expected_production_url):
    world(upstream=upstream)
    _, r = await ride(gw, RAIL, op, body={"model": MODEL}, name=inputs(upstream=upstream, op=op))
    then_eq("status", r.status_code, 200)
    then_eq("expected_upstream_path", upstreams[RAIL].calls[-1]["path"], expected_upstream_path, claim=f"upstream_path? = {expected_upstream_path}")
    then_eq("expected_production_url", upstream_url(RAIL, UPSTREAM_DEFAULTS[RAIL], "anthropic", op), expected_production_url,
            claim=f"production_url? = {expected_production_url}")


# -- Stream completeness: the terminal event decides ----------------------------------------------
COMPLETENESS_ROWS = [  # description | upstream | requests_incomplete? | incomplete? | incomplete_total?
    ("a stream that ends without message_stop is recorded incomplete", "upstream-stream-truncated", 1, "no-terminal", 1),
    ("a gzipped stream's message_stop is seen through the encoding", "upstream-stream-gzip", 0, NONE, 0),
]


@pytest.mark.parametrize(("upstream", "expected_requests_incomplete", "expected_incomplete", "expected_incomplete_total"),
                         [r[1:] for r in COMPLETENESS_ROWS], ids=[r[0] for r in COMPLETENESS_ROWS])
async def test_stream_completeness(gw, upstreams, store, upstream, expected_requests_incomplete, expected_incomplete, expected_incomplete_total):
    world(upstream=upstream)
    upstreams[RAIL].behaviour = upstream
    doc, r = await ride(gw, RAIL, "messages", body={"model": MODEL, "stream": True}, name=inputs(upstream=upstream))
    count, reason, _ = incomplete_recorded(store, doc)
    with then(f"status 200; requests_incomplete? = {expected_requests_incomplete}",
              status={"expected": 200, "actual": r.status_code}, expected_requests_incomplete={"expected": expected_requests_incomplete, "actual": count}):
        assert r.status_code == 200 and count == expected_requests_incomplete
    then_eq("expected_incomplete", reason, expected_incomplete, claim=f"incomplete? = {expected_incomplete}")
    series_reason = expected_incomplete if expected_incomplete != NONE else "no-terminal"
    then_eq("expected_incomplete_total", await incomplete_series(gw, RAIL, "anthropic", series_reason), expected_incomplete_total,
            claim=f"incomplete_total? = {expected_incomplete_total} (reason {series_reason})")


# -- Stream completeness: the pod hangs up --------------------------------------------------------
HANGUP_ROWS = [  # description | upstream | requests_incomplete? | incomplete? | incomplete_total?
    ("the client going away mid-stream is recorded incomplete", "upstream-stream", 1, "client-closed", 1),
]


@pytest.mark.parametrize(("upstream", "expected_requests_incomplete", "expected_incomplete", "expected_incomplete_total"),
                         [r[1:] for r in HANGUP_ROWS], ids=[r[0] for r in HANGUP_ROWS])
async def test_client_closed_mid_stream(gw, app, store, upstream, expected_requests_incomplete, expected_incomplete, expected_incomplete_total):
    world(upstream=upstream, note="the gateway's stream is driven directly: the in-process client buffers whole bodies, so a hang-up is the iterator closed early")
    with given("a session on rail anthropic (reviewer, harness claude)"):
        doc = await open_session(gw, role="reviewer", harness="claude")
    row = store.get_session(doc["session"]["id"])

    class _Events(httpx.AsyncByteStream):
        async def __aiter__(self):
            yield b'event: message_start\ndata: {"type":"message_start"}\n\n'
            yield b'event: content_block_delta\ndata: {"type":"content_block_delta"}\n\n'

    resp = httpx.Response(200, headers={"content-type": "text/event-stream"}, stream=_Events())
    with when(f"the {upstream} answer's first chunk is relayed, then the client hangs up (the body iterator is closed) · {inputs(upstream=upstream)}"):
        sr = app.state.proxy._stream(resp, row, "anthropic", 200, {}, True, time.monotonic(), "")
        it = sr.body_iterator
        first = await it.__anext__()
        await it.aclose()
        attach_json("relayed before the hang-up", {"first_chunk": first.decode()})
    count, reason, _ = incomplete_recorded(store, doc)
    then_eq("expected_requests_incomplete", count, expected_requests_incomplete, claim=f"requests_incomplete? = {expected_requests_incomplete}")
    then_eq("expected_incomplete", reason, expected_incomplete, claim=f"incomplete? = {expected_incomplete}")
    then_eq("expected_incomplete_total", await incomplete_series(gw, RAIL, "anthropic", expected_incomplete), expected_incomplete_total,
            claim=f"incomplete_total? = {expected_incomplete_total} (reason {expected_incomplete})")
