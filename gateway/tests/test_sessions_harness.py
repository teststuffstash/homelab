"""GW-SESSIONS-ADMIT §The harness follows the cell (specs/endpoints/sessions.md) — the operator's
2026-10-23 ruling (every subscription rail is every role's, so the walk crosses the dialect boundary
on its own) and the 2026-10-24 one (homelab#2870: the harness is taken LAST, from the (rail, model)
cell — a Go cell's dialect is its model's). Rows run in the `policy-codex` world (roles shaped as
the ruling; codex `max_sessions` 2, anthropic 5, opencode 3; the opencode standard list carries both
dialect shapes — `deepseek-v4.1-flash` openai first, `claude-haiku-5-5` anthropic second) with
codex headroom fresh at 20 % / 64 %.

| description | role | body | active on rails (anthropic / opencode / codex) || decision | rail | harness | model |
|---|---|---|---||---|---|---|---|
| without a harness the walk crosses the dialect boundary: the reviewer reaches codex | reviewer | (defaults) | 5 / 3 / 0 || dispatch | codex | codex | codex/fixture-model |
| a dual-dialect rail keeps the role's harness | reviewer | (defaults) | 5 / 0 / 0 || dispatch | opencode | claude | opencode-go/claude-haiku-5-5 |
| the Go cell's dialect is the model's: an openai cell rides the opencode harness | reviewer | tier: standard | 5 / 0 / 0 || dispatch | opencode | opencode | opencode-go/deepseek-v4.1-flash |
| an explicit harness on the Go rail skips the openai cells and takes the Claude model | reviewer | harness: claude, tier: standard | 5 / 0 / 0 || dispatch | opencode | claude | opencode-go/claude-haiku-5-5 |
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


async def test_cell_dialect_names_the_harness(codex_app, codex_gw, clock):
    """row: the Go cell's dialect is the model's: an openai cell rides the opencode harness"""
    world("policy-codex")
    await _arrange(codex_app, codex_gw, clock, {"anthropic": 5})
    with when("POST /sessions {role: reviewer, tier: standard} — no harness; the subscription is full"):
        r = await codex_gw.post("/sessions", json={"stack": "platform", "task": "homelab-2588-r1",
                                                   "role": "reviewer", "tier": "standard"})
    then_eq("status", r.status_code, 200)
    doc = r.json()
    with then("the walk takes the tier list's first cell (deepseek-v4.1-flash, openai) and the harness that speaks it",
              answer={k: doc.get(k) for k in ("decision", "rail", "harness", "model")}):
        then_eq("decision", doc["decision"], "dispatch")
        then_eq("rail", doc["rail"], "opencode")
        then_eq("harness", doc["harness"], "opencode")
        then_eq("model", doc["model"], "opencode-go/deepseek-v4.1-flash")


async def test_explicit_harness_skips_the_openai_cells(codex_app, codex_gw, clock):
    """row: an explicit harness on the Go rail skips the openai cells and takes the Claude model"""
    world("policy-codex")
    await _arrange(codex_app, codex_gw, clock, {"anthropic": 5})
    with when("POST /sessions {role: reviewer, harness: claude, tier: standard} — the subscription is full"):
        r = await codex_gw.post("/sessions", json={"stack": "platform", "task": "homelab-2588-r1",
                                                   "role": "reviewer", "harness": "claude", "tier": "standard"})
    then_eq("status", r.status_code, 200)
    doc = r.json()
    with then("dispatch on opencode with the Claude model — the openai cell was skipped, never ridden",
              answer={k: doc.get(k) for k in ("decision", "rail", "harness", "model")}):
        then_eq("decision", doc["decision"], "dispatch")
        then_eq("rail", doc["rail"], "opencode")
        then_eq("harness", doc["harness"], "claude")
        then_eq("model", doc["model"], "opencode-go/claude-haiku-5-5")


# -- §Harness-scoped strikes (operator ruling 2026-10-24, homelab#2867's round 1) -------------------
# A harness fault excludes the struck harness on every cell for the task, never the model. Strikes are
# arranged through the outcome endpoint on earlier sessions of the SAME task T (never seeded).
T = "homelab-2867-r1"
WORKER_T = {"stack": "platform", "role": "worker", "task": T, "round": 1}
STRUCK = "`harness-fault` on harness opencode"
REFUTED = ("`harness-fault` on harness opencode (attempt 1), then `clean` on attempt 2's opencode session "
           "(tier heavy, admitted before the strike)")

# (description, arrange, body, decision, rail, harness, model, reason)
HARNESS_STRIKE_ROWS = [
    ("a harness strike moves the walk to a cell another harness speaks ⚖", STRUCK,
     "worker, T, `attempt: 2`", "dispatch", "codex", "codex", "codex/fixture-model", "—"),
    ("a harness strike excludes no model", STRUCK,
     "worker, T, `harness: goose`, `attempt: 2`", "dispatch", "opencode", "goose", "opencode-go/deepseek-v4.1-flash", "—"),
    ("an explicit harness that is struck defers ⚖", STRUCK,
     "worker, T, `harness: opencode`, `attempt: 2`", "defer (`{decision, reason}` only)", "—", "—", "—", "cells-exhausted"),
    ("a refuted harness strike excludes nothing", REFUTED,
     "worker, T, `attempt: 3`", "dispatch", "opencode", "opencode", "opencode-go/deepseek-v4.1-flash", "—"),
]
BODIES = {
    "worker, T, `attempt: 2`": {"attempt": 2},
    "worker, T, `harness: goose`, `attempt: 2`": {"harness": "goose", "attempt": 2},
    "worker, T, `harness: opencode`, `attempt: 2`": {"harness": "opencode", "attempt": 2},
    "worker, T, `attempt: 3`": {"attempt": 3},
}


async def _report(gw, doc: dict, klass: str) -> dict:
    r = await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": klass})
    assert r.status_code == 200, r.text
    return r.json()


async def _arrange_strike(app, gw, clock, arrange: str) -> None:
    with given("codex headroom observed fresh: 20 % / 64 % (the rail's admission gate)"):
        app.state.codex.headroom.observe(fresh_report(clock))
    with given(f"arrange = {arrange}"):
        with quiet():
            first = await open_session(gw, **WORKER_T)
            second = await open_session(gw, **WORKER_T, attempt=2, tier="heavy") if arrange == REFUTED else None
            struck = await _report(gw, first, "harness-fault")
            await gw.delete(f"/sessions/{first['session']['id']}")
            clean = None
            if second is not None:
                clock.advance(1)
                clean = await _report(gw, second, "clean")
                await gw.delete(f"/sessions/{second['session']['id']}")
        attach_json("arranged: the task's outcomes", {
            "attempt 1": {"rail": first["rail"], "harness": first["harness"], "model": first["model"], "strike": struck["strike"]},
            **({"attempt 2": {"rail": second["rail"], "harness": second["harness"], "model": second["model"],
                              "refuted": clean["refuted"]}} if second is not None else {}),
        })
        assert (first["rail"], first["harness"]) == ("opencode", "opencode"), first
        assert struck["strike"] == {"class": "harness-fault", "scope": "harness"}, struck


@pytest.mark.parametrize(("arrange", "body", "decision", "rail", "harness", "model", "reason"),
                         [r[1:] for r in HARNESS_STRIKE_ROWS], ids=[r[0] for r in HARNESS_STRIKE_ROWS])
async def test_harness_scoped_strike(codex_app, codex_gw, clock, arrange, body, decision, rail, harness, model, reason):
    world("policy-codex")
    await _arrange_strike(codex_app, codex_gw, clock, arrange)
    req = {**WORKER_T, **BODIES[body]}
    with when(f"POST /sessions {req}"):
        r = await codex_gw.post("/sessions", json=req)
    then_eq("status", r.status_code, 200)
    doc = r.json()
    if decision == "dispatch":
        expected = {"decision": "dispatch", "rail": rail, "harness": harness, "model": model}
    else:
        expected = {"decision": "defer", "reason": reason}
    claim = "expected " + ", ".join(f"{k} = {v}" for k, v in expected.items())
    with then(claim, **{k: {"expected": v, "actual": doc.get(k)} for k, v in expected.items()}):
        for k, v in expected.items():
            assert doc.get(k) == v, f"{k}: expected {v!r}, got {doc.get(k)!r}"
    if decision != "dispatch":
        with then("no retry_after_s: waiting does not help — the platform fixes the harness",
                  keys={"expected": ["decision", "reason"], "actual": sorted(doc)}):
            assert set(doc) == {"decision", "reason"}, doc
