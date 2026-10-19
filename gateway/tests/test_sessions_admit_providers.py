"""GW-SESSIONS-ADMIT §The provider axis — the openrouter cell is (rail, model, provider) once the endpoint
snapshot covers the model (specs/endpoints/sessions.md; GW-RAIL-OPENROUTER §Selection, homelab#2741).

World `policy-default · openrouter-endpoints` (the snapshot of deepseek/deepseek-v4.1-flash = the
openrouter heavy tier; `deepseek/deepseek-v4-flash` = the standard tier has no entry) unless a row says
`openrouter-endpoints-ineligible` (the snapshot trimmed to open-inference/fp4, alibaba and parasail/fp8 —
none clears the floors). T0 = 1_800_000_000. M = deepseek/deepseek-v4.1-flash.

| description | arrange | body || decision | rail | model | reason | retry_after_s |
|---|---|---||---|---|---|---|---|
| a provider cell strike leaves the model admissible while another eligible provider remains | T's earlier ride struck harness-gave-up on deepinfra | worker, rail openrouter, tier heavy, T || dispatch | openrouter | M | — | — |
| every eligible provider struck for the task: the model is exhausted | T's five earlier rides struck deepinfra, atlas-cloud, morph, inference-net, baidu | worker, rail openrouter, tier heavy, T || defer ({decision, reason} only) | — | — | cells-exhausted | — |
| every eligible provider cooled: cell-cooled until the earliest reset | two requests whose pinned attempts all answered 429 (retry-after 30) | worker, rail openrouter, tier heavy || defer | — | — | cell-cooled | 30 |
| no endpoint clears the floors: the model defers no-eligible-provider | openrouter-endpoints-ineligible | worker, rail openrouter, tier heavy || defer | — | — | no-eligible-provider | 60 |
| an ineligible model is skipped, the walk continues | openrouter-endpoints-ineligible | researcher, harness claude (rails openrouter, anthropic) || dispatch | anthropic | claude/sonnet | — | — |
| a provider strike with no snapshot to steer by excludes the model's cell | T's unpinned v4-flash ride (served by Sail Research) struck harness-gave-up | worker, rail openrouter, tier standard, T || defer ({decision, reason} only) | — | — | cells-exhausted | — |
"""

from __future__ import annotations

from .conftest import (
    attach_json,
    bearer,
    open_session,
    quiet,
    rule,
    seed_openrouter_endpoints,
    then,
    then_eq,
    when,
    world,
)

pytestmark = rule("GW-SESSIONS-ADMIT")
RAIL = "openrouter"
M = "deepseek/deepseek-v4.1-flash"
PATH = "/openai/v1/chat/completions"
INELIGIBLE = ("open-inference/fp4", "alibaba", "parasail/fp8")


def _seed(app, store, upstreams, only=None):
    body = seed_openrouter_endpoints(store, upstreams[RAIL], only=only)
    app.state.providers.reload()
    return body


async def _admit(gw, body: dict) -> dict:
    req = {"stack": "platform", "role": "worker", "task": "homelab-2741-admit", **body}
    with when(f"POST /sessions body {body}"):
        r = await gw.post("/sessions", json=req)
    then_eq("status", r.status_code, 200)
    return r.json()


def _verdict(doc: dict, expected: dict, escalate: bool = False) -> None:
    claim = "expected " + ", ".join(f"{k} = {v}" for k, v in expected.items())
    with then(claim, **{k: {"expected": v, "actual": doc.get(k)} for k, v in expected.items()}):
        assert {k: doc.get(k) for k in expected} == expected, f"{claim}: got {doc}"
    if escalate:
        with then("the defer carries exactly decision and reason (no retry_after_s)", keys={"expected": ["decision", "reason"], "actual": sorted(doc)}):
            assert set(doc) == {"decision", "reason"}


async def _strike(gw, task: str, tier: str = "heavy", display: str | None = None, upstreams=None) -> dict:
    with quiet():
        if display is not None and upstreams is not None:
            upstreams[RAIL].provider_display = display
        d = await open_session(gw, role="worker", harness="opencode", rail=RAIL, tier=tier, task=task)
        await gw.post(PATH, json={"model": d["model"], "messages": []}, headers=bearer(d))
        await gw.post(f"/sessions/{d['session']['id']}/outcome", json={"class": "harness-gave-up"})
        await gw.delete(f"/sessions/{d['session']['id']}")
    return d


