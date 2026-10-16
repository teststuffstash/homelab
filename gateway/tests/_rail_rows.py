"""Shared helpers for the per-rail decision tables (not a test module)."""

from __future__ import annotations

import json

from .conftest import given, open_session, when

PATHS = {"messages": "/anthropic/v1/messages", "chat": "/openai/v1/chat/completions", "models": "/openai/v1/models"}
UPSTREAM_PATHS = {"messages": "/v1/messages", "chat": "/v1/chat/completions", "models": "/v1/models"}
SESSION_FOR = {  # (rail, dialect) → an admission that lands on that rail with a harness that speaks it
    ("anthropic", "anthropic"): {"role": "reviewer", "harness": "claude"},
    ("opencode", "anthropic"): {"role": "reviewer", "harness": "claude", "rail": "opencode"},
    ("opencode", "openai"): {"role": "worker", "harness": "opencode"},
    ("openrouter", "anthropic"): {"role": "worker", "harness": "claude", "rail": "openrouter"},
    ("openrouter", "openai"): {"role": "worker", "harness": "goose", "rail": "openrouter"},
}


async def ride(gw, rail: str, op: str, headers: dict | None = None, body: dict | None = None, path: str | None = None):
    """Given a session on `rail` whose harness speaks `op`'s dialect; WHEN the one call under test
    (op=<op>, its inbound headers and body extras in the step name — the row's values)."""
    dialect = "anthropic" if op == "messages" else "openai"
    with given(f"a session on rail {rail} ({dialect} dialect, {SESSION_FOR[(rail, dialect)]})"):
        doc = await open_session(gw, **SESSION_FOR[(rail, dialect)])
    h = {"authorization": f"Bearer {doc['session']['token']}", **(headers or {})}
    p = path or PATHS[op]
    verb = "GET" if op == "models" else "POST"
    with when(f"{verb} {p} op={op} · inbound {headers or '(no extra headers)'}" + (f" · body {body}" if body else "")):
        if op == "models":
            r = await gw.get(p, headers=h)
        else:
            payload = {"messages": [{"role": "user", "content": "hi"}], "max_tokens": 8, **(body or {})}
            r = await gw.post(p, json=payload, headers=h)
    return doc, r


async def expected_bytes(upstream, op: str, model: str, behaviour: str) -> tuple[int, bytes, dict]:
    """What the fake upstream itself returns for the same call — the identity oracle (a given
    step: the fake's own exchange attaches under it)."""
    with given(f"the identity oracle: the {upstream.rail} fake's own answer to op={op} model {model} under {behaviour}"):
        return await _expected_bytes(upstream, op, model, behaviour)


async def _expected_bytes(upstream, op: str, model: str, behaviour: str) -> tuple[int, bytes, dict]:
    import httpx

    upstream.behaviour = behaviour
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=upstream.app), base_url="http://u") as c:
        if op == "models":
            r = await c.get(UPSTREAM_PATHS[op])
        else:
            r = await c.post(UPSTREAM_PATHS[op], json={"messages": [{"role": "user", "content": "hi"}], "max_tokens": 8, "model": model, **({"stream": True} if behaviour.startswith("upstream-stream") else {})})
    upstream.calls.pop()
    return r.status_code, r.content, dict(r.headers)


def dumps(o) -> str:
    return json.dumps(o, sort_keys=True)
