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
| an openai-dialect cache read is split out | POST /openai/v1/chat/completions | upstream-ok-cached | .../chat/completions | 200 | byte-identical | (requests, tokens_in, tokens_cache_read, tokens_cache_write, tokens_out) = (1, 12, 300, 0, 7): tokens_in = prompt_tokens - cached_tokens |
| a stream streams | POST /openai/v1/chat/completions, stream: true | upstream-stream | .../chat/completions | 200 | SSE bytes unchanged | tokens from the last chunk's usage |
| a rate limit passes through | POST /openai/v1/chat/completions | upstream-429 | .../chat/completions | 429 | the upstream body, retry-after kept | requests +1 |
| an upstream auth failure is typed and hidden | POST /openai/v1/chat/completions | upstream-401 | .../chat/completions | 424 | upstream-auth envelope | requests +1 |
| an unreachable upstream is typed | POST /openai/v1/chat/completions | upstream-down | .../chat/completions | 502 | upstream-unreachable envelope | requests +1 |
| a read past 600 s (WIP: clock-faked) | POST /openai/v1/chat/completions | upstream-slow | .../chat/completions | 504 | upstream-timeout | requests +1 |
| the /api/v1 alias serves the OpenRouter-shaped path | POST /api/v1/chat/completions | upstream-ok | .../chat/completions | 200 | byte-identical | requests +1 |

Stream completeness (openai dialect; terminal event = `data: [DONE]`):

| description | inbound path | upstream behaviour | status | recorded on the session | gateway_requests_incomplete_total{rail="openrouter",dialect="openai",reason} |
|---|---|---|---|---|---|
| a stream that ends without [DONE] is recorded incomplete | POST /openai/v1/chat/completions, stream: true | upstream-stream-truncated | 200 | requests_incomplete 1; the request row's incomplete = no-terminal | no-terminal = 1 |
| a stream that ends with [DONE] is complete | POST /openai/v1/chat/completions, stream: true | upstream-stream | 200 | requests_incomplete 0; incomplete = null | no-terminal = 0 |
| a non-streamed answer read to its end is complete | POST /openai/v1/chat/completions | upstream-ok | 200 | requests_incomplete 0; incomplete = null | no-terminal = 0 |
| a stream cut by a read timeout is recorded incomplete | POST /openai/v1/chat/completions, stream: true | upstream-stream-cut (timeout) | 200 sent, row 504 | requests_incomplete 1; incomplete = timeout | timeout = 1 |
| a stream cut by the transport is recorded incomplete | POST /openai/v1/chat/completions, stream: true | upstream-stream-cut (transport-error) | 200 | requests_incomplete 1; incomplete = transport-error | transport-error = 1 |
"""

from __future__ import annotations

import pytest

from agent_gateway.config import UPSTREAM_DEFAULTS
from agent_gateway.credentials import StaticSecrets
from agent_gateway.rails import OAUTH_BETA, upstream_url

from ._rail_rows import expected_bytes, ride
from ._stream_rows import incomplete_series, recorded_incomplete
from .conftest import (
    OPENROUTER_KEY,
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

pytestmark = rule("GW-RAIL-OPENROUTER")
RAIL = "openrouter"

HEADER_ROWS = [
    ("the stack key rides as a bearer on the openai dialect", "chat", {}, {"authorization": f"Bearer {OPENROUTER_KEY}"}),
    ("the stack key rides as a bearer on the anthropic dialect", "messages", {"x-api-key": "<token>", "authorization": None}, {"authorization": f"Bearer {OPENROUTER_KEY}", "x-api-key": None}),
    ("anthropic-beta is forwarded untouched (verify)", "messages", {"anthropic-beta": OAUTH_BETA}, {"anthropic-beta": OAUTH_BETA}),
    ("the Go session header is not this rail's business", "chat", {"x-opencode-session": "c1"}, {"x-opencode-session": "c1"}),
    ("the user agent passes through", "chat", {"user-agent": "goose/1.x"}, {"user-agent": "goose/1.x"}),
]


def _recorded(store, doc, want: tuple, what: str = "requests"):
    with then(f"recorded on the session: {what} = {want if len(want) > 1 else want[0]}"):
        row = store.get_session(doc["session"]["id"])
        got = (row.requests, row.tokens_in, row.tokens_out) if len(want) == 3 else (row.requests,)
        check(what, got, want)


@pytest.mark.parametrize(("op", "inbound", "expect"), [r[1:] for r in HEADER_ROWS], ids=[r[0] for r in HEADER_ROWS])
async def test_headers(gw, upstreams, op, inbound, expect):
    world(upstream="upstream-ok")
    harness = "claude" if op == "messages" else "goose"
    with given(f"a session on rail openrouter (worker, harness {harness})"):
        doc = await open_session(gw, role="worker", harness=harness, rail=RAIL)
    token = doc["session"]["token"]
    headers = {**bearer(doc), **{k: (token if v == "<token>" else v) for k, v in inbound.items() if v is not None}}
    if inbound.get("authorization", "x") is None:
        headers.pop("authorization")
    path = "/anthropic/v1/messages" if op == "messages" else "/openai/v1/chat/completions"
    with when(f"POST {path} op={op} · inbound {inbound or '(no extra headers)'}"):
        r = await gw.post(path, json={"messages": []}, headers=headers)
    then_eq("status", r.status_code, 200)
    call = upstreams[RAIL].calls[-1]
    with then("expect upstream headers " + ", ".join(f"{k} = {v}" for k, v in expect.items()),
              expect={"expected": expect, "actual": {k: call["headers"].get(k) for k in expect}}):
        for k, v in expect.items():
            assert call["headers"].get(k) == v, (k, call["headers"].get(k))


async def test_stack_key(gw, upstreams, secrets):
    """row: the stack's own key is used"""
    world(upstream="upstream-ok")
    oracle_key = "sk-or-v1-FAKE-oracle-key"
    with given("state: stack oracle's ref oracle-agents/oracle-openrouter holds its own key"):
        secrets.secrets["oracle-agents/oracle-openrouter"] = StaticSecrets.secret(oracle_key, "OPENROUTER_API_KEY")
        attach_json("secret oracle-agents/oracle-openrouter", {"OPENROUTER_API_KEY": oracle_key})
    with given("a session on rail openrouter (stack oracle, worker, harness goose)"):
        doc = await open_session(gw, stack="oracle", role="worker", harness="goose", rail=RAIL)
    with when("POST /openai/v1/chat/completions on the oracle session"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 200)
    then_eq("upstream authorization", upstreams[RAIL].calls[-1]["headers"]["authorization"], f"Bearer {oracle_key}",
            claim="upstream authorization = Bearer <oracle's key>")


