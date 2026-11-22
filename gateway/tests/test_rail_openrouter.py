"""GW-RAIL-OPENROUTER — the per-stack OpenRouter rail's wire (specs/endpoints/openai-chat.md; the
provider axis is tests/test_rail_openrouter_providers.py).

One parametrized case per table row: the argnames are the table's header cells (`name?` is
`expected_name`), the ids its description cells, the literals the page's Legend lines. World
`policy-default`, the fake OpenRouter upstream in the behaviour the `upstream` column names; the
session is a worker's on the openrouter rail (harness goose on the openai dialect, claude on the
anthropic one), opened by `ride()`.
"""

from __future__ import annotations

import pytest

from agent_gateway.config import UPSTREAM_DEFAULTS
from agent_gateway.credentials import StaticSecrets
from agent_gateway.rails import upstream_url

from ._rail_rows import (
    NONE,
    apply_transport_world,
    body_class,
    headers_seen,
    inputs,
    op_of,
    oracle,
    recorded,
    ride,
)
from ._stream_rows import incomplete_recorded, incomplete_series
from .conftest import attach_json, given, rule, then, then_eq, world

pytestmark = rule("GW-RAIL-OPENROUTER")
RAIL = "openrouter"
MODEL = "deepseek/deepseek-v4-flash"  # the standard tier: no endpoint snapshot, rides unpinned
ORACLE_KEY = "sk-or-v1-FAKE-oracle-key"
PRODUCTION = "https://openrouter.ai/api"


# -- The stack's key and the headers --------------------------------------------------------------
HEADER_ROWS = [  # description | upstream | stack | op | inbound | upstream_header?
    ("the stack key rides as a bearer on the openai dialect", "upstream-ok", "platform", "chat", NONE, "Authorization: Bearer <OPENROUTER_API_KEY>"),
    ("the stack key rides as a bearer on the anthropic dialect", "upstream-ok", "platform", "messages", "x-api-key: <session token>; Authorization: (none)",
     "Authorization: Bearer <OPENROUTER_API_KEY>; x-api-key: (absent)"),
    ("anthropic-beta is forwarded untouched ⚖ (verify)", "upstream-ok", "platform", "messages", "anthropic-beta: oauth-2025-04-20", "anthropic-beta: oauth-2025-04-20"),
    ("the Go session header is not this rail's business", "upstream-ok", "platform", "chat", "x-opencode-session: c1", "x-opencode-session: c1"),
    ("the user agent passes through (user_agent: forward) ⚖", "upstream-ok", "platform", "chat", "User-Agent: goose/1.x", "User-Agent: goose/1.x"),
    ("the stack's own key is used", "upstream-ok", "oracle", "chat", NONE, "Authorization: Bearer <ORACLE_OPENROUTER_API_KEY>"),
]


@pytest.mark.parametrize(("upstream", "stack", "op", "inbound", "expected_upstream_header"), [r[1:] for r in HEADER_ROWS], ids=[r[0] for r in HEADER_ROWS])
async def test_headers(gw, upstreams, secrets, upstream, stack, op, inbound, expected_upstream_header):
    world(upstream=upstream)
    if stack == "oracle":
        with given("state: stack oracle's ref oracle-agents/oracle-openrouter holds its own key <ORACLE_OPENROUTER_API_KEY>"):
            secrets.secrets["oracle-agents/oracle-openrouter"] = StaticSecrets.secret(ORACLE_KEY, "OPENROUTER_API_KEY")
            attach_json("secret oracle-agents/oracle-openrouter", {"OPENROUTER_API_KEY": "<ORACLE_OPENROUTER_API_KEY>"})
    doc, r = await ride(gw, RAIL, op, inbound=inbound, stack=stack, name=inputs(upstream=upstream, stack=stack, op=op, inbound=inbound))
    then_eq("status", r.status_code, 200)
    seen = headers_seen(upstreams[RAIL].calls[-1], expected_upstream_header, doc, inbound, aliases={ORACLE_KEY: "<ORACLE_OPENROUTER_API_KEY>"})
    then_eq("expected_upstream_header", seen, expected_upstream_header, claim=f"upstream_header? = {expected_upstream_header}")


