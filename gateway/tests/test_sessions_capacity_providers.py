"""GW-SESSIONS-CAPACITY §The provider axis — the openrouter cell is (rail, model, provider) once the
endpoint snapshot covers the model (specs/endpoints/sessions.md; GW-RAIL-OPENROUTER §Selection,
homelab#2741). World `policy-default · openrouter-endpoints` (the snapshot of deepseek/deepseek-v4.1-flash
= the openrouter heavy tier; `deepseek/deepseek-v4-flash` = the standard tier has no entry) or
`openrouter-endpoints-ineligible` (the snapshot trimmed to open-inference/fp4, alibaba and parasail/fp8
— none clears the floors). T0 = 1_800_000_000. Header == argnames, description == id (tests/_rows.py)."""

from __future__ import annotations

import pytest

from ._rows import ABSENT, DASH, POLICY, body_of, enter_world, expect, inputs
from .conftest import attach_json, bearer, given, open_session, quiet, rule, seed_openrouter_endpoints, when

pytestmark = rule("GW-SESSIONS-CAPACITY")
RAIL = "openrouter"
M = "deepseek/deepseek-v4.1-flash"
PATH = "/openai/v1/chat/completions"
INELIGIBLE = ("open-inference/fp4", "alibaba", "parasail/fp8")

ONE_STRUCK = "T's earlier ride struck harness-gave-up on deepinfra"
ALL_STRUCK = "T's five earlier rides struck deepinfra, atlas-cloud, morph, inference-net, baidu"
ALL_COOLED = "two requests whose pinned attempts all answered 429 (retry-after: 30)"
NO_STEER = "T's unpinned v4-flash ride (served by Sail Research) struck harness-gave-up"
# T = the row's task (strikes are per task)
TASKS = {ONE_STRUCK: "homelab-2741-one-struck", ALL_STRUCK: "homelab-2741-all-struck", ALL_COOLED: "homelab-2741-cooled",
         NO_STEER: "homelab-2741-no-steer", DASH: "homelab-2741-admit"}


def _seed(app, store, upstreams, world: str):
    only = INELIGIBLE if "ineligible" in world else None
    body = seed_openrouter_endpoints(store, upstreams[RAIL], only=only)
    app.state.providers.reload()
    return body


async def _strike(gw, task: str, tier: str = "heavy", display: str | None = None, upstreams=None) -> dict:
    with quiet():
        if display is not None and upstreams is not None:
            upstreams[RAIL].provider_display = display
        d = await open_session(gw, role="worker", rail=RAIL, tier=tier, task=task)
        await gw.post(PATH, json={"model": d["model"], "messages": []}, headers=bearer(d))
        await gw.post(f"/sessions/{d['session']['id']}/outcome", json={"class": "harness-gave-up"})
        await gw.delete(f"/sessions/{d['session']['id']}")
    return d


async def _arrange(gw, app, store, upstreams, arrange: str, task: str) -> None:
    with given(f"arrange = {arrange}"):
        if arrange == ONE_STRUCK:
            await _strike(gw, task)
            attach_json("the task's strikes", [(s["class"], s["provider"]) for s in store.strikes_for("platform", task)])
        elif arrange == ALL_STRUCK:
            for _ in range(5):
                await _strike(gw, task)
            attach_json("the task's strikes", [(s["class"], s["provider"]) for s in store.strikes_for("platform", task)])
        elif arrange == ALL_COOLED:
            for slug in ("deepinfra", "atlas-cloud", "morph", "inference-net", "baidu"):
                upstreams[RAIL].provider_behaviours[slug] = "upstream-429"
            with quiet():
                d = await open_session(gw, role="worker", rail=RAIL, tier="heavy", task="homelab-2741-cool-arrange")
                r1 = await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(d))
                r2 = await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(d))
            attach_json("arranged: two requests, five pinned attempts, all 429",
                        {"statuses": [r1.status_code, r2.status_code],
                         "cooled": sorted(app.state.capacity.cooled_providers(RAIL, M, app.state.sessions.clock()))})
        elif arrange == NO_STEER:
            await _strike(gw, task, tier="standard", display="Sail Research", upstreams=upstreams)
            attach_json("the task's strikes", [(s["class"], s["model"], s["provider"]) for s in store.strikes_for("platform", task)])


PROVIDER_ROWS = [
    pytest.param("policy-default · openrouter-endpoints", ONE_STRUCK, "worker", RAIL, "heavy", 2,
                 "dispatch", RAIL, M, DASH, DASH, id="a provider cell strike leaves the model admissible while another eligible provider remains ⚖"),
    pytest.param("policy-default · openrouter-endpoints", ALL_STRUCK, "worker", RAIL, "heavy", 6,
                 "defer", DASH, DASH, "cells-exhausted", ABSENT, id="every eligible provider struck for the task: the model is exhausted ⚖"),
    pytest.param("policy-default · openrouter-endpoints · upstream-429", ALL_COOLED, "worker", RAIL, "heavy", 1,
                 "defer", DASH, DASH, "cell-cooled", 30, id="every eligible provider cooled: cell-cooled until the earliest reset ⚖"),
    pytest.param("policy-default · openrouter-endpoints-ineligible", DASH, "worker", RAIL, "heavy", 1,
                 "defer", DASH, DASH, "no-eligible-provider", 60, id="no endpoint clears the floors: the model defers no-eligible-provider ⚖"),
    pytest.param("policy-default · openrouter-endpoints-ineligible", DASH, "researcher", POLICY, POLICY, 1,
                 "dispatch", "anthropic", "claude/sonnet", DASH, DASH, id="an ineligible model is skipped, the walk continues"),
    pytest.param("policy-default · openrouter-endpoints", NO_STEER, "worker", RAIL, "standard", 2,
                 "defer", DASH, DASH, "cells-exhausted", ABSENT, id="a provider strike with no snapshot to steer by excludes the model's cell ⚖"),
]


@pytest.mark.parametrize(("world", "arrange", "role", "rail", "tier", "attempt",
                          "expected_decision", "expected_rail", "expected_model", "expected_reason", "expected_retry_after_s"), PROVIDER_ROWS)
async def test_the_provider_axis(gw, app, store, upstreams, world, arrange, role, rail, tier, attempt,
                                 expected_decision, expected_rail, expected_model, expected_reason, expected_retry_after_s):
    enter_world(world)
    inputs(arrange=arrange, role=role, rail=rail, tier=tier, attempt=attempt)
    task = TASKS[arrange]
    with given(f"the endpoint snapshot of the world {world} is loaded"):
        _seed(app, store, upstreams, world)
    await _arrange(gw, app, store, upstreams, arrange, task)
    body = {"stack": "platform", "task": task, "attempt": attempt, **body_of(role=role, rail=rail, tier=tier)}
    with when(f"POST /sessions {body}"):
        r = await gw.post("/sessions", json=body)
    assert r.status_code == 200, r.text
    expect(r.json(), decision=expected_decision, rail=expected_rail, model=expected_model, reason=expected_reason, retry_after_s=expected_retry_after_s)
