"""GW-RAIL-OPENCODE — the Go rail's wire, both dialects (specs/endpoints/anthropic-messages.md).

One parametrized case per table row: the argnames are the table's header cells (`name?` is
`expected_name`), the ids its description cells, the literals the page's Legend lines. World
`policy-default`, the fake Go upstream in the behaviour the `upstream` column names; `op` picks the
session's harness (`messages` → a claude reviewer pinned to the Go rail, `chat` / `models` → an
opencode worker), opened by `ride()`.
"""

from __future__ import annotations

import pytest

from agent_gateway.config import UPSTREAM_DEFAULTS
from agent_gateway.rails import upstream_url

from ._rail_rows import NONE, apply_transport_world, body_class, headers_seen, inputs, oracle, recorded, ride
from .conftest import rule, then, then_eq, world

pytestmark = rule("GW-RAIL-OPENCODE")
RAIL = "opencode"
MODEL = {"messages": "claude-haiku-5-5", "chat": "deepseek-v4.1-flash", "models": None}  # the wire ids of the policy's Go tiers


async def _header_case(gw, upstreams, upstream, op, inbound, expected_upstream_header):
    world(upstream=upstream)
    doc, r = await ride(gw, RAIL, op, inbound=inbound, name=inputs(upstream=upstream, op=op, inbound=inbound))
    then_eq("status", r.status_code, 200)
    then_eq("expected_upstream_header", headers_seen(upstreams[RAIL].calls[-1], expected_upstream_header, doc, inbound), expected_upstream_header,
            claim=f"upstream_header? = {expected_upstream_header}")


# -- The Go credential and the beta ---------------------------------------------------------------
CREDENTIAL_ROWS = [  # description | upstream | op | inbound | upstream_header?
    ("the Go key rides as x-api-key on the anthropic dialect", "upstream-ok", "messages", NONE, "x-api-key: <OPENCODE_GO_API_KEY>"),
    ("no bearer reaches the Go anthropic endpoint", "upstream-ok", "messages", NONE, "Authorization: (absent)"),
    ("the Go key rides as a bearer on the openai dialect", "upstream-ok", "chat", NONE, "Authorization: Bearer <OPENCODE_GO_API_KEY>; x-api-key: (absent)"),
    ("anthropic-beta is dropped", "upstream-ok", "messages", "anthropic-beta: oauth-2025-04-20", "anthropic-beta: (absent)"),
]


@pytest.mark.parametrize(("upstream", "op", "inbound", "expected_upstream_header"), [r[1:] for r in CREDENTIAL_ROWS], ids=[r[0] for r in CREDENTIAL_ROWS])
async def test_credential_headers(gw, upstreams, upstream, op, inbound, expected_upstream_header):
    await _header_case(gw, upstreams, upstream, op, inbound, expected_upstream_header)


# -- The vendor's session id ----------------------------------------------------------------------
SESSION_ROWS = [  # description | upstream | op | inbound | upstream_header?
    ("the claude-code session id passes through alone", "upstream-ok", "messages", "X-Claude-Code-Session-Id: u1",
     "X-Claude-Code-Session-Id: u1; x-opencode-session: (absent)"),
    ("the opencode session id passes through alone", "upstream-ok", "chat", "x-opencode-session: c1",
     "x-opencode-session: c1; X-Claude-Code-Session-Id: (absent)"),
    ("both session headers pass through", "upstream-ok", "messages", "x-opencode-session: c1; X-Claude-Code-Session-Id: u1",
     "x-opencode-session: c1; X-Claude-Code-Session-Id: u1"),
    ("no session header — the gateway supplies its session id ⚖", "upstream-ok", "messages", NONE, "x-opencode-session: <session id>"),
]


@pytest.mark.parametrize(("upstream", "op", "inbound", "expected_upstream_header"), [r[1:] for r in SESSION_ROWS], ids=[r[0] for r in SESSION_ROWS])
async def test_session_headers(gw, upstreams, upstream, op, inbound, expected_upstream_header):
    await _header_case(gw, upstreams, upstream, op, inbound, expected_upstream_header)


