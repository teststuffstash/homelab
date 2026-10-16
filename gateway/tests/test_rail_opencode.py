"""GW-RAIL-OPENCODE — the Go rail's wire, both dialects (specs/endpoints/anthropic-messages.md).

| description | dialect | inbound header | upstream header |
|---|---|---|---|
| the Go key rides as x-api-key on the anthropic dialect | anthropic | Authorization: Bearer gws_... | x-api-key: <go key> |
| no bearer reaches the Go anthropic endpoint | anthropic | Authorization: Bearer gws_... | no Authorization |
| the Go key rides as a bearer on the openai dialect | openai | Authorization: Bearer gws_... | Authorization: Bearer <go key> |
| anthropic-beta is dropped | anthropic | anthropic-beta: oauth-2025-04-20 | no anthropic-beta |
| the claude-code session id passes through alone | anthropic | X-Claude-Code-Session-Id: <uuid>, no x-opencode-session | X-Claude-Code-Session-Id: <uuid>, no x-opencode-session |
| the opencode session id passes through alone | openai | x-opencode-session: <id> | x-opencode-session: <id> |
| both session headers pass through | anthropic | both | both, unchanged |
| no session header — the gateway supplies its session id | anthropic | neither | x-opencode-session: <gateway session id> |
| the user agent passes through | openai | User-Agent: opencode/1.18.21 | User-Agent: opencode/1.18.21 |

| description | inbound path | upstream behaviour | upstream URL | status | body |
|---|---|---|---|---|---|
| an anthropic-dialect call lands | POST /anthropic/v1/messages | upstream-ok | https://opencode.ai/zen/go/v1/messages | 200 | byte-identical |
| an openai-dialect call lands | POST /openai/v1/chat/completions | upstream-ok | https://opencode.ai/zen/go/v1/chat/completions | 200 | byte-identical |
| the models list passes through | GET /openai/v1/models | upstream-ok | https://opencode.ai/zen/go/v1/models | 200 | byte-identical |
| a stream streams | POST /openai/v1/chat/completions, stream: true | upstream-stream | .../chat/completions | 200 | SSE bytes unchanged |
| a rate limit passes through | POST /anthropic/v1/messages | upstream-429 | .../messages | 429 | the upstream body, retry-after kept |
| an upstream auth failure is typed and hidden | POST /openai/v1/chat/completions | upstream-401 | .../chat/completions | 502 | upstream-auth envelope |
| the vendor's MissingSessionID is passed through, not masked | POST /anthropic/v1/messages | upstream-400-missing-session | .../messages | 400 | the upstream body |
| an unreachable upstream is typed | POST /anthropic/v1/messages | upstream-down | .../messages | 502 | upstream-unreachable envelope |
| a read past 600 s (WIP: clock-faked) | POST /anthropic/v1/messages | upstream-slow | .../messages | 504 | upstream-timeout |
"""

from __future__ import annotations

import pytest

from agent_gateway.config import UPSTREAM_DEFAULTS
from agent_gateway.rails import OAUTH_BETA, upstream_url

from ._rail_rows import expected_bytes, ride
from .conftest import GO_KEY, err, rule, then, then_eq, world

pytestmark = rule("GW-RAIL-OPENCODE")
RAIL = "opencode"

HEADER_ROWS = [
    ("the Go key rides as x-api-key on the anthropic dialect", "messages", {}, {"x-api-key": GO_KEY}),
    ("no bearer reaches the Go anthropic endpoint", "messages", {}, {"authorization": None}),
    ("the Go key rides as a bearer on the openai dialect", "chat", {}, {"authorization": f"Bearer {GO_KEY}", "x-api-key": None}),
    ("anthropic-beta is dropped", "messages", {"anthropic-beta": OAUTH_BETA}, {"anthropic-beta": None}),
    ("the claude-code session id passes through alone", "messages", {"x-claude-code-session-id": "u1"}, {"x-claude-code-session-id": "u1", "x-opencode-session": None}),
    ("the opencode session id passes through alone", "chat", {"x-opencode-session": "c1"}, {"x-opencode-session": "c1", "x-claude-code-session-id": None}),
    ("both session headers pass through", "messages", {"x-opencode-session": "c1", "x-claude-code-session-id": "u1"}, {"x-opencode-session": "c1", "x-claude-code-session-id": "u1"}),
    ("no session header — the gateway supplies its session id", "messages", {}, {"x-opencode-session": "<session id>"}),
    ("the user agent passes through", "chat", {"user-agent": "opencode/1.18.21"}, {"user-agent": "opencode/1.18.21"}),
]