async def test_one_provider_struck(gw, app, store, upstreams):
    """row: a provider cell strike leaves the model admissible while another eligible provider remains"""
    world(upstream="upstream-ok", note="openrouter-endpoints")
    _seed(app, store, upstreams)
    task = "homelab-2741-one-struck"
    await _strike(gw, task)
    attach_json("the task's strikes", store.strikes_for("platform", task))
    doc = await _admit(gw, {"rail": RAIL, "tier": "heavy", "harness": "opencode", "task": task})
    _verdict(doc, {"decision": "dispatch", "rail": RAIL, "model": M})


async def test_every_provider_struck(gw, app, store, upstreams):
    """row: every eligible provider struck for the task: the model is exhausted"""
    world(upstream="upstream-ok", note="openrouter-endpoints")
    _seed(app, store, upstreams)
    task = "homelab-2741-all-struck"
    for _ in range(5):
        await _strike(gw, task)
    attach_json("the task's strikes", [(s["class"], s["provider"]) for s in store.strikes_for("platform", task)])
    doc = await _admit(gw, {"rail": RAIL, "tier": "heavy", "harness": "opencode", "task": task, "attempt": 6})
    _verdict(doc, {"decision": "defer", "reason": "cells-exhausted"}, escalate=True)


async def test_every_provider_cooled(gw, app, store, upstreams):
    """row: every eligible provider cooled: cell-cooled until the earliest reset"""
    world(upstream="upstream-429", note="openrouter-endpoints; every eligible provider answers 429 retry-after 30")
    _seed(app, store, upstreams)
    for slug in ("deepinfra", "atlas-cloud", "morph", "inference-net", "baidu"):
        upstreams[RAIL].provider_behaviours[slug] = "upstream-429"
    with quiet():
        d = await open_session(gw, role="worker", harness="opencode", rail=RAIL, tier="heavy", task="homelab-2741-cool-arrange")
        r1 = await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(d))
        r2 = await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(d))
    attach_json("arranged: two requests, five pinned attempts, all 429", {"statuses": [r1.status_code, r2.status_code],
                                                                            "cooled": sorted(app.state.capacity.cooled_providers(RAIL, M, app.state.sessions.clock()))})
    doc = await _admit(gw, {"rail": RAIL, "tier": "heavy", "harness": "opencode"})
    _verdict(doc, {"decision": "defer", "reason": "cell-cooled", "retry_after_s": 30})


async def test_no_eligible_provider(gw, app, store, upstreams):
    """row: no endpoint clears the floors: the model defers no-eligible-provider"""
    world(note="openrouter-endpoints-ineligible")
    _seed(app, store, upstreams, only=INELIGIBLE)
    doc = await _admit(gw, {"rail": RAIL, "tier": "heavy", "harness": "opencode"})
    _verdict(doc, {"decision": "defer", "reason": "no-eligible-provider", "retry_after_s": 60})


async def test_ineligible_model_skipped(gw, app, store, upstreams):
    """row: an ineligible model is skipped, the walk continues"""
    world(note="openrouter-endpoints-ineligible")
    _seed(app, store, upstreams, only=INELIGIBLE)
    doc = await _admit(gw, {"role": "researcher", "harness": "claude"})
    _verdict(doc, {"decision": "dispatch", "rail": "anthropic", "model": "claude/sonnet"})


async def test_provider_strike_without_snapshot(gw, app, store, upstreams):
    """row: a provider strike with no snapshot to steer by excludes the model's cell"""
    world(upstream="upstream-ok", note="openrouter-endpoints; deepseek/deepseek-v4-flash has no entry, the fake names Sail Research")
    _seed(app, store, upstreams)
    task = "homelab-2741-no-steer"
    await _strike(gw, task, tier="standard", display="Sail Research", upstreams=upstreams)
    attach_json("the task's strikes", [(s["class"], s["model"], s["provider"]) for s in store.strikes_for("platform", task)])
    doc = await _admit(gw, {"rail": RAIL, "tier": "standard", "harness": "opencode", "task": task, "attempt": 2})
    _verdict(doc, {"decision": "defer", "reason": "cells-exhausted"}, escalate=True)