# -- Where a call lands and what the session records ----------------------------------------------
LAND_ROWS = [  # description | upstream | path | upstream_path? | status? | body? | recorded?
    ("an openai-dialect call lands", "upstream-ok", "/openai/v1/chat/completions", "/v1/chat/completions", 200, "the upstream bytes", "1 · 7 · 0 · 0 · 3"),
    ("an anthropic-dialect call lands", "upstream-ok", "/anthropic/v1/messages", "/v1/messages", 200, "the upstream bytes", "1 · 12 · 0 · 0 · 7"),
    ("the models list passes through", "upstream-ok", "/openai/v1/models", "/v1/models", 200, "the upstream bytes", "1 · 0 · 0 · 0 · 0"),
    ("an openai-dialect cache read is split out ⚖", "upstream-ok-cached", "/openai/v1/chat/completions", "/v1/chat/completions", 200, "the upstream bytes", "1 · 12 · 300 · 0 · 7"),
    ("a stream streams", "upstream-stream", "/openai/v1/chat/completions", "/v1/chat/completions", 200, "the upstream bytes", "1 · 19 · 0 · 0 · 4"),
    ("the /api/v1 alias serves the OpenRouter-shaped path", "upstream-ok", "/api/v1/chat/completions", "/v1/chat/completions", 200, "the upstream bytes", "1 · 7 · 0 · 0 · 3"),
]


@pytest.mark.parametrize(("upstream", "path", "expected_upstream_path", "expected_status", "expected_body", "expected_recorded"),
                         [r[1:] for r in LAND_ROWS], ids=[r[0] for r in LAND_ROWS])
async def test_calls_land(gw, upstreams, store, upstream, path, expected_upstream_path, expected_status, expected_body, expected_recorded):
    world(upstream=upstream)
    op = op_of(path)
    got = await oracle(upstreams[RAIL], op, MODEL, upstream)
    upstreams[RAIL].behaviour = upstream
    body = {"model": MODEL, **({"stream": True} if upstream == "upstream-stream" else {})} if op != "models" else None
    doc, r = await ride(gw, RAIL, path=path, body=body, name=inputs(upstream=upstream, path=path))
    dialect = "anthropic" if op == "messages" else "openai"
    with then(f"upstream_path? = {expected_upstream_path} (the production default {PRODUCTION}{expected_upstream_path})",
              expected_upstream_path={"expected": expected_upstream_path, "actual": upstreams[RAIL].calls[-1]["path"]},
              production_url={"expected": PRODUCTION + expected_upstream_path, "actual": upstream_url(RAIL, UPSTREAM_DEFAULTS[RAIL], dialect, op)}):
        assert upstreams[RAIL].calls[-1]["path"] == expected_upstream_path
        assert upstream_url(RAIL, UPSTREAM_DEFAULTS[RAIL], dialect, op) == PRODUCTION + expected_upstream_path
    then_eq("expected_status", r.status_code, expected_status, claim=f"status? = {expected_status} (= the upstream's {got[0]})")
    with then(f"body? = {expected_body} (same content-type as the upstream's own answer)",
              expected_body={"expected": expected_body, "actual": body_class(r, got[1])},
              content_type={"expected": got[2]["content-type"], "actual": r.headers.get("content-type")}):
        assert body_class(r, got[1]) == expected_body
        assert r.headers.get("content-type") == got[2]["content-type"]
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
    got = await oracle(upstreams[RAIL], "chat", MODEL, upstream)
    upstreams[RAIL].behaviour = upstream
    apply_transport_world(transport, RAIL, upstream)
    doc, r = await ride(gw, RAIL, "chat", body={"model": MODEL}, name=inputs(upstream=upstream))
    then_eq("expected_status", r.status_code, expected_status, claim=f"status? = {expected_status}")
    with then(f"body? = {expected_body} (no upstream credential hint crosses back)",
              expected_body={"expected": expected_body, "actual": body_class(r, got[1] if got else None)}, body_text={"actual": r.text[:200]}):
        assert body_class(r, got[1] if got else None) == expected_body
        assert "LEAK" not in r.text
    then_eq("expected_retry_after", r.headers.get("retry-after") or NONE, expected_retry_after, claim=f"retry_after? = {expected_retry_after}")
    then_eq("expected_requests", store.get_session(doc["session"]["id"]).requests, expected_requests, claim=f"requests? = {expected_requests}")