LAND_ROWS = [
    ("an openai-dialect call lands", "chat", "upstream-ok", "/v1/chat/completions", (1, 7, 3)),
    ("an anthropic-dialect call lands", "messages", "upstream-ok", "/v1/messages", (1, 12, 7)),
    ("the models list passes through", "models", "upstream-ok", "/v1/models", (0, 0, 0)),
    ("a stream streams", "chat", "upstream-stream", "/v1/chat/completions", (1, 19, 4)),
]


@pytest.mark.parametrize(("op", "behaviour", "path", "recorded"), [r[1:] for r in LAND_ROWS], ids=[r[0] for r in LAND_ROWS])
async def test_calls_land(gw, upstreams, store, op, behaviour, path, recorded):
    world(upstream=behaviour)
    model = "deepseek/deepseek-v4-flash"
    status, body, headers = await expected_bytes(upstreams[RAIL], op, model, behaviour)
    upstreams[RAIL].behaviour = behaviour
    extra = {"model": model, **({"stream": True} if behaviour == "upstream-stream" else {})} if op != "models" else None
    doc, r = await ride(gw, RAIL, op, body=extra)
    then_eq("status", (r.status_code, status), (200, 200), claim="status = 200 (= the upstream's)")
    dialect = "anthropic" if op == "messages" else "openai"
    prod = upstream_url(RAIL, UPSTREAM_DEFAULTS[RAIL], dialect, op)
    with then(f"body = the upstream body under {behaviour}, byte-identical, same content-type, from upstream path {path} "
              f"(production URL https://openrouter.ai/api{path})",
              body={"expected_len": len(body), "actual_len": len(r.content)},
              content_type={"expected": headers["content-type"], "actual": r.headers["content-type"]},
              path={"expected": path, "actual": upstreams[RAIL].calls[-1]["path"]},
              production_url={"expected": "https://openrouter.ai/api" + path, "actual": prod}):
        assert r.content == body
        assert r.headers["content-type"] == headers["content-type"]
        assert upstreams[RAIL].calls[-1]["path"] == path
        assert prod == "https://openrouter.ai/api" + path
    with then(f"recorded on the session: (requests, tokens_in, tokens_out) = {(1, 0, 0) if op == 'models' else recorded}"):
        row = store.get_session(doc["session"]["id"])
        got = (row.requests, row.tokens_in, row.tokens_out)
        if op == "models":
            check("recorded", got, (1, 0, 0))
        else:
            check("recorded", got, recorded)


async def test_openai_cache_read_split_out(gw, upstreams, store):
    """row: an openai-dialect cache read is split out"""
    world(upstream="upstream-ok-cached")
    model = "deepseek/deepseek-v4-flash"
    status, body, _headers = await expected_bytes(upstreams[RAIL], "chat", model, "upstream-ok-cached")
    upstreams[RAIL].behaviour = "upstream-ok-cached"
    doc, r = await ride(gw, RAIL, "chat", body={"model": model})
    then_eq("status", (r.status_code, status), (200, 200), claim="status = 200 (= the upstream's)")
    with then("body = the upstream body, byte-identical", body={"expected_len": len(body), "actual_len": len(r.content)}):
        assert r.content == body
    what = "(requests, tokens_in, tokens_cache_read, tokens_cache_write, tokens_out)"
    with then(f"recorded on the session: {what} = (1, 12, 300, 0, 7) — prompt_tokens 312 includes cached_tokens 300"):
        row = store.get_session(doc["session"]["id"])
        check(what, (row.requests, row.tokens_in, row.tokens_cache_read, row.tokens_cache_write, row.tokens_out), (1, 12, 300, 0, 7))


