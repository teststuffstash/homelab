"""Routing decision table, dummy opaque state only.

| description | sequence | replay |
| same session and turn | issue, replay | accepted |
| another session | issue, cross session replay | refused |
| new turn clears state | issue, next turn replay | refused |
| forged state | no issue, replay | refused |
| oversized state | upstream issues 4097 bytes | dropped |
| delayed old turn response | new turn before old response | dropped |
"""
import pytest

from agent_gateway.turn_state import TurnStates

from .conftest import rule, then_eq, when, world

pytestmark = rule("GW-RAIL-CODEX")


@pytest.mark.parametrize("case", ["same", "session", "turn", "forged", "oversize", "delayed"], ids=[
    "same session and turn", "another session", "new turn clears state", "forged state", "oversized state",
    "delayed old turn response"])
def test_bound_state(case):
    world("policy-codex")
    states = TurnStates()
    doc = {"client_metadata": {"turn_id": "dummy-turn"}}
    with when("routing sequence: " + case):
        key = states.request("session-a", "dummy-account", doc, None)
        issued = states.response("session-a", key, "x" * 4097 if case == "oversize" else "dummy-state")
        if case == "oversize":
            result = issued is None
        elif case == "delayed":
            states.request("session-a", "dummy-account", {"client_metadata": {"turn_id": "next"}}, None)
            result = states.response("session-a", key, "dummy-state") is None
        else:
            if case == "turn":
                doc["client_metadata"]["turn_id"] = "next"
            try:
                states.request("session-b" if case == "session" else "session-a", "dummy-account", doc,
                               "forged" if case == "forged" else "dummy-state")
                accepted = True
            except ValueError:
                accepted = False
            result = accepted == (case == "same")
    then_eq("binding and bound hold", result, True)
