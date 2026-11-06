"""GW-RAIL-CODEX §Opaque turn state — the turn-state round trip, driven through the gateway against the
fake backend (specs/endpoints/openai-responses.md). Dummy state values only. Argnames = the table's
header (`sequence | client_state? | replay? | backend_calls?`), ids = its description cells.

The replay's fate is observed as: accepted = 200 and the backend saw the header; refused = 400
`turn-state-invalid` and NO backend call.
"""

from __future__ import annotations

import asyncio

import pytest

from agent_gateway.turn_state import HEADER

from ._codex_rows import expect, row, verdicts
from ._codex_world import admitted, body, codex_session, ride
from .conftest import attach_json, given, quiet, rule, then, world

pytestmark = rule("GW-RAIL-CODEX")
STATE = "dummy-state"


def turn(turn_id: str) -> dict:
    return body(client_metadata={"turn_id": turn_id})


async def _first_turn(gw, doc, upstream, issue: str | None, turn_id: str = "dummy-turn"):
    """Given: the first turn of a session — the backend issues `issue` (or nothing)."""
    upstream.response_headers = {HEADER: issue} if issue is not None else {}
    with given(f"turn {turn_id!r}: the backend issues {'nothing' if issue is None else f'{len(issue)} bytes of state'}"):
        r = await gw.post("/openai/v1/responses", json=turn(turn_id), headers={"authorization": f"Bearer {doc['session']['token']}"})
        got = r.headers.get(HEADER)
        attach_json("first turn", {"status": r.status_code, "client_received_state": got if got is None else f"<{len(got)} bytes>",
                                   "backend_calls": len(upstream.calls)})
    return got


def _replay(upstream, r, calls_before: int) -> dict:
    seen = upstream.calls[-1]["headers"].get(HEADER) if len(upstream.calls) > calls_before else None
    return {"status": r.status_code, "error": (r.json().get("error", {}).get("code") if r.status_code != 200 else None),
            "backend_saw_header": (seen is not None), "backend_calls": len(upstream.calls),
            "outcome": "accepted" if r.status_code == 200 and seen is not None else "refused"}


def _client_state(received: str | None) -> str:
    return "the issued state" if received == STATE else "none" if received is None else f"<{len(received)} bytes>"


SEQUENCES = {  # the `sequence` cell → (what the backend issues on the first turn, the replay's turn, the replayed value, another session?)
    "issue, replay": (STATE, "dummy-turn", STATE, False),
    "issue, cross-session replay": (STATE, "dummy-turn", STATE, True),
    "issue, next-turn replay": (STATE, "next", STATE, False),
    "no issue, replay": (None, "dummy-turn", "forged", False),
    "issued 4097 bytes, replay": ("x" * 4097, "dummy-turn", "x" * 4097, False),
}


@pytest.mark.parametrize(("sequence", "expected_client_state", "expected_replay", "expected_backend_calls"), [
    pytest.param("issue, replay", "the issued state", "accepted", 2, id="same session and turn"),
    pytest.param("issue, cross-session replay", "the issued state", "refused", 1, id="another session"),
    pytest.param("issue, next-turn replay", "the issued state", "refused", 1, id="new turn clears state"),
    pytest.param("no issue, replay", "none", "refused", 1, id="forged state"),
    pytest.param("issued 4097 bytes, replay", "none", "refused", 1, id="oversized state ⚖"),
])
async def test_bound_state(codex_app, codex_gw, codex_upstream, clock, sequence, expected_client_state, expected_replay, expected_backend_calls):
    world("policy-codex", "upstream-ok")
    row(sequence=sequence, expected_client_state=expected_client_state, expected_replay=expected_replay,
        expected_backend_calls=expected_backend_calls)
    doc = await admitted(codex_app, codex_gw, clock)
    issue, replay_turn, replay_value, other_session = SEQUENCES[sequence]
    received = await _first_turn(codex_gw, doc, codex_upstream, issue)
    replay_doc = doc
    if other_session:
        with given("a SECOND codex session on the same (already fresh) headroom"):
            with quiet():
                replay_doc = await codex_session(codex_gw)
    calls_before = len(codex_upstream.calls)
    r = await ride(codex_gw, replay_doc, turn(replay_turn), {HEADER: replay_value},
                   label=f"sequence {sequence}: replay <{len(replay_value)} bytes> in turn {replay_turn!r}")
    got = _replay(codex_upstream, r, calls_before)
    verdicts(
        client_state=(_client_state(received), expected_client_state),
        replay=(got["outcome"], expected_replay),
        backend_calls=(got["backend_calls"], expected_backend_calls),
    )
    if got["outcome"] == "refused":
        with then("the refusal is 400 turn-state-invalid"):
            assert got["error"] == "turn-state-invalid"


@pytest.mark.parametrize(("sequence", "expected_client_state", "expected_replay", "expected_backend_calls"), [
    pytest.param("old turn held, new turn done, old answers with state, replay", "none", "refused", 2, id="delayed old turn response ⚖"),
])
async def test_delayed_old_turn(codex_app, codex_gw, codex_upstream, clock, sequence, expected_client_state, expected_replay, expected_backend_calls):
    world("policy-codex", "upstream-ok")
    row(sequence=sequence, expected_client_state=expected_client_state, expected_replay=expected_replay,
        expected_backend_calls=expected_backend_calls)
    doc = await admitted(codex_app, codex_gw, clock)
    h = {"authorization": f"Bearer {doc['session']['token']}"}
    # The backend issues state ONLY on the old turn; the new turn gets none — so the only way the
    # old value could ever be replayable in the new turn is a late install, which the row forbids.
    codex_upstream.response_headers = lambda call: ({HEADER: STATE} if call["body"]["client_metadata"]["turn_id"] == "old" else {})
    codex_upstream.hold_first = asyncio.Event()
    with given(f"sequence {sequence}: turn 'old' in flight (held); turn 'new' completes first (no state issued); 'old' answers with state"):
        with quiet():  # two rides, one summary attachment below
            old = asyncio.ensure_future(codex_gw.post("/openai/v1/responses", json=turn("old"), headers=h))
            while len(codex_upstream.calls) < 1:
                await asyncio.sleep(0)
            new = await codex_gw.post("/openai/v1/responses", json=turn("new"), headers=h)
            codex_upstream.hold_first.set()
            old_r = await old
        order = [c["body"]["client_metadata"]["turn_id"] for c in codex_upstream.calls]
        attach_json("order and outcomes", {"backend_call_order": order, "new_turn_status": new.status_code, "old_turn_status": old_r.status_code,
                                          "old_turn_client_received_state": old_r.headers.get(HEADER),
                                          "new_turn_client_received_state": new.headers.get(HEADER)})
    calls_before = len(codex_upstream.calls)
    r = await ride(codex_gw, doc, turn("new"), {HEADER: STATE}, label="replay the old turn's value in turn 'new'")
    got = _replay(codex_upstream, r, calls_before)
    with then("the backend saw the turns in the order old, new"):
        assert order == ["old", "new"]
    received = old_r.headers.get(HEADER) or new.headers.get(HEADER)
    expect("client_state", _client_state(received), expected_client_state, claim="client_state? = none (neither turn's answer carried state)")
    verdicts(
        replay=(got["outcome"], expected_replay),
        backend_calls=(got["backend_calls"], expected_backend_calls),
    )
    with then("the refusal is 400 turn-state-invalid"):
        assert got["error"] == "turn-state-invalid"
