"""GW-RAIL-OPENROUTER — the per-stack OpenRouter rail's wire (specs/endpoints/openai-chat.md).

| description | dialect | inbound header | upstream header |
|---|---|---|---|
| the stack key rides as a bearer on the openai dialect | openai | Authorization: Bearer gws_... | Authorization: Bearer <OPENROUTER_API_KEY> |
| the stack key rides as a bearer on the anthropic dialect | anthropic | x-api-key: gws_... | Authorization: Bearer <OPENROUTER_API_KEY>, no x-api-key |
| anthropic-beta is forwarded untouched (verify) | anthropic | anthropic-beta: oauth-2025-04-20 | anthropic-beta: oauth-2025-04-20 |
| the Go session header is not this rail's business | openai | x-opencode-session: <id> | x-opencode-session: <id> (passthrough) |
| the user agent passes through | openai | User-Agent: goose/1.x | User-Agent: goose/1.x |
| the stack's own key is used | openai | stack oracle | Authorization: Bearer <oracle's key> |

| description | inbound path | upstream behaviour | upstream URL | status | body | recorded on the session |
|---|---|---|---|---|---|---|
| an openai-dialect call lands | POST /openai/v1/chat/completions | upstream-ok | https://openrouter.ai/api/v1/chat/completions | 200 | byte-identical | requests +1, tokens_in = usage.prompt_tokens, tokens_out = usage.completion_tokens |
| an anthropic-dialect call lands | POST /anthropic/v1/messages | upstream-ok | https://openrouter.ai/api/v1/messages | 200 | byte-identical | tokens_in = usage.input_tokens, tokens_out = usage.output_tokens |
| the models list passes through | GET /openai/v1/models | upstream-ok | https://openrouter.ai/api/v1/models | 200 | byte-identical | nothing |
| a stream streams | POST /openai/v1/chat/completions, stream: true | upstream-stream | .../chat/completions | 200 | SSE bytes unchanged | tokens from the last chunk's usage |
| a rate limit passes through | POST /openai/v1/chat/completions | upstream-429 | .../chat/completions | 429 | the upstream body, retry-after kept | requests +1 |
| an upstream auth failure is typed and hidden | POST /openai/v1/chat/completions | upstream-401 | .../chat/completions | 502 | upstream-auth envelope | requests +1 |
| an unreachable upstream is typed | POST /openai/v1/chat/completions | upstream-down | .../chat/completions | 502 | upstream-unreachable envelope | requests +1 |
| a read past 600 s (WIP: clock-faked) | POST /openai/v1/chat/completions | upstream-slow | .../chat/completions | 504 | upstream-timeout | requests +1 |
| the /api/v1 alias serves the OpenRouter-shaped path | POST /api/v1/chat/completions | upstream-ok | .../chat/completions | 200 | byte-identical | requests +1 |
"""

from __future__ import annotations

import pytest

from agent_gateway.config import UPSTREAM_DEFAULTS
from agent_gateway.credentials import StaticSecrets
from agent_gateway.rails import OAUTH_BETA, upstream_url

from ._rail_rows import expected_bytes, ride
from .conftest import OPENROUTER_KEY, bearer, err, open_session, rule

pytestmark = rule("GW-RAIL-OPENROUTER")
RAIL = "openrouter"

HEADER_ROWS = [
    ("the stack key rides as a bearer on the openai dialect", "chat", {}, {"authorization": f"Bearer {OPENROUTER_KEY}"}),
    ("the stack key rides as a bearer on the anthropic dialect", "messages", {"x-api-key": "<token>", "authorization": None}, {"authorization": f"Bearer {OPENROUTER_KEY}", "x-api-key": None}),
    ("anthropic-beta is forwarded untouched (verify)", "messages", {"anthropic-beta": OAUTH_BETA}, {"anthropic-beta": OAUTH_BETA}),
    ("the Go session header is not this rail's business", "chat", {"x-opencode-session": "c1"}, {"x-opencode-session": "c1"}),
    ("the user agent passes through", "chat", {"user-agent": "goose/1.x"}, {"user-agent": "goose/1.x"}),
]


@pytest.mark.parametrize(("op", "inbound", "expect"), [r[1:] for r in HEADER_ROWS], ids=[r[0] for r in HEADER_ROWS])
async def test_headers(gw, upstreams, op, inbound, expect):
    doc = await open_session(gw, role="worker", harness="claude" if op == "messages" else "goose", rail=RAIL)
    token = doc["session"]["token"]
    headers = {**bearer(doc), **{k: (token if v == "<token>" else v) for k, v in inbound.items() if v is not None}}
    if inbound.get("authorization", "x") is None:
        headers.pop("authorization")
    path = "/anthropic/v1/messages" if op == "messages" else "/openai/v1/chat/completions"
    r = await gw.post(path, json={"messages": []}, headers=headers)
    assert r.status_code == 200, r.text
    call = upstreams[RAIL].calls[-1]
    for k, v in expect.items():
        assert call["headers"].get(k) == v, (k, call["headers"].get(k))


