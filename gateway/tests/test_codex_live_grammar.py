"""GW-RAIL-CODEX §Live grammar — captured 2026-10-23 (specs/endpoints/openai-responses.md): the rows the
capture ride's bundle derived (GW-CODEX-CAPTURE, task capture-codex-20261023T100750Z — a tool-call turn
and its continuation through the live backend). The fixture `fixtures/codex-live/turn-2026-10-23.json`
is the SANITIZED bundle's structure: header names, event types/sizes/times, item types, usage numbers.
Argnames = the table's header (`fixture | result?`), ids = its description cells.
"""

from __future__ import annotations

import json
import pathlib

import pytest

from agent_gateway import responses
from agent_gateway.codex import usage_of

from ._codex_rows import expect, row
from ._codex_world import TEXT, admitted, body, ride
from .conftest import attach_json, given, rule, then, when, world

pytestmark = rule("GW-RAIL-CODEX")

FIXTURE = pathlib.Path(__file__).parent / "fixtures" / "codex-live" / "turn-2026-10-23.json"
LIVE = json.loads(FIXTURE.read_text(encoding="utf-8"))
TURN = LIVE["requests"][0]
EXACT_UPSTREAM = {"authorization", "chatgpt-account-id", "content-type", "accept", "accept-encoding", "user-agent",
                  "host", "content-length", "connection"}

HEADERS_CELL = ("the CLI's own request header names: originator, session-id, thread-id, x-client-request-id, "
                "x-codex-beta-features, x-codex-turn-metadata, x-codex-window-id, x-openai-internal-codex-responses-lite")
ITEMS_CELL = ("the lite protocol's items: additional_tools, developer and user message, custom_tool_call, "
              "custom_tool_call_output; no top-level tools; include, reasoning, text, prompt_cache_key, client_metadata, "
              "parallel_tool_calls: false, tool_choice: auto")
EVENTS_CELL = ("the 78-event tool-call turn: response.created → in_progress → a message item (output_text.delta ×9) → "
               "a custom_tool_call exec (custom_tool_call_input.delta ×57) → response.metadata → response.completed; "
               "usage 10683 in / 9088 cached / 83 out + a vendor attribution extension")


def _cli_headers() -> dict[str, str]:
    """The pinned CLI's own request headers as the capture saw their NAMES (values synthetic)."""
    names = [h for h in TURN["client_headers"] if h not in ("accept", "authorization", "content-length", "content-type", "host", "user-agent")]
    return {name: f"SYNTHETIC-{name}" for name in names}


@pytest.mark.parametrize(("fixture", "expected_result"), [
    pytest.param(HEADERS_CELL, "200; none of them crossed; the upstream set is exactly the six (+ transport)",
                 id="the pinned CLI's own request headers never cross — the live set ⚖"),
])
async def test_cli_headers_never_cross(codex_app, codex_gw, codex_upstream, clock, fixture, expected_result):
    world("policy-codex")
    row(fixture=fixture, expected_result=expected_result)
    doc = await admitted(codex_app, codex_gw, clock)
    inbound = _cli_headers()
    with given(f"fixture {FIXTURE.name}: the live header names {sorted(inbound)} (the backend answered 200 without them on 2026-10-23)"):
        attach_json("inbound (synthetic values)", inbound)
    r = await ride(codex_gw, doc, headers=inbound, label="the CLI's own headers inbound")
    sent = {k.lower(): v for k, v in codex_upstream.calls[-1]["headers"].items()}
    crossed = sorted(set(inbound) & set(sent))
    result = (f"{r.status_code}; " + ("none of them crossed" if not crossed and "SYNTHETIC-" not in json.dumps(sent) else f"crossed: {crossed}")
              + "; the upstream set is exactly the six (+ transport)" if set(sent) == EXACT_UPSTREAM else f"{r.status_code}; upstream set {sorted(sent)}")
    expect("result", result, expected_result)


@pytest.mark.parametrize(("fixture", "expected_result"), [
    pytest.param(ITEMS_CELL, "200; the body crossed unchanged, the model the session's", id="the lite protocol's input items pass the body check"),
])
async def test_lite_input_items(codex_app, codex_gw, codex_upstream, clock, fixture, expected_result):
    world("policy-codex")
    row(fixture=fixture, expected_result=expected_result)
    doc = await admitted(codex_app, codex_gw, clock)
    payload = body(input=[
        {"type": "additional_tools", "role": "developer", "tools": [{"type": "custom", "name": "exec", "description": "run a command"}]},
        {"type": "message", "role": "developer", "content": [{"type": "input_text", "text": "be brief"}]},
        {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hi"}]},
        {"type": "custom_tool_call", "call_id": "call_fixture", "name": "exec", "input": "wc -l README.md"},
        {"type": "custom_tool_call_output", "call_id": "call_fixture", "output": "220 README.md"},
    ], include=["reasoning.encrypted_content"], parallel_tool_calls=False, tool_choice="auto", reasoning={"effort": "medium"},
        text={"verbosity": "low"}, prompt_cache_key="synthetic", client_metadata={"k": "v"})
    with given(f"fixture: the live request's item types {[i['type'] for i in TURN['input_items']][:4]}… and top-level keys {sorted(TURN['body_top_level'])}"):
        pass
    r = await ride(codex_gw, doc, payload, label="the lite protocol's shape")
    crossed = codex_upstream.calls[-1]["body"]
    unchanged = crossed == payload and sorted(crossed) == sorted(TURN["body_top_level"]) and TEXT in r.text
    result = f"{r.status_code}; " + ("the body crossed unchanged, the model the session's" if unchanged else f"the body crossed as {sorted(crossed)}")
    with then("the crossed body", crossed_keys=sorted(crossed), item_types=[i["type"] for i in crossed["input"]]):
        pass
    expect("result", result, expected_result)


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


@pytest.mark.parametrize(("fixture", "expected_result"), [
    pytest.param(EVENTS_CELL, "completed, byte-identical, one close; counted 1595 / 9088 / 83 = the live client-response usage",
                 id="the live turn's event grammar relays and completes with the ledger's usage"),
])
async def test_live_grammar_relays(fixture, expected_result):
    world("policy-codex")
    row(fixture=fixture, expected_result=expected_result)
    usage = {**TURN["terminal_usage_standard"], "attribution": {"items": {"withheld": True}}}
    chunks = _synthesize(TURN["events"], usage)
    types = [e["type"] for e in TURN["events"]]
    with given(f"fixture: the live turn's {len(types)} events, the terminal's usage {TURN['terminal_usage_standard']} + the vendor's `attribution`"):
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
    same = (counted.tokens_in, counted.tokens_cache_read, counted.tokens_out) == (live["in"], live["cache_read"], live["out"])
    result = (f"{obs.outcome}, {'byte-identical' if b''.join(out) == b''.join(chunks) else 'bytes differ'}, "
              f"{'one close' if closes == [1] else f'{len(closes)} closes'}; counted {counted.tokens_in} / {counted.tokens_cache_read} / {counted.tokens_out}"
              + (" = the live client-response usage" if same else f" ≠ the live {live}"))
    expect("result", result, expected_result)


def _runs(types: list[str]) -> list[str]:
    runs: list[list] = []
    for t in types:
        if runs and runs[-1][0] == t:
            runs[-1][1] += 1
        else:
            runs.append([t, 1])
    return [f"{t}×{n}" if n > 1 else t for t, n in runs]
