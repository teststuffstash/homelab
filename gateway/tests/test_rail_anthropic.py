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
| a rate limit passes through | POST /anthropic/v1/messages | upstream-429 | 429 | the upstream body, retry-after kept | requests +1 |
| an upstream auth failure is typed and hidden | POST /anthropic/v1/messages | upstream-401 | 502 | upstream-auth envelope | requests +1 |
| the openai dialect is not served on the subscription | POST /openai/v1/chat/completions | (no upstream call) | 501 | dialect-unsupported-on-rail | nothing |
| the models list is not served on the subscription | GET /openai/v1/models | (no upstream call) | 501 | dialect-unsupported-on-rail | nothing |
| an unreachable upstream is typed | POST /anthropic/v1/messages | upstream-down | 502 | upstream-unreachable envelope | requests +1 |
| a read past 600 s (WIP: clock-faked) | POST /anthropic/v1/messages | upstream-slow | 504 | upstream-timeout | requests +1 |
| the upstream URL is api.anthropic.com/v1/messages | — | — | — | — | — |
"""

from __future__ import annotations

import pytest

from agent_gateway.rails import OAUTH_BETA, upstream_url

from ._rail_rows import expected_bytes, ride
from .conftest import ANTHROPIC_TOKEN, UPSTREAM_BASES, bearer, err, open_session, rule

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
    doc, r = await ride(gw, RAIL, "messages", headers=inbound)
    assert r.status_code == 200, r.text
    call = upstreams[RAIL].calls[-1]
    assert call["path"] == "/v1/messages"
    for k, v in expect.items():
        assert call["headers"].get(k) == v, (k, call["headers"].get(k))


def test_upstream_url(settings):
    """row: the upstream URL is api.anthropic.com/v1/messages"""
    assert upstream_url(RAIL, settings.upstreams[RAIL], "anthropic", "messages") == UPSTREAM_BASES[RAIL] + "/v1/messages"
    from agent_gateway.config import UPSTREAM_DEFAULTS

    assert upstream_url(RAIL, UPSTREAM_DEFAULTS[RAIL], "anthropic", "messages") == "https://api.anthropic.com/v1/messages"


async def test_messages_call_lands(gw, upstreams, policy, store):
    """row: a messages call lands"""
    status, body, headers = await expected_bytes(upstreams[RAIL], "messages", "claude-sonnet-4-6", "upstream-ok")
    doc, r = await ride(gw, RAIL, "messages", body={"model": "claude-sonnet-4-6"})
    assert r.status_code == status == 200 and r.content == body
    assert r.headers["content-type"] == headers["content-type"]
    row = store.get_session(doc["session"]["id"])
    assert (row.requests, row.tokens_in, row.tokens_out) == (1, 11, 5)


async def test_streamed_call_streams(gw, upstreams, store):
    """row: a streamed call streams"""
    status, body, headers = await expected_bytes(upstreams[RAIL], "messages", "claude-sonnet-4-6", "upstream-stream")
    upstreams[RAIL].behaviour = "upstream-stream"
    doc, r = await ride(gw, RAIL, "messages", body={"model": "claude-sonnet-4-6", "stream": True})
    assert r.status_code == 200 and r.content == body
    assert r.headers["content-type"].startswith("text/event-stream")
    row = store.get_session(doc["session"]["id"])
    assert (row.requests, row.tokens_in, row.tokens_out) == (1, 23, 9)


async def test_rate_limit_passes_through(gw, upstreams, store):
    """row: a rate limit passes through"""
    upstreams[RAIL].behaviour = "upstream-429"
    doc, r = await ride(gw, RAIL, "messages")
    assert r.status_code == 429 and r.headers["retry-after"] == "30"
    assert r.json()["error"]["type"] == "rate_limit_error"
    assert store.get_session(doc["session"]["id"]).requests == 1


async def test_upstream_auth_hidden(gw, upstreams, store):
    """row: an upstream auth failure is typed and hidden"""
    upstreams[RAIL].behaviour = "upstream-401"
    doc, r = await ride(gw, RAIL, "messages")
    assert r.status_code == 502 and err(r) == "upstream-auth"
    assert "LEAK" not in r.text and store.get_session(doc["session"]["id"]).requests == 1


DIALECT_ROWS = [("the openai dialect is not served on the subscription", "chat"), ("the models list is not served on the subscription", "models")]


@pytest.mark.parametrize("op", [r[1] for r in DIALECT_ROWS], ids=[r[0] for r in DIALECT_ROWS])
async def test_openai_dialect_501(gw, upstreams, store, op):
    doc = await open_session(gw, role="reviewer", harness="claude")
    r = await (gw.get("/openai/v1/models", headers=bearer(doc)) if op == "models" else gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc)))
    assert r.status_code == 501 and err(r) == "dialect-unsupported-on-rail"
    assert upstreams[RAIL].calls == [] and store.get_session(doc["session"]["id"]).requests == 0


async def test_upstream_unreachable(gw, transport, store):
    """row: an unreachable upstream is typed"""
    transport.unreachable.add(RAIL)
    doc, r = await ride(gw, RAIL, "messages")
    assert r.status_code == 502 and err(r) == "upstream-unreachable"
    assert store.get_session(doc["session"]["id"]).requests == 1


async def test_read_past_600s(gw, transport, store):
    """row: a read past 600 s (WIP: clock-faked)"""
    transport.slow.add(RAIL)
    doc, r = await ride(gw, RAIL, "messages")
    assert r.status_code == 504 and err(r) == "upstream-timeout"
    assert store.get_session(doc["session"]["id"]).requests == 1