# -- Stream completeness ---------------------------------------------------------------------------
COMPLETENESS_ROWS = [  # description | upstream | cut | stream | requests_incomplete? | incomplete? | row_status? | incomplete_total?
    ("a stream that ends without [DONE] is recorded incomplete", "upstream-stream-truncated", NONE, "true", 1, "no-terminal", 200, 1),
    ("a stream that ends with [DONE] is complete", "upstream-stream", NONE, "true", 0, NONE, 200, 0),
    ("a non-streamed answer read to its end is complete", "upstream-ok", NONE, "false", 0, NONE, 200, 0),
    ("a stream cut by a read timeout is recorded incomplete", "upstream-stream-cut", "timeout", "true", 1, "timeout", 504, 1),
    ("a stream cut by the transport is recorded incomplete", "upstream-stream-cut", "transport-error", "true", 1, "transport-error", 200, 1),
]


@pytest.mark.parametrize(("upstream", "cut", "stream", "expected_requests_incomplete", "expected_incomplete", "expected_row_status", "expected_incomplete_total"),
                         [r[1:] for r in COMPLETENESS_ROWS], ids=[r[0] for r in COMPLETENESS_ROWS])
async def test_stream_completeness(gw, upstreams, transport, store, upstream, cut, stream, expected_requests_incomplete, expected_incomplete,
                                   expected_row_status, expected_incomplete_total):
    world(upstream=upstream, note=None if cut == NONE else f"cut = {cut}")
    with given(f"the upstream answers {upstream}" + (f"; the transport cuts the body after its first chunk (cut = {cut})" if cut != NONE else "")):
        upstreams[RAIL].behaviour = "upstream-stream" if upstream == "upstream-stream-cut" else upstream
        if cut != NONE:
            transport.cut[RAIL] = cut
    try:
        doc, r = await ride(gw, RAIL, "chat", body={"model": MODEL, **({"stream": True} if stream == "true" else {})},
                            name=inputs(upstream=upstream, cut=cut, stream=stream))
    except Exception:  # noqa: BLE001 — a cut stream surfaces in the in-process client as the gateway's re-raise
        doc = await _last_session(store)
    count, reason, row_status = incomplete_recorded(store, doc)
    then_eq("expected_requests_incomplete", count, expected_requests_incomplete, claim=f"requests_incomplete? = {expected_requests_incomplete}")
    then_eq("expected_incomplete", reason, expected_incomplete, claim=f"incomplete? = {expected_incomplete}")
    then_eq("expected_row_status", row_status, expected_row_status, claim=f"row_status? = {expected_row_status}")
    series_reason = expected_incomplete if expected_incomplete != NONE else "no-terminal"
    then_eq("expected_incomplete_total", await incomplete_series(gw, RAIL, "openai", series_reason), expected_incomplete_total,
            claim=f"incomplete_total? = {expected_incomplete_total} (reason {series_reason})")


async def _last_session(store) -> dict:
    """The session the cut ride opened (its dispatch answer was consumed inside ride())."""
    with store._lock:
        (sid,) = store._db.execute("SELECT id FROM sessions ORDER BY created_at DESC, rowid DESC LIMIT 1").fetchone()
    return {"session": {"id": sid}}
