"""GW-RAIL-CODEX §Live grammar — captured 2026-10-23 (specs/endpoints/openai-responses.md): the rows the
capture ride's bundle derived (GW-CODEX-CAPTURE, task capture-codex-20261023T100750Z — a tool-call turn
and its continuation through the live backend). The fixture `fixtures/codex-live/turn-2026-10-23.json`
is the SANITIZED bundle's structure: header names, event types/sizes/times, item types, usage numbers.

| description | the fixture says | the row proves (offline, the fake backend) |
|---|---|---|
| the pinned CLI's own request headers never cross — the live set | the CLI sent originator, session-id, thread-id, x-client-request-id, x-codex-beta-features, x-codex-turn-metadata, x-codex-window-id, x-openai-internal-codex-responses-lite; the backend answered 200 without them | a ride carrying every one of them: the upstream saw none; the set is exactly the six (+ transport) |
| the lite protocol's input items pass the body check | input = additional_tools, developer/user messages, custom_tool_call, custom_tool_call_output; no top-level tools | the same item types ride: 200, the body crosses with only the model filled |
| the live turn's event grammar relays and completes with the ledger's usage | 78 events (response.created … custom_tool_call_input.delta×57 … response.metadata, response.completed), usage 10683 in / 9088 cached / 83 out + a vendor `attribution` extension | the same type sequence synthesized relays byte-identical: completed, in 1595, cache_read 9088, out 83 — the live client-response's numbers |
"""

from __future__ import annotations

import json
import pathlib

from agent_gateway import responses
from agent_gateway.codex import usage_of

from ._codex_world import TEXT, admitted, body, ride
from .conftest import attach_json, given, rule, then, then_eq, when, world

pytestmark = rule("GW-RAIL-CODEX")

FIXTURE = pathlib.Path(__file__).parent / "fixtures" / "codex-live" / "turn-2026-10-23.json"
LIVE = json.loads(FIXTURE.read_text(encoding="utf-8"))
TURN = LIVE["requests"][0]
EXACT_UPSTREAM = {"authorization", "chatgpt-account-id", "content-type", "accept", "accept-encoding", "user-agent",
                  "host", "content-length", "connection"}


def _cli_headers() -> dict[str, str]:
    """The pinned CLI's own request headers as the capture saw their NAMES (values synthetic)."""
    names = [h for h in TURN["client_headers"] if h not in ("accept", "authorization", "content-length", "content-type", "host", "user-agent")]
    return {name: f"SYNTHETIC-{name}" for name in names}


async def test_cli_headers_never_cross(codex_app, codex_gw, codex_upstream, clock):
    """row: the pinned CLI's own request headers never cross — the live set"""
    world("policy-codex")
    doc = await admitted(codex_app, codex_gw, clock)
    inbound = _cli_headers()
    with given(f"the live set: {sorted(inbound)} (fixture {FIXTURE.name}; the backend answered 200 without them on 2026-10-23)"):
        attach_json("inbound (synthetic values)", inbound)
    r = await ride(codex_gw, doc, headers=inbound, label="the CLI's own headers inbound")
    sent = {k.lower(): v for k, v in codex_upstream.calls[-1]["headers"].items()}
    with then("none crossed; the upstream set is exactly the six (+ transport)", ride_status=r.status_code,
              upstream_names=sorted(sent), crossed=sorted(set(inbound) & set(sent))):
        assert r.status_code == 200
        assert not set(inbound) & set(sent)
        assert set(sent) == EXACT_UPSTREAM
        assert "SYNTHETIC-" not in json.dumps(sent)


async def test_lite_input_items(codex_app, codex_gw, codex_upstream, clock):
    """row: the lite protocol's input items pass the body check"""
    world("policy-codex")
    doc = await admitted(codex_app, codex_gw, clock)
    payload = body(input=[
        {"type": "additional_tools", "role": "developer", "tools": [{"type": "custom", "name": "exec", "description": "run a command"}]},
        {"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "be brief"}]},
        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hi"}]},
        {"type": "custom_tool_call", "call_id": "call_fixture", "name": "exec", "input": "wc -l README.md"},
        {"type": "custom_tool_call_output", "call_id": "call_fixture", "output": "220 README.md"},
    ], include=["reasoning.encrypted_content"], parallel_tool_calls=False, tool_choice="auto", reasoning={"effort": "medium"},
        text={"verbosity": "low"}, prompt_cache_key="synthetic", client_metadata={"k": "v"})
    with given(f"the live request's item types {[i['type'] for i in TURN['input_items']][:4]}… and top-level keys {sorted(TURN['body_top_level'])}"):
        pass
    r = await ride(codex_gw, doc, payload, label="the lite protocol's shape")
    crossed = codex_upstream.calls[-1]["body"]
    with then("200; the body crossed unchanged (the model the session's)", ride_status=r.status_code,
              crossed_keys=sorted(crossed), item_types=[i["type"] for i in crossed["input"]]):
        assert r.status_code == 200 and TEXT in r.text
        assert crossed == payload
        assert sorted(crossed) == sorted(TURN["body_top_level"])


def _synthesize(events: list[dict], usage: dict) -> list[bytes]:
    """The live type sequence as SSE, minimal bodies: the terminal carries the fixture's usage."""
    out = []
    for e in events:
        doc: dict = {"type": e["type"]}
        if e["type"] == "response.completed":
            doc["response"] = {"status": "completed", "usage": usage}
        elif e["type"] == "response.created":
            doc["response"] = {"status": "in_progress"}
        elif "item_type" in e:
            doc["item"] = {"type": e["item_type"], **({"name": e["item_name"]} if e.get("item_name") else {})}
        out.append(f"event: {e['type']}\ndata: {json.dumps(doc, separators=(',', ':'))}\n\n".encode())
    return out


async def test_live_grammar_relays(codex_app):
    """row: the live turn's event grammar relays and completes with the ledger's usage"""
    world("policy-codex")
    usage = {**TURN["terminal_usage_standard"], "attribution": {"items": {"withheld": True}}}
    chunks = _synthesize(TURN["events"], usage)
    types = [e["type"] for e in TURN["events"]]
    with given(f"the live turn's {len(types)} events, types from the fixture, the terminal's usage {TURN['terminal_usage_standard']} + the vendor's `attribution`"):
        attach_json("type runs", _runs(types))
    obs, closes, out = responses.Observation(), [], []

    async def source():
        for c in chunks:
            yield c

    async def close():
        closes.append(1)

    with when("relay the synthesized stream"):
        async for chunk in responses.relay(source(), obs, close):
            out.append(chunk)
    counted = usage_of(obs)
    live = TURN["client_response"]["usage"]
    with then("completed, bytes identical, one close; the counted usage = the live client-response's",
              outcome=obs.outcome, counted={"in": counted.tokens_in, "cache_read": counted.tokens_cache_read, "out": counted.tokens_out}, live=live):
        then_eq("outcome", obs.outcome, "completed")
        assert b"".join(out) == b"".join(chunks) and closes == [1]
        assert (counted.tokens_in, counted.tokens_cache_read, counted.tokens_out) == (live["in"], live["cache_read"], live["out"])


def _runs(types: list[str]) -> list[str]:
    runs: list[list] = []
    for t in types:
        if runs and runs[-1][0] == t:
            runs[-1][1] += 1
        else:
            runs.append([t, 1])
    return [f"{t}×{n}" if n > 1 else t for t, n in runs]
