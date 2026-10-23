"""GW-SESSIONS-ADMIT §The harness follows the rail (specs/endpoints/sessions.md) — the operator's
2026-10-23 ruling: every subscription rail is every role's, so the walk crosses the dialect boundary
on its own. Rows run in the `policy-codex` world (roles shaped as the ruling; codex `max_sessions`
2, anthropic 5, opencode 3) with codex headroom fresh at 20 % / 64 %.

| description | role | body | active on rails (anthropic / opencode / codex) || decision | rail | harness | model |
|---|---|---|---||---|---|---|---|
| without a harness the walk crosses the dialect boundary: the reviewer reaches codex | reviewer | (defaults) | 5 / 3 / 0 || dispatch | codex | codex | codex/fixture-model |
| a dual-dialect rail keeps the role's harness | reviewer | (defaults) | 5 / 0 / 0 || dispatch | opencode | claude | opencode-go/claude-haiku-5-5 |
| an opencode-harness worker reaching the anthropic rail rides claude | worker | (defaults) | 0 / 3 / 2 || dispatch | anthropic | claude | claude/sonnet |
| an explicit harness still narrows the walk to its dialect | reviewer | harness: claude | 5 / 3 / 0 || defer (rail-capacity) | — | — | — |
| an explicit rail without a harness takes the rail's harness | reviewer | rail: codex | 0 / 0 / 0 || dispatch | codex | codex | codex/fixture-model |
| the env is the picked harness's | worker | (defaults) | 0 / 3 / 2 || dispatch | anthropic | claude | env names ANTHROPIC_MODEL, never CODEX_MODEL / OPENCODE_CONFIG_CONTENT |
"""

from __future__ import annotations

import pytest

from ._codex_world import fresh_report
from .conftest import attach_json, given, open_session, quiet, rule, then, then_eq, when, world

pytestmark = rule("GW-SESSIONS-ADMIT")

# (description, body, fill {rail: n}, expected answer fields)
ROWS = [
    ("without a harness the walk crosses the dialect boundary: the reviewer reaches codex", {"role": "reviewer"},
     {"anthropic": 5, "opencode": 3}, {"decision": "dispatch", "rail": "codex", "harness": "codex", "model": "codex/fixture-model"}),
    ("a dual-dialect rail keeps the role's harness", {"role": "reviewer"},
     {"anthropic": 5}, {"decision": "dispatch", "rail": "opencode", "harness": "claude", "model": "opencode-go/claude-haiku-5-5"}),
    ("an opencode-harness worker reaching the anthropic rail rides claude", {"role": "worker"},
     {"opencode": 3, "codex": 2}, {"decision": "dispatch", "rail": "anthropic", "harness": "claude", "model": "claude/sonnet"}),
    ("an explicit harness still narrows the walk to its dialect", {"role": "reviewer", "harness": "claude"},
     {"anthropic": 5, "opencode": 3}, {"decision": "defer", "reason": "rail-capacity"}),
    ("an explicit rail without a harness takes the rail's harness", {"role": "reviewer", "rail": "codex"},
     {}, {"decision": "dispatch", "rail": "codex", "harness": "codex", "model": "codex/fixture-model"}),
]

FILL = {  # how a rail is filled: an explicit (role, harness) pair that the rail serves
    "anthropic": {"role": "reviewer", "harness": "claude"},
    "opencode": {"role": "worker", "harness": "opencode"},
    "codex": {"role": "prober", "harness": "codex"},
}


async def _arrange(app, gw, clock, fill: dict[str, int]) -> None:
    with given("codex headroom observed fresh: 20 % / 64 % (the rail's admission gate)"):
        app.state.codex.headroom.observe(fresh_report(clock))
    for rail, n in fill.items():
        with given(f"state: rail {rail} holds {n} active sessions (its max_sessions)"):
            with quiet():
                for i in range(n):
                    await open_session(gw, task=f"fill-{rail}-{i}", rail=rail, **FILL[rail])
            attach_json(f"filled: {rail} × {n}", {"rail": rail, "active_sessions_opened": n})


@pytest.mark.parametrize(("body", "fill", "expected"), [r[1:] for r in ROWS], ids=[r[0] for r in ROWS])
async def test_harness_follows_rail(codex_app, codex_gw, clock, body, fill, expected):
    world("policy-codex")
    await _arrange(codex_app, codex_gw, clock, fill)
    with when(f"POST /sessions {body} (no harness unless the body names one)"):
        r = await codex_gw.post("/sessions", json={"stack": "platform", "task": "homelab-2588-r1", **body})
    then_eq("status", r.status_code, 200)
    doc = r.json()
    claim = "expected " + ", ".join(f"{k} = {v}" for k, v in expected.items())
    with then(claim, **{k: {"expected": v, "actual": doc.get(k)} for k, v in expected.items()}):
        for k, v in expected.items():
            assert doc.get(k) == v, f"{k}: expected {v!r}, got {doc.get(k)!r}"


async def test_env_follows_harness(codex_app, codex_gw, clock):
    """row: the env is the picked harness's"""
    world("policy-codex")
    await _arrange(codex_app, codex_gw, clock, {"opencode": 3, "codex": 2})
    with when("POST /sessions {role: worker} — no harness; opencode and codex full, anthropic next"):
        doc = await open_session(codex_gw, role="worker")
    with then("the dispatch is anthropic on the claude harness and its env is claude's",
              answer={"rail": doc["rail"], "harness": doc["harness"], "env_keys": sorted(doc["env"])}):
        then_eq("rail", doc["rail"], "anthropic")
        then_eq("harness", doc["harness"], "claude")
        assert "ANTHROPIC_MODEL" in doc["env"], sorted(doc["env"])
        assert not {"CODEX_MODEL", "OPENCODE_CONFIG_CONTENT"} & set(doc["env"]), sorted(doc["env"])