async def test_rate_limit(gw, upstreams, store):
    """row: a rate limit passes through"""
    world(upstream="upstream-429")
    upstreams[RAIL].behaviour = "upstream-429"
    doc, r = await ride(gw, RAIL, "chat")
    then_eq("status", r.status_code, 429)
    then_eq("retry-after", r.headers.get("retry-after"), "30")
    _recorded(store, doc, (1,))


async def test_upstream_auth_hidden(gw, upstreams, store):
    """row: an upstream auth failure is typed and hidden"""
    world(upstream="upstream-401")
    upstreams[RAIL].behaviour = "upstream-401"
    doc, r = await ride(gw, RAIL, "chat")
    then_eq("status", r.status_code, 424)
    with then("body = the upstream-auth envelope, not the upstream body (no LEAK marker)", body={"actual": r.text}):
        assert err(r) == "upstream-auth"
        assert "LEAK" not in r.text
    _recorded(store, doc, (1,))


async def test_upstream_unreachable(gw, transport, store):
    """row: an unreachable upstream is typed"""
    world(upstream="upstream-down")
    transport.unreachable.add(RAIL)
    doc, r = await ride(gw, RAIL, "chat")
    then_eq("status", r.status_code, 502)
    then_eq("code", err(r), "upstream-unreachable", claim="error code = upstream-unreachable")
    _recorded(store, doc, (1,))


async def test_read_past_600s(gw, transport, store):
    """row: a read past 600 s (WIP: clock-faked)"""
    world(upstream="upstream-slow")
    transport.slow.add(RAIL)
    doc, r = await ride(gw, RAIL, "chat")
    then_eq("status", r.status_code, 504)
    then_eq("code", err(r), "upstream-timeout", claim="error code = upstream-timeout")
    _recorded(store, doc, (1,))


async def test_api_v1_alias(gw, upstreams, store):
    """row: the /api/v1 alias serves the OpenRouter-shaped path"""
    world(upstream="upstream-ok")
    status, body, _ = await expected_bytes(upstreams[RAIL], "chat", "deepseek/deepseek-v4-flash", "upstream-ok")
    doc, r = await ride(gw, RAIL, "chat", path="/api/v1/chat/completions")
    then_eq("status", r.status_code, 200)
    with then("body = the upstream body, byte-identical, from upstream path /v1/chat/completions",
              body={"expected_len": len(body), "actual_len": len(r.content)},
              path={"expected": "/v1/chat/completions", "actual": upstreams[RAIL].calls[-1]["path"]}):
        assert r.content == body
        assert upstreams[RAIL].calls[-1]["path"] == "/v1/chat/completions"
    _recorded(store, doc, (1,))


COMPLETENESS_ROWS = [
    ("a stream that ends without [DONE] is recorded incomplete", "upstream-stream-truncated", None, True, 1, "no-terminal"),
    ("a stream that ends with [DONE] is complete", "upstream-stream", None, True, 0, None),
    ("a non-streamed answer read to its end is complete", "upstream-ok", None, False, 0, None),
    ("a stream cut by a read timeout is recorded incomplete", "upstream-stream", "timeout", True, 1, "timeout"),
    ("a stream cut by the transport is recorded incomplete", "upstream-stream", "transport-error", True, 1, "transport-error"),
]


@pytest.mark.parametrize(("behaviour", "cut", "stream", "count", "reason"), [r[1:] for r in COMPLETENESS_ROWS], ids=[r[0] for r in COMPLETENESS_ROWS])
async def test_stream_completeness(gw, upstreams, transport, store, behaviour, cut, stream, count, reason):
    world(upstream=behaviour if cut is None else "upstream-stream-cut", note=None if cut is None else f"cut: {cut}")
    with given(f"cut = {cut}: the upstream answers {behaviour}" + (f", the transport cuts it ({cut})" if cut else ", uncut")):
        upstreams[RAIL].behaviour = behaviour
        if cut is not None:
            transport.cut[RAIL] = cut
    try:
        doc, r = await ride(gw, RAIL, "chat", body={"stream": True} if stream else None)
    except Exception:  # noqa: BLE001 — a cut stream surfaces in the in-process client as the gateway's re-raise
        doc = await _last_session(gw, store)
    recorded_incomplete(store, doc, count, reason)
    with then(f"count = {count}: gateway_requests_incomplete_total{{rail=openrouter,dialect=openai,reason={reason or 'no-terminal'}}} = {count}"):
        check("series", await incomplete_series(gw, RAIL, "openai", reason or "no-terminal"), count)


async def _last_session(gw, store) -> dict:
    """The session the cut ride opened (its dispatch answer was consumed inside ride())."""
    with store._lock:
        (sid,) = store._db.execute("SELECT id FROM sessions ORDER BY created_at DESC, rowid DESC LIMIT 1").fetchone()
    return {"session": {"id": sid}}