async def test_stack_key(gw, upstreams, secrets):
    """row: the stack's own key is used"""
    oracle_key = "sk-or-v1-FAKE-oracle-key"
    secrets.secrets["oracle-agents/oracle-openrouter"] = StaticSecrets.secret(oracle_key, "OPENROUTER_API_KEY")
    doc = await open_session(gw, stack="oracle", role="worker", harness="goose", rail=RAIL)
    r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    assert r.status_code == 200
    assert upstreams[RAIL].calls[-1]["headers"]["authorization"] == f"Bearer {oracle_key}"


LAND_ROWS = [
    ("an openai-dialect call lands", "chat", "upstream-ok", "/v1/chat/completions", (1, 7, 3)),
    ("an anthropic-dialect call lands", "messages", "upstream-ok", "/v1/messages", (1, 11, 5)),
    ("the models list passes through", "models", "upstream-ok", "/v1/models", (0, 0, 0)),
    ("a stream streams", "chat", "upstream-stream", "/v1/chat/completions", (1, 19, 4)),
]


@pytest.mark.parametrize(("op", "behaviour", "path", "recorded"), [r[1:] for r in LAND_ROWS], ids=[r[0] for r in LAND_ROWS])
async def test_calls_land(gw, upstreams, store, op, behaviour, path, recorded):
    model = "deepseek/deepseek-v4-flash"
    status, body, headers = await expected_bytes(upstreams[RAIL], op, model, behaviour)
    upstreams[RAIL].behaviour = behaviour
    extra = {"model": model, **({"stream": True} if behaviour == "upstream-stream" else {})} if op != "models" else None
    doc, r = await ride(gw, RAIL, op, body=extra)
    assert r.status_code == status == 200 and r.content == body
    assert r.headers["content-type"] == headers["content-type"]
    assert upstreams[RAIL].calls[-1]["path"] == path
    dialect = "anthropic" if op == "messages" else "openai"
    assert upstream_url(RAIL, UPSTREAM_DEFAULTS[RAIL], dialect, op) == "https://openrouter.ai/api" + path
    row = store.get_session(doc["session"]["id"])
    if op == "models":
        assert row.requests == 1 and (row.tokens_in, row.tokens_out) == (0, 0)
    else:
        assert (row.requests, row.tokens_in, row.tokens_out) == recorded


async def test_rate_limit(gw, upstreams, store):
    """row: a rate limit passes through"""
    upstreams[RAIL].behaviour = "upstream-429"
    doc, r = await ride(gw, RAIL, "chat")
    assert r.status_code == 429 and r.headers["retry-after"] == "30"
    assert store.get_session(doc["session"]["id"]).requests == 1


async def test_upstream_auth_hidden(gw, upstreams, store):
    """row: an upstream auth failure is typed and hidden"""
    upstreams[RAIL].behaviour = "upstream-401"
    doc, r = await ride(gw, RAIL, "chat")
    assert r.status_code == 502 and err(r) == "upstream-auth" and "LEAK" not in r.text
    assert store.get_session(doc["session"]["id"]).requests == 1


async def test_upstream_unreachable(gw, transport, store):
    """row: an unreachable upstream is typed"""
    transport.unreachable.add(RAIL)
    doc, r = await ride(gw, RAIL, "chat")
    assert r.status_code == 502 and err(r) == "upstream-unreachable"
    assert store.get_session(doc["session"]["id"]).requests == 1


async def test_read_past_600s(gw, transport, store):
    """row: a read past 600 s (WIP: clock-faked)"""
    transport.slow.add(RAIL)
    doc, r = await ride(gw, RAIL, "chat")
    assert r.status_code == 504 and err(r) == "upstream-timeout"
    assert store.get_session(doc["session"]["id"]).requests == 1


async def test_api_v1_alias(gw, upstreams, store):
    """row: the /api/v1 alias serves the OpenRouter-shaped path"""
    status, body, _ = await expected_bytes(upstreams[RAIL], "chat", "deepseek/deepseek-v4-flash", "upstream-ok")
    doc, r = await ride(gw, RAIL, "chat", path="/api/v1/chat/completions")
    assert r.status_code == 200 and r.content == body
    assert upstreams[RAIL].calls[-1]["path"] == "/v1/chat/completions"
    assert store.get_session(doc["session"]["id"]).requests == 1