@pytest.mark.parametrize(("op", "inbound", "expect"), [r[1:] for r in HEADER_ROWS], ids=[r[0] for r in HEADER_ROWS])
async def test_headers(gw, upstreams, op, inbound, expect):
    world(upstream="upstream-ok")
    doc, r = await ride(gw, RAIL, op, headers=inbound)
    then_eq("status", r.status_code, 200)
    call = upstreams[RAIL].calls[-1]
    want = {k: (doc["session"]["id"] if v == "<session id>" else v) for k, v in expect.items()}
    got = {k: call["headers"].get(k) for k in want}
    with then("expect upstream headers " + ", ".join(f"{k} = {v}" for k, v in expect.items()),
              expect={"expected": want, "actual": got}):
        for k, v in want.items():
            assert call["headers"].get(k) == v, (k, call["headers"].get(k))


LAND_ROWS = [
    ("an anthropic-dialect call lands", "messages", "upstream-ok", "/v1/messages"),
    ("an openai-dialect call lands", "chat", "upstream-ok", "/v1/chat/completions"),
    ("the models list passes through", "models", "upstream-ok", "/v1/models"),
    ("a stream streams", "chat", "upstream-stream", "/v1/chat/completions"),
]


@pytest.mark.parametrize(("op", "behaviour", "path"), [r[1:] for r in LAND_ROWS], ids=[r[0] for r in LAND_ROWS])
async def test_calls_land(gw, upstreams, settings, op, behaviour, path):
    world(upstream=behaviour)
    model = "claude-sonnet-4-6" if op == "messages" else "deepseek-v4-flash"
    status, body, headers = await expected_bytes(upstreams[RAIL], op, model, behaviour)
    upstreams[RAIL].behaviour = behaviour
    extra = {"model": model, **({"stream": True} if behaviour == "upstream-stream" else {})} if op != "models" else None
    doc, r = await ride(gw, RAIL, op, body=extra)
    then_eq("status", (r.status_code, status), (200, 200), claim="status = 200 (= the upstream's)")
    with then(f"body = the upstream body under {behaviour}, byte-identical, same content-type",
              body={"expected_len": len(body), "actual_len": len(r.content)},
              content_type={"expected": headers["content-type"], "actual": r.headers["content-type"]}):
        assert r.content == body
        assert r.headers["content-type"] == headers["content-type"]
    dialect = "anthropic" if op == "messages" else "openai"
    prod = upstream_url(RAIL, UPSTREAM_DEFAULTS[RAIL], dialect, op)
    with then(f"upstream path = {path} (production URL https://opencode.ai/zen/go{path})",
              path={"expected": path, "actual": upstreams[RAIL].calls[-1]["path"]},
              production_url={"expected": "https://opencode.ai/zen/go" + path, "actual": prod}):
        assert upstreams[RAIL].calls[-1]["path"] == path
        assert prod == "https://opencode.ai/zen/go" + path


async def test_rate_limit(gw, upstreams):
    """row: a rate limit passes through"""
    world(upstream="upstream-429")
    upstreams[RAIL].behaviour = "upstream-429"
    _, r = await ride(gw, RAIL, "messages")
    then_eq("status", r.status_code, 429)
    then_eq("retry-after", r.headers.get("retry-after"), "30")
    then_eq("body error.type", r.json()["error"]["type"], "rate_limit_error", claim="body = the upstream body (error.type = rate_limit_error)")


async def test_upstream_auth_hidden(gw, upstreams):
    """row: an upstream auth failure is typed and hidden"""
    world(upstream="upstream-401")
    upstreams[RAIL].behaviour = "upstream-401"
    _, r = await ride(gw, RAIL, "chat")
    then_eq("status", r.status_code, 502)
    with then("body = the upstream-auth envelope, not the upstream body (no LEAK marker)", body={"actual": r.text}):
        assert err(r) == "upstream-auth"
        assert "LEAK" not in r.text


async def test_missing_session_id_passthrough(gw, upstreams):
    """row: the vendor's MissingSessionID is passed through, not masked"""
    world(upstream="upstream-400-missing-session")
    upstreams[RAIL].behaviour = "upstream-400-missing-session"
    _, r = await ride(gw, RAIL, "messages")
    then_eq("status", r.status_code, 400)
    then_eq("body type", r.json()["type"], "MissingSessionID", claim="body = the vendor's (type = MissingSessionID)")


async def test_upstream_unreachable(gw, transport):
    """row: an unreachable upstream is typed"""
    world(upstream="upstream-down")
    transport.unreachable.add(RAIL)
    _, r = await ride(gw, RAIL, "messages")
    then_eq("status", r.status_code, 502)
    then_eq("code", err(r), "upstream-unreachable", claim="error code = upstream-unreachable")


async def test_read_past_600s(gw, transport):
    """row: a read past 600 s (WIP: clock-faked)"""
    world(upstream="upstream-slow")
    transport.slow.add(RAIL)
    _, r = await ride(gw, RAIL, "messages")
    then_eq("status", r.status_code, 504)
    then_eq("code", err(r), "upstream-timeout", claim="error code = upstream-timeout")