# -- The client's signature and encoding ----------------------------------------------------------
CLIENT_ROWS = [  # description | upstream | op | inbound | upstream_header?
    # `user_agent: fixed` on this rail (policy ⚖): the edge in front of opencode.ai judges client
    # signatures (Cloudflare 1010 refused `Python-urllib`, 2026-10-17) — it sees the gateway's own UA
    ("the caller's user agent is replaced by the gateway's own ⚖", "upstream-ok", "chat", "User-Agent: Python-urllib/3.13", "User-Agent: agent-gateway"),
    ("the client's Accept-Encoding passes through", "upstream-ok", "chat", "Accept-Encoding: gzip", "Accept-Encoding: gzip"),
    ("no Accept-Encoding from the client is identity upstream ⚖", "upstream-ok", "chat", "Accept-Encoding: (none)", "Accept-Encoding: identity"),
]


@pytest.mark.parametrize(("upstream", "op", "inbound", "expected_upstream_header"), [r[1:] for r in CLIENT_ROWS], ids=[r[0] for r in CLIENT_ROWS])
async def test_client_headers(gw, upstreams, upstream, op, inbound, expected_upstream_header):
    await _header_case(gw, upstreams, upstream, op, inbound, expected_upstream_header)


# -- A call lands on the Go upstream --------------------------------------------------------------
LAND_ROWS = [  # description | upstream | op | upstream_path? | status? | body? | recorded?
    ("an anthropic-dialect call lands", "upstream-ok", "messages", "/v1/messages", 200, "the upstream bytes", "1 · 12 · 0 · 0 · 7"),
    ("an openai-dialect call lands", "upstream-ok", "chat", "/v1/chat/completions", 200, "the upstream bytes", "1 · 7 · 0 · 0 · 3"),
    ("the models list passes through", "upstream-ok", "models", "/v1/models", 200, "the upstream bytes", "1 · 0 · 0 · 0 · 0"),
    ("a stream streams", "upstream-stream", "chat", "/v1/chat/completions", 200, "the upstream bytes", "1 · 19 · 0 · 0 · 4"),
]
PRODUCTION = "https://opencode.ai/zen/go"


@pytest.mark.parametrize(("upstream", "op", "expected_upstream_path", "expected_status", "expected_body", "expected_recorded"),
                         [r[1:] for r in LAND_ROWS], ids=[r[0] for r in LAND_ROWS])
async def test_calls_land(gw, upstreams, store, upstream, op, expected_upstream_path, expected_status, expected_body, expected_recorded):
    world(upstream=upstream)
    got = await oracle(upstreams[RAIL], op, MODEL[op], upstream)
    upstreams[RAIL].behaviour = upstream
    body = {"model": MODEL[op], **({"stream": True} if upstream == "upstream-stream" else {})} if op != "models" else None
    doc, r = await ride(gw, RAIL, op, body=body, name=inputs(upstream=upstream, op=op))
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
ERR_ROWS = [  # description | upstream | op | status? | body? | retry_after?
    ("a rate limit passes through", "upstream-429", "messages", 429, "the upstream bytes", "30"),
    ("an upstream auth failure is typed and hidden", "upstream-401", "chat", 424, "upstream-auth envelope", NONE),
    ("the vendor's MissingSessionID is passed through, not masked ⚖", "upstream-400-missing-session", "messages", 400, "the upstream bytes", NONE),
    ("an unreachable upstream is typed", "upstream-down", "messages", 502, "upstream-unreachable envelope", NONE),
    ("a read past 600 s is a typed timeout", "upstream-slow", "messages", 504, "upstream-timeout envelope", NONE),
]


@pytest.mark.parametrize(("upstream", "op", "expected_status", "expected_body", "expected_retry_after"), [r[1:] for r in ERR_ROWS], ids=[r[0] for r in ERR_ROWS])
async def test_not_2xx(gw, upstreams, transport, upstream, op, expected_status, expected_body, expected_retry_after):
    world(upstream=upstream)
    got = await oracle(upstreams[RAIL], op, MODEL[op], upstream)
    upstreams[RAIL].behaviour = upstream
    apply_transport_world(transport, RAIL, upstream)
    _, r = await ride(gw, RAIL, op, body={"model": MODEL[op]}, name=inputs(upstream=upstream, op=op))
    then_eq("expected_status", r.status_code, expected_status, claim=f"status? = {expected_status}")
    with then(f"body? = {expected_body} (no upstream credential hint crosses back)",
              expected_body={"expected": expected_body, "actual": body_class(r, got[1] if got else None)}, body_text={"actual": r.text[:200]}):
        assert body_class(r, got[1] if got else None) == expected_body
        assert "LEAK" not in r.text
    then_eq("expected_retry_after", r.headers.get("retry-after") or NONE, expected_retry_after, claim=f"retry_after? = {expected_retry_after}")
