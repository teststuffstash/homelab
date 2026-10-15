"""GW-ACCESS — the role x rail half of the inventory, as v0 enforces it via roles.<role>.rails (specs/access.md).

| description | role | rail | expected |
|---|---|---|---|
| worker x anthropic | worker | anthropic | denied (defer role-rail-denied) |
| worker x opencode | worker | opencode | allowed |
| worker x openrouter | worker | openrouter | allowed |
| reviewer x anthropic | reviewer | anthropic | allowed |
| reviewer x opencode | reviewer | opencode | allowed |
| reviewer x openrouter | reviewer | openrouter | denied |
| coordinator x anthropic | coordinator | anthropic | allowed |
| coordinator x opencode | coordinator | opencode | allowed |
| coordinator x openrouter | coordinator | openrouter | denied |
| responder x anthropic | responder | anthropic | allowed |
| responder x opencode | responder | opencode | allowed |
| responder x openrouter | responder | openrouter | denied |
| retro x anthropic | retro | anthropic | allowed |
| retro x opencode | retro | opencode | denied |
| retro x openrouter | retro | openrouter | allowed |
| prober x anthropic | prober | anthropic | allowed |
| prober x opencode | prober | opencode | denied |
| prober x openrouter | prober | openrouter | denied |
| researcher x anthropic | researcher | anthropic | allowed |
| researcher x opencode | researcher | opencode | denied |
| researcher x openrouter | researcher | openrouter | allowed |

The other columns of specs/access.md (git identity, stack MCP, browser MCP) are documented as
unenforced in v0 and have no rows here by design.
"""

from __future__ import annotations

import pytest

from .conftest import rule

pytestmark = rule("GW-ACCESS")

ALLOWED = {
    "worker": {"opencode", "openrouter"},
    "reviewer": {"anthropic", "opencode"},
    "coordinator": {"anthropic", "opencode"},
    "responder": {"anthropic", "opencode"},
    "retro": {"anthropic", "openrouter"},
    "prober": {"anthropic"},
    "researcher": {"openrouter", "anthropic"},
}
ROWS = [(f"{role} x {rail}", role, rail, rail in rails) for role, rails in ALLOWED.items() for rail in ("anthropic", "opencode", "openrouter")]


@pytest.mark.parametrize(("role", "rail", "allowed"), [r[1:] for r in ROWS], ids=[r[0] for r in ROWS])
async def test_role_rail(gw, policy, role, rail, allowed):
    assert set(policy.roles[role].rails) == ALLOWED[role], "the table must mirror policy-default.json"
    # harness claude speaks the anthropic dialect, which every rail serves — so the verdict is the role's alone
    r = await gw.post("/sessions", json={"stack": "platform", "role": role, "task": "t", "rail": rail, "harness": "claude"})
    assert r.status_code == 200, r.text
    doc = r.json()
    if allowed:
        assert doc["decision"] == "dispatch" and doc["rail"] == rail
    else:
        assert doc["decision"] == "defer" and doc["reason"] == "role-rail-denied"
