"""GW-RAIL-CODEX — the opaque turn-state round trip, driven through the gateway against the fake
backend (specs/endpoints/openai-responses.md §Opaque turn state). Dummy state values only.

| description | sequence | replay |
| same session and turn | issue, replay | accepted |
| another session | issue, cross session replay | refused |
| new turn clears state | issue, next turn replay | refused |
| forged state | no issue, replay | refused |
| oversized state ⚖ | upstream issues 4097 bytes | dropped (not refused): no state header to the client, a replay of it is 400 |
| delayed old turn response ⚖ | new turn before old response | dropped (not refused): the old turn's value never installs into the newer turn; a replay of it is 400 |

Each case attaches what the backend issued, what the client got back, what was replayed, the
replay's outcome (accepted = 200 and the backend saw the header; refused = 400
`turn-state-invalid` and NO backend call) and the backend call count.
"""
import asyncio

import pytest

from agent_gateway.turn_state import HEADER

from ._codex_world import admitted, body, codex_session, ride
from .conftest import attach_json, given, quiet, rule, then_eq, world

pytestmark = rule("GW-RAIL-CODEX")
STATE = "dummy-state"


def turn(turn_id: str) -> dict:
    return body(client_metadata={"turn_id": turn_id})


async def _first_turn(gw, doc, upstream, issue: str | None, turn_id: str = "dummy-turn"):
    """Given: the first turn of a session — the backend issues `issue` (or nothing) — as a given step."""
    upstream.response_headers = {HEADER: issue} if issue is not None else {}
    with given(f"turn {turn_id!r}: the backend issues {'nothing' if issue is None else f'{len(issue)} bytes of state'}"):
        r = await gw.post("/openai/v1/responses", json=turn(turn_id), headers={"authorization": f"Bearer {doc['session']['token']}"})
        got = r.headers.get(HEADER)
        attach_json("first turn", {"status": r.status_code, "client_received_state": got if got is None else f"<{len(got)} bytes>",
                                   "backend_calls": len(upstream.calls)})
    return got


def _replay(upstream, r, calls_before: int) -> dict:
    """The replay's outcome as observed: status, error code, whether the backend saw the header."""
    seen = upstream.calls[-1]["headers"].get(HEADER) if len(upstream.calls) > calls_before else None
    outcome = "accepted" if r.status_code == 200 else "refused"
    return {"status": r.status_code, "error": (r.json().get("error", {}).get("code") if r.status_code != 200 else None),
            "backend_saw_header": (seen is not None), "backend_calls": len(upstream.calls), "outcome": outcome}


@pytest.mark.parametrize("case", ["same", "session", "turn", "forged", "oversize"], ids=[
    "same session and turn", "another session", "new turn clears state", "forged state", "oversized state ⚖"])
async def test_bound_state(codex_app, codex_gw, codex_upstream, clock, case):
    world("policy-codex", "upstream-ok")
    doc = await admitted(codex_app, codex_gw, clock)
    issue = {"same": STATE, "session": STATE, "turn": STATE, "forged": None, "oversize": "x" * 4097}[case]
    received = await _first_turn(codex_gw, doc, codex_upstream, issue)
    replay_doc, replay_turn, replay_value = doc, "dummy-turn", STATE
    if case == "session":
        with given("a SECOND codex session on the same (already fresh) headroom"):
            with quiet():
                replay_doc = await codex_session(codex_gw)
    elif case == "turn":
        replay_turn = "next"
    elif case == "forged":
        replay_value = "forged"
    elif case == "oversize":
        replay_value = issue
    calls_before = len(codex_upstream.calls)
    r = await ride(codex_gw, replay_doc, turn(replay_turn), {HEADER: replay_value},
                   label=f"replay {'the issued' if replay_value == issue else 'a non-issued'} value in turn {replay_turn!r}"
                         + (" from ANOTHER session" if case == "session" else ""))
    got = _replay(codex_upstream, r, calls_before)
    attach_json("replay", {"replayed": f"<{len(replay_value)} bytes>", **got})
    if case in ("same", "session", "turn"):
        then_eq("client received the issued state on the first turn", received, STATE)
    elif case == "forged":
        then_eq("no state was issued (client received none)", received, None)
    else:
        then_eq("oversized state is dropped (client received none)", received, None)
    if case == "same":
        then_eq("replay", got["outcome"], "accepted")
        then_eq("backend saw the replayed header", got["backend_saw_header"], True)
        then_eq("backend calls", got["backend_calls"], 2)
    else:
        then_eq("replay", got["outcome"], "refused")
        then_eq("error code", got["error"], "turn-state-invalid")
        then_eq("backend calls (the replay made none)", got["backend_calls"], calls_before)


async def test_delayed_old_turn(codex_app, codex_gw, codex_upstream, clock):
    """row: delayed old turn response ⚖"""
    world("policy-codex", "upstream-ok")
    doc = await admitted(codex_app, codex_gw, clock)
    h = {"authorization": f"Bearer {doc['session']['token']}"}
    # The backend issues state ONLY on the old turn; the new turn gets none — so the only way the
    # old value could ever be replayable in the new turn is a late install, which the row forbids.
    codex_upstream.response_headers = lambda call: ({HEADER: STATE} if call["body"]["client_metadata"]["turn_id"] == "old" else {})
    codex_upstream.hold_first = asyncio.Event()
    with given("turn 'old' is in flight (the backend holds its answer); turn 'new' completes first (no state issued); then 'old' answers with state"):
        old = asyncio.ensure_future(codex_gw.post("/openai/v1/responses", json=turn("old"), headers=h))
        while len(codex_upstream.calls) < 1:
            await asyncio.sleep(0)
        new = await codex_gw.post("/openai/v1/responses", json=turn("new"), headers=h)
        codex_upstream.hold_first.set()
        old_r = await old
        order = [c["body"]["client_metadata"]["turn_id"] for c in codex_upstream.calls]
        attach_json("order and outcomes", {"backend_call_order": order, "new_turn_status": new.status_code,
                                          "old_turn_status": old_r.status_code,
                                          "old_turn_client_received_state": old_r.headers.get(HEADER),
                                          "new_turn_client_received_state": new.headers.get(HEADER)})
    calls_before = len(codex_upstream.calls)
    r = await ride(codex_gw, doc, turn("new"), {HEADER: STATE}, label="replay the old turn's value in turn 'new'")
    got = _replay(codex_upstream, r, calls_before)
    attach_json("replay", got)
    then_eq("backend saw the turns in this order", order, ["old", "new"])
    then_eq("the delayed old-turn state is not returned to the client", old_r.headers.get(HEADER), None)
    then_eq("the new turn holds no state", new.headers.get(HEADER), None)
    then_eq("replay", got["outcome"], "refused")
    then_eq("error code", got["error"], "turn-state-invalid")
    then_eq("backend calls (the replay made none)", got["backend_calls"], calls_before)
