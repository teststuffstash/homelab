"""Shared helpers for the data-plane decision tables (not a test module): GW-RAIL-ANTHROPIC,
GW-RAIL-OPENCODE, GW-RAIL-OPENROUTER, GW-MODEL-RESOLVE, GW-CRED-BOUNDARY (specs/endpoints/
anthropic-messages.md, openai-chat.md). Every row module threads its columns through the steps
with these: the `when` step name carries the row's inputs (`inputs()`), the header cells are read
and rendered in the Legend's literals (`parse_pairs()`, `headers_seen()`), an answer is classed the
way the `body?` column spells it (`body_class()`), the session's counters render as the
`recorded?` cell (`recorded()`). The literals — `(none)`, `(absent)`, `<AUTH_TOKEN>`,
`<session token>`, `<session id>` — are the ones the pages' Legend lines decode.
"""

from __future__ import annotations

import json

import httpx

from .conftest import ANTHROPIC_TOKEN, GO_KEY, OPENROUTER_KEY, given, open_session, quiet, when

PATHS = {"messages": "/anthropic/v1/messages", "chat": "/openai/v1/chat/completions", "models": "/openai/v1/models"}
UPSTREAM_PATHS = {"messages": "/v1/messages", "chat": "/v1/chat/completions", "models": "/v1/models"}
SESSION_FOR = {  # (rail, dialect) → an admission that lands on that rail with a harness that speaks it
    ("anthropic", "anthropic"): {"role": "reviewer", "harness": "claude"},
    ("opencode", "anthropic"): {"role": "reviewer", "harness": "claude", "rail": "opencode"},
    ("opencode", "openai"): {"role": "worker", "harness": "opencode"},
    ("openrouter", "anthropic"): {"role": "worker", "harness": "claude", "rail": "openrouter"},
    ("openrouter", "openai"): {"role": "worker", "harness": "goose", "rail": "openrouter"},
}
NONE = "(none)"
ABSENT = "(absent)"
# Credential placeholders as the pages' Legend lines spell them (a Secret KEY, never a value): the
# rendered upstream header shows the placeholder, so no fake value appears in a verdict either.
PLACEHOLDERS = {ANTHROPIC_TOKEN: "<AUTH_TOKEN>", GO_KEY: "<OPENCODE_GO_API_KEY>", OPENROUTER_KEY: "<OPENROUTER_API_KEY>"}


def inputs(**cols) -> str:
    """`a = x · b = y` — the row's input cells, by column name, for the `when` step's name."""
    return " · ".join(f"{k} = {v}" for k, v in cols.items())


def op_of(path: str) -> str:
    if path.endswith("/models"):
        return "models"
    return "chat" if path.endswith("/chat/completions") else "messages"


def parse_pairs(cell: str) -> list[tuple[str, str]]:
    """`Header: value; Other: (absent)` → [(header, value)]; `(none)` → []."""
    if cell.strip() in ("", NONE):
        return []
    out = []
    for part in cell.split(";"):
        name, _, value = part.partition(":")
        out.append((name.strip(), value.strip()))
    return out


async def ride(gw, rail: str, op: str | None = None, *, path: str | None = None, inbound: str = NONE,
               body: dict | None = None, stack: str = "platform", name: str = ""):
    """Given a session on `rail` whose harness speaks the call's dialect; WHEN the one call under
    test — `name` (the row's inputs, `inputs()`) is the step's name. `inbound` is the row's cell:
    `Header: value` pairs beside the session bearer; `<session token>` = the token; a value `(none)`
    REMOVES that header from the request (the client's own Accept-Encoding, or the bearer itself)."""
    p = path or PATHS[op]
    op = op or op_of(p)
    dialect = "anthropic" if op == "messages" else "openai"
    admission = {**SESSION_FOR[(rail, dialect)], "stack": stack}
    with given(f"a session on rail {rail}, stack {stack} ({dialect} dialect: {admission['role']} / harness {admission['harness']})"):
        doc = await open_session(gw, **admission)
    token = doc["session"]["token"]
    headers = {"authorization": f"Bearer {token}"}
    drop = []
    for k, v in parse_pairs(inbound):
        if v == NONE:
            drop.append(k.lower())
        else:
            headers[k.lower()] = token if v == "<session token>" else v
    verb = "GET" if op == "models" else "POST"
    with when(f"{verb} {p} · {name}" if name else f"{verb} {p}"):
        if op == "models":
            req = gw.build_request("GET", p, headers=headers)
        else:
            payload = {"messages": [{"role": "user", "content": "hi"}], "max_tokens": 8, **(body or {})}
            req = gw.build_request("POST", p, json=payload, headers=headers)
        for k in drop:
            if k in req.headers:
                del req.headers[k]
        r = await gw.send(req)
    return doc, r


