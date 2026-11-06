"""GW-ACCESS — the role × rail half of the inventory, as v0 enforces it via roles.<role>.rails
(specs/access.md). Three tables, one per rail; every row is one explicit-rail `POST /sessions` for
stack `platform` in the `policy-default` world: header == the parametrize argnames, description ==
the row id.

The other columns of specs/access.md (git identity, stack MCP, browser MCP) are documented as
unenforced in v0 and have no rows here by design (the page marks them unverified).
"""

from __future__ import annotations

import pytest

from .conftest import attach_json, check, given, rule, then, when, world

pytestmark = rule("GW-ACCESS")

STACK = "platform"
DENIED = "role-rail-denied"


def _row(description: str, role: str, rail: str, decision: str, reason: str):
    return pytest.param(role, rail, decision, reason, id=description)


SUBSCRIPTION_ROWS = [
    _row("the worker never rides the subscription — its slots are the review and coordination lanes' ⚖", "worker", "anthropic", "defer", DENIED),
    _row("the reviewer's review lane is the subscription", "reviewer", "anthropic", "dispatch", "none"),
    _row("the coordinator's dispatch lane is the subscription", "coordinator", "anthropic", "dispatch", "none"),
    _row("the responder's triage lane is the subscription", "responder", "anthropic", "dispatch", "none"),
    _row("the retro's claude cell is the subscription", "retro", "anthropic", "dispatch", "none"),
    _row("the prober's only rail is the subscription", "prober", "anthropic", "dispatch", "none"),
    _row("the researcher's draws may ride the subscription", "researcher", "anthropic", "dispatch", "none"),
]

GO_ROWS = [
    _row("the Go rail is the worker's rail", "worker", "opencode", "dispatch", "none"),
    _row("the Go rail is the reviewer's failover", "reviewer", "opencode", "dispatch", "none"),
    _row("the Go rail is the coordinator's failover", "coordinator", "opencode", "dispatch", "none"),
    _row("the Go rail is the responder's failover", "responder", "opencode", "dispatch", "none"),
    _row("the retro has no Go cell", "retro", "opencode", "defer", DENIED),
    _row("the prober has no Go rail", "prober", "opencode", "defer", DENIED),
    _row("the researcher has no Go rail", "researcher", "opencode", "defer", DENIED),
]

OPENROUTER_ROWS = [
    _row("OpenRouter is the worker's pool rail", "worker", "openrouter", "dispatch", "none"),
    _row("the reviewer never rides OpenRouter", "reviewer", "openrouter", "defer", DENIED),
    _row("the coordinator never rides OpenRouter", "coordinator", "openrouter", "defer", DENIED),
    _row("the responder never rides OpenRouter", "responder", "openrouter", "defer", DENIED),
    _row("the retro's API cell is OpenRouter", "retro", "openrouter", "dispatch", "none"),
    _row("the prober never rides OpenRouter", "prober", "openrouter", "defer", DENIED),
    _row("OpenRouter is the researcher's draw rail", "researcher", "openrouter", "dispatch", "none"),
]

ARGS = ("role", "rail", "expected_decision", "expected_reason")


async def _ask(gw, policy, role: str, rail: str, expected_decision: str, expected_reason: str) -> None:
    world()
    with given(f"policy-default: role {role} lists the rails {list(policy.roles[role].rails)}; the asked rail is {rail}"):
        attach_json(f"policy roles.{role}.rails", list(policy.roles[role].rails))
    # no explicit harness: every rail's tier list holds a cell the walk can name a harness for
    # (a Go cell's dialect is its model's — GW-SESSIONS-ADMIT §The harness follows the cell), so
    # the verdict here is the role's rail membership alone
    with when(f"POST /sessions stack {STACK}, role {role}, rail {rail}"):
        r = await gw.post("/sessions", json={"stack": STACK, "role": role, "task": "t", "rail": rail})
    doc = r.json()
    with then(f"decision = {expected_decision}, reason = {expected_reason} (status 200)"):
        check("status", r.status_code, 200)
        check("expected_decision", doc.get("decision"), expected_decision)
        check("expected_reason", doc.get("reason", "none"), expected_reason)
        if expected_decision == "dispatch":
            check("rail", doc.get("rail"), rail)


@pytest.mark.parametrize(ARGS, SUBSCRIPTION_ROWS)
async def test_who_may_ride_the_subscription_rail(gw, policy, role, rail, expected_decision, expected_reason):
    await _ask(gw, policy, role, rail, expected_decision, expected_reason)


@pytest.mark.parametrize(ARGS, GO_ROWS)
async def test_who_may_ride_the_go_rail(gw, policy, role, rail, expected_decision, expected_reason):
    await _ask(gw, policy, role, rail, expected_decision, expected_reason)


@pytest.mark.parametrize(ARGS, OPENROUTER_ROWS)
async def test_who_may_ride_the_openrouter_rail(gw, policy, role, rail, expected_decision, expected_reason):
    await _ask(gw, policy, role, rail, expected_decision, expected_reason)