def headers_seen(call: dict, expected_cell: str, doc: dict | None = None, inbound: str = NONE, aliases: dict | None = None) -> str:
    """The upstream's values for the headers `expected_cell` names, rendered in the cell's own
    shape: `(absent)` when the header did not reach upstream; a fake credential as its Legend
    placeholder; the ride's session id / token as `<session id>` / `<session token>`; `Connection`
    as `(the gateway's own)` when it is not the pod's value (the gateway's HTTP client owns it)."""
    seen = {k.lower(): v for k, v in call["headers"].items()}
    sent = {k.lower(): v for k, v in parse_pairs(inbound)}
    names = {**PLACEHOLDERS, **(aliases or {})}
    if doc is not None:
        names[doc["session"]["token"]] = "<session token>"
        names[doc["session"]["id"]] = "<session id>"
    parts = []
    for name, _ in parse_pairs(expected_cell):
        v = seen.get(name.lower())
        if v is None:
            shown = ABSENT
        elif name.lower() == "connection" and v != sent.get("connection"):
            shown = "(the gateway's own)"
        else:
            shown = v
            for value, placeholder in names.items():
                shown = shown.replace(value, placeholder)
        parts.append(f"{name}: {shown}")
    return "; ".join(parts)


async def oracle(upstream, op: str, model: str, behaviour: str) -> tuple[int, bytes, dict] | None:
    """What the fake upstream itself answers the same call under `behaviour` — the identity oracle
    the `body?` column's `the upstream bytes` is judged against (a given step named with the call;
    the fake's own exchange is muted — the `body?` verdict carries the comparison, and a case stays
    under the hygiene budget of 8 attachments). None for the transport-level worlds
    (`upstream-down`, `upstream-slow`): nothing answers there."""
    if behaviour in ("upstream-down", "upstream-slow"):
        return None
    with given(f"the identity oracle: the {upstream.rail} fake's own answer to op={op} model {model} under {behaviour}"), quiet():
        return await _oracle(upstream, op, model, behaviour)


expected_bytes = oracle  # the older name, kept for the modules that read like the oracle's rows


async def _oracle(upstream, op: str, model: str, behaviour: str) -> tuple[int, bytes, dict]:
    upstream.behaviour = behaviour
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=upstream.app), base_url="http://u") as c:
        if op == "models":
            r = await c.get(UPSTREAM_PATHS[op])
        else:
            r = await c.post(UPSTREAM_PATHS[op], json={"messages": [{"role": "user", "content": "hi"}], "max_tokens": 8, "model": model,
                                                       **({"stream": True} if behaviour.startswith("upstream-stream") else {})})
    upstream.calls.pop()
    return r.status_code, r.content, dict(r.headers)


def body_class(r, oracle_bytes: bytes | None) -> str:
    """The `body?` cell's literal for an answer: `the upstream bytes` (byte-identical to the
    upstream's own answer to the same call, SSE included), `<code> envelope` (the gateway's error
    envelope, `{error: {code, message}}`), else `(other)`."""
    if oracle_bytes is not None and r.content == oracle_bytes:
        return "the upstream bytes"
    try:
        body = r.json()
    except ValueError:
        return "(other)"
    if isinstance(body, dict) and set(body) == {"error"} and isinstance(body["error"], dict) and set(body["error"]) == {"code", "message"}:
        return f"{body['error']['code']} envelope"
    return "(other)"


def recorded(store, doc: dict) -> str:
    """The session's counters as the `recorded?` cell spells them:
    `requests · tokens_in · tokens_cache_read · tokens_cache_write · tokens_out`."""
    row = store.get_session(doc["session"]["id"])
    return " · ".join(str(x) for x in (row.requests, row.tokens_in, row.tokens_cache_read, row.tokens_cache_write, row.tokens_out))


def apply_transport_world(transport, rail: str, behaviour: str) -> None:
    """The transport-level worlds (specs/worlds/README.md): `upstream-down` = a connect failure
    that is not a timeout; `upstream-slow` = the read runs past 600 s (clock-faked)."""
    if behaviour == "upstream-down":
        transport.unreachable.add(rail)
    elif behaviour == "upstream-slow":
        transport.slow.add(rail)


def dumps(o) -> str:
    return json.dumps(o, sort_keys=True)
