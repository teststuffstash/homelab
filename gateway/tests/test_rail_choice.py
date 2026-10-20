"""GW-MODEL-TIERS §Cost per clean ride · §The Go price · §The rail choice · the evidence age (specs/endpoints/catalog.md; homelab#2743).

World `policy-default · openrouter-endpoints` (the snapshot of deepseek/deepseek-v4.1-flash = M seeded, every
cell eligible) with the Go catalog (`catalog-ok` + `docs-ok`, plan go: fee $10/month; deepseek-v4.1-flash
$80/month at list 0.15 in / 0.60 out). T0 = 1_800_000_000 (Fri 2027-01-15 08:00:00Z, a Go peak hour).
A worker with harness opencode at tier LIGHT: opencode names opencode-go/deepseek-v4.1-flash (MG), openrouter
names deepseek/deepseek-v4-flash then M — M and MG are twins. The cost terms are the world's `tiers.cost`:
0.01 M output tokens a ride, no strike overhead, 5 judged rides before a measured rate.

| description | out $/M | rides (clean / judged, prior) | tiers.cost (T · overhead · min_rides) || rate (basis) | $ per clean ride |
|---|---|---|---||---|---|
| a clean cell costs its price for one ride's tokens | 0.42 | 0 / 0, prior 1.0 | 0.01 · 0 · 5 || 1 (prior) | 0.0042 |
| under min_rides the prior stands | 0.42 | 2 / 4, prior 0.9 | 0.01 · 0 · 5 || 0.9 (prior) | 0.004667 |
| a measured clean rate of one half doubles the cost | 0.42 | 3 / 6, prior 1.0 | 0.01 · 0 · 5 || 0.5 (measured) | 0.0084 |
| the strike overhead is paid once per failed ride | 0.42 | 3 / 6, prior 1.0 | 0.01 · 0.10 · 5 || 0.5 (measured) | 0.1084 |
| a cell with no clean ride yet is unaffordable | 0.42 | 0 / 5, prior 1.0 | 0.01 · 0 · 5 || 0 (measured) | inf |

| description | the rail's trailing-30-day ledger || model | discount | basis | out $/M · in $/M |
|---|---||---|---|---|---|
| the plan's promise prices an idle rail | nothing || deepseek-v4.1-flash | 10 / 80 = 0.125 | promise | 0.075 · 0.01875 |
| each model's own allowance is its promise | nothing || claude-haiku-5-5 | 10 / 15 = 0.666667 | promise | 0.333333 · 0.066667 |
| a rail drawing past the allowance is priced on the meter | one worker ride at T0 + 2 h (off-peak) drawing in 1000M at $0.15 + out 100M at $0.60 = $210 at list || deepseek-v4.1-flash | 10 / 210 = 0.047619 | measured | 0.028571 · 0.007143 |
| an unlimited model prices at 0 | nothing || longcat-2.5-preview-free | 0 | unlimited | 0 · 0 |
| no fee read: no price | the docs snapshot written before the Plan table (its body without plan_fees) || deepseek-v4.1-flash | null | null | null · null |
| the price shows on GET /catalog/opencode | nothing || pricing: fee_usd_month 10, draw_30d_usd 0, models[deepseek-v4.1-flash] {out 0.075, in 0.01875, discount 0.125, basis promise, rides 0 / 0} | | | |

| description | arrange | body || decision | rail | model | rail_choice | gateway_rail_choice_total{model=M,rail,reason} |
|---|---|---||---|---|---|---|---|
| Go wins with free headroom and an equal clean rate | — | worker, tier light || dispatch | opencode | MG | opencode over openrouter: price | rail=opencode,reason=price 1 |
| openrouter wins when Go's window is near its share | a worker ride on opencode drew in 30M / out 3.2M at T0 ($12.84 ≥ 0.80 × $16) | the same || dispatch | openrouter | M (the twin at the head, ahead of the list's first id) | openrouter over opencode: headroom | rail=openrouter,reason=headroom 1 |
| openrouter wins when Go's clean rate is lower | six judged Go rides on MG, one clean (rate 1/6: $0.075 / 0.1667 = $0.45/M per clean ride, past deepinfra's $0.42) | the same || dispatch | openrouter | M | openrouter over opencode: clean-rate | rail=openrouter,reason=clean-rate 1 |
| no eligible openrouter endpoint: Go | the snapshot trimmed to the ineligible endpoints | the same || dispatch | opencode | MG | opencode over openrouter: no-eligible-endpoint | rail=opencode,reason=no-eligible-endpoint 1 |
| no openrouter cell has passed the entry canary yet: Go | every cell of M set back to candidate | the same || dispatch | opencode | MG | opencode over openrouter: no-eligible-endpoint | rail=opencode,reason=no-eligible-endpoint 1 |
| both twins held: no choice, the walk defers with the hold that lifts first | the window draw above; the snapshot ineligible; the task's earlier ride struck no-verdict on deepseek/deepseek-v4-flash | the same, that task || defer | — | — | — (a defer) | no series; reason no-eligible-provider, retry_after_s 60 |
| no twin at the tier: the role's order, no choice | — | worker, tier standard (opencode MG; openrouter deepseek/deepseek-v4-flash) || dispatch | opencode | MG | null | no series |
| the choice survives a failover: the ride's rows name the serving provider, its outcome judges that cell | the window draw above; the openrouter ride's deepinfra attempt answers 500 | the same, then one ride and a clean outcome || dispatch | openrouter | M | headroom | the session's request rows deepinfra 500 then atlas-cloud 200; GET /catalog/openrouter rides: atlas-cloud 1 / 1, deepinfra 0 / 0 |

| description | the mounted snapshot || gateway_tier_evidence_age_seconds |
|---|---||---|
| age is seconds since snapshot_at | a file with snapshot_at T0 − 600, GATEWAY_BENCHMARKS naming it || 600 |
| no snapshot mounted, no series | GATEWAY_BENCHMARKS naming a missing file || absent |
"""

from __future__ import annotations

import dataclasses
import json
import math
import re

import httpx
import pytest

from agent_gateway.app import create_app
from agent_gateway.config import CostPolicy
from agent_gateway.tiers import clean_rate, cost_per_clean_ride

from .conftest import (
    ObservedAsyncClient,
    attach_json,
    bearer,
    check,
    given,
    open_session,
    quiet,
    rule,
    seed_openrouter_endpoints,
    then,
    then_eq,
    when,
    world,
)

pytestmark = rule("GW-MODEL-TIERS")
M = "deepseek/deepseek-v4.1-flash"
MG = "opencode-go/deepseek-v4.1-flash"
M2 = "deepseek/deepseek-v4-flash"
WORLD = "openrouter-endpoints + the Go catalog"
INELIGIBLE = ("open-inference/fp4", "alibaba", "parasail/fp8")
MESSAGES = "/anthropic/v1/messages"
CHAT = "/openai/v1/chat/completions"
COST = CostPolicy(0.01, 0.0, 5)


# ── §Cost per clean ride ────────────────────────────────────────────────────────────────────
COST_ROWS = [
    ("a clean cell costs its price for one ride's tokens", 0.42, (0, 0, 1.0), (0.01, 0.0, 5), (1.0, "prior"), 0.0042),
    ("under min_rides the prior stands", 0.42, (2, 4, 0.9), (0.01, 0.0, 5), (0.9, "prior"), 0.004667),
    ("a measured clean rate of one half doubles the cost", 0.42, (3, 6, 1.0), (0.01, 0.0, 5), (0.5, "measured"), 0.0084),
    ("the strike overhead is paid once per failed ride", 0.42, (3, 6, 1.0), (0.01, 0.10, 5), (0.5, "measured"), 0.1084),
    ("a cell with no clean ride yet is unaffordable", 0.42, (0, 5, 1.0), (0.01, 0.0, 5), (0.0, "measured"), math.inf),
]


@pytest.mark.parametrize(("price", "rides", "terms", "rate", "cost"), [r[1:] for r in COST_ROWS], ids=[r[0] for r in COST_ROWS])
def test_cost_per_clean_ride(price, rides, terms, rate, cost):
    world(note="a hand-written cell")
    clean, judged, prior = rides
    pol = CostPolicy(*terms)
    with given(f"a cell priced ${price}/M out with {clean} clean of {judged} judged rides (prior {prior}); tiers.cost terms {terms} = T {terms[0]} · overhead {terms[1]} · min_rides {terms[2]}"):
        attach_json("cell", {"out_price": price, "rides": {"clean": clean, "judged": judged, "prior": prior}, "cost": dataclasses.asdict(pol)})
    with when("clean_rate(clean, judged, prior, min_rides), then cost_per_clean_ride(price, rate, cost)"):
        r, basis = clean_rate(clean, judged, prior, pol.min_rides)
        c = cost_per_clean_ride(price, r, pol)
    then_eq("rate (basis)", (round(r, 6), basis.split(" ")[0]), rate)
    then_eq("$ per clean ride", round(c, 6) if math.isfinite(c) else c, cost)


# ── §The Go price ───────────────────────────────────────────────────────────────────────────
async def _go_ride(gw, upstreams, usage: dict, tier: str = "light", task: str = "homelab-2743-draw") -> dict:
    """One worker ride on opencode (harness claude: the anthropic dialect's usage is the row's)."""
    with quiet():
        doc = await open_session(gw, role="worker", rail="opencode", harness="claude", tier=tier, task=task)
        up = upstreams["opencode"]
        up.usage = usage
        r = await gw.post(MESSAGES, headers=bearer(doc), json={"max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]})
        up.usage = None
    attach_json(f"arranged Go ride: {doc['model']} usage {usage} → {r.status_code}", {"session": doc["session"]["id"], "usage": usage, "status": r.status_code})
    return doc


def _pricing(app) -> dict:
    return app.state.capacity.go_pricing("opencode", app.state.sessions.clock())


async def test_go_price_promise(app):
    """row: the plan's promise prices an idle rail"""
    world(note=f"{WORLD}; no ride on the opencode rail")
    with when("capacity.go_pricing(opencode) over an empty ledger"):
        p = _pricing(app)
        attach_json("pricing", p)
    row = p["models"]["deepseek-v4.1-flash"]
    then_eq("fee · draw_30d", (p["fee_usd_month"], p["draw_30d_usd"]), (10.0, 0.0))
    then_eq("deepseek-v4.1-flash discount · basis · out · in", (row["discount"], row["basis"], row["out"], row["in"]), (0.125, "promise", 0.075, 0.01875))


async def test_go_price_own_allowance(app):
    """row: each model's own allowance is its promise"""
    world(note=f"{WORLD}; no ride on the opencode rail")
    with when("capacity.go_pricing(opencode) over an empty ledger"):
        row = _pricing(app)["models"]["claude-haiku-5-5"]
        attach_json("claude-haiku-5-5", row)
    then_eq("discount · basis · out · in", (round(row["discount"], 6), row["basis"], round(row["out"], 6), round(row["in"], 6)),
            (0.666667, "promise", 0.333333, 0.066667))


async def test_go_price_measured(gw, app, upstreams, clock):
    """row: a rail drawing past the allowance is priced on the meter"""
    world(upstream="upstream-ok (usage in 1000M / out 100M)", note=f"{WORLD}; one ride at T0 + 2 h, off-peak")
    with given("one worker ride at T0 + 2 h drawing in 1000M at $0.15 + out 100M at $0.60 = $210 at list"):
        clock.advance(7200)
        await _go_ride(gw, upstreams, {"input_tokens": 1_000_000_000, "output_tokens": 100_000_000})
    with when("capacity.go_pricing(opencode)"):
        p = _pricing(app)
        attach_json("pricing", p)
    row = p["models"]["deepseek-v4.1-flash"]
    then_eq("draw_30d_usd", round(p["draw_30d_usd"], 6), 210.0)
    then_eq("deepseek-v4.1-flash discount · basis · out · in", (round(row["discount"], 6), row["basis"], round(row["out"], 6), round(row["in"], 6)),
            (0.047619, "measured", 0.028571, 0.007143))


async def test_go_price_unlimited(app):
    """row: an unlimited model prices at 0"""
    world(note=f"{WORLD}; no ride on the opencode rail")
    with when("capacity.go_pricing(opencode)"):
        row = _pricing(app)["models"]["longcat-2.5-preview-free"]
        attach_json("longcat-2.5-preview-free", row)
    then_eq("discount · basis · out · in", (row["discount"], row["basis"], row["out"], row["in"]), (0.0, "unlimited", 0.0, 0.0))


async def test_go_price_no_fee(app):
    """row: no fee read: no price"""
    world(note=f"{WORLD}; the docs snapshot's body without plan_fees (written before the Plan table was read)")
    with given("the stored docs snapshot carries no plan_fees"):
        del app.state.catalog.snapshots["docs"].body["plan_fees"]
    with when("capacity.go_pricing(opencode)"):
        p = _pricing(app)
        attach_json("pricing", p)
    row = p["models"]["deepseek-v4.1-flash"]
    then_eq("fee · deepseek-v4.1-flash discount · basis · out · in", (p["fee_usd_month"], row["discount"], row["basis"], row["out"], row["in"]),
            (None, None, None, None, None))


async def test_go_price_view(gw):
    """row: the price shows on GET /catalog/opencode"""
    world(note=f"{WORLD}; no ride on the opencode rail")
    with when("GET /catalog/opencode"):
        v = (await gw.get("/catalog/opencode")).json()
    p = v["pricing"]
    then_eq("pricing.fee_usd_month · draw_30d_usd", (p["fee_usd_month"], p["draw_30d_usd"]), (10.0, 0.0))
    then_eq("pricing.models[deepseek-v4.1-flash]", p["models"]["deepseek-v4.1-flash"],
            {"out": 0.075, "in": 0.01875, "discount": 0.125, "basis": "promise", "rides": {"clean": 0, "judged": 0}})


# ── §The rail choice ────────────────────────────────────────────────────────────────────────
def _seed(app, store, upstreams, only=None):
    body = seed_openrouter_endpoints(store, upstreams["openrouter"], only=only)
    app.state.providers.reload()
    return body


async def _admit(gw, body: dict) -> dict:
    req = {"stack": "platform", "role": "worker", "harness": "opencode", "task": "homelab-2743-choice", **body}
    with when(f"POST /sessions body {body}"):
        r = await gw.post("/sessions", json=req)
    then_eq("status", r.status_code, 200)
    return r.json()


async def _choice_series(gw) -> dict[tuple[str, str, str], float]:
    with quiet():
        text = (await gw.get("/metrics")).text
    out = {}
    for m in re.finditer(r'^gateway_rail_choice_total\{model="([^"]*)",rail="([^"]*)",reason="([^"]*)"\} (\S+)$', text, re.M):
        out[(m.group(1), m.group(2), m.group(3))] = float(m.group(4))
    return out


def _verdict(doc: dict, decision: str, rail: str | None, model: str | None, choice: dict | None) -> None:
    expected = {"decision": decision, "rail": rail, "model": model, "rail_choice": choice}
    claim = "expected " + ", ".join(f"{k} = {v}" for k, v in expected.items())
    with then(claim, **{k: {"expected": v, "actual": doc.get(k)} for k, v in expected.items()}):
        assert {k: doc.get(k) for k in expected} == expected, doc


async def _series_is(gw, rail: str | None, reason: str | None) -> None:
    series = await _choice_series(gw)
    if rail is None:
        then_eq("gateway_rail_choice_total series", series, {}, claim="no rail choice series")
    else:
        then_eq(f"gateway_rail_choice_total{{model={M},rail={rail},reason={reason}}}", series.get((M, rail, reason)), 1.0)


async def test_go_wins(gw, app, store, upstreams):
    """row: Go wins with free headroom and an equal clean rate"""
    world(note=WORLD)
    _seed(app, store, upstreams)
    with given("no ride on either rail: Go's promise $0.075/M vs deepinfra's $0.42/M, both at the prior rate 1.0"):
        attach_json("standing", {"go": _pricing(app)["models"]["deepseek-v4.1-flash"]})
    doc = await _admit(gw, {"tier": "light"})
    _verdict(doc, "dispatch", "opencode", MG, {"rail": "opencode", "over": "openrouter", "reason": "price"})
    await _series_is(gw, "opencode", "price")


async def test_openrouter_wins_headroom(gw, app, store, upstreams):
    """row: openrouter wins when Go's window is near its share"""
    world(upstream="upstream-ok (usage in 30M / out 3.2M)", note=f"{WORLD}; the Go 5h window at $12.84 ≥ 0.80 × $16")
    _seed(app, store, upstreams)
    with given("a worker ride on opencode drew in 30M / out 3.2M at T0 (peak: $12.84, over the 5h threshold $12.80)"):
        await _go_ride(gw, upstreams, {"input_tokens": 30_000_000, "output_tokens": 3_200_000})
    doc = await _admit(gw, {"tier": "light"})
    _verdict(doc, "dispatch", "openrouter", M, {"rail": "openrouter", "over": "opencode", "reason": "headroom"})
    await _series_is(gw, "openrouter", "headroom")


async def test_openrouter_wins_clean_rate(gw, app, store, upstreams):
    """row: openrouter wins when Go's clean rate is lower"""
    world(upstream="upstream-ok", note=f"{WORLD}; six judged Go rides on MG, one clean")
    _seed(app, store, upstreams)
    with given("six judged worker rides on opencode-go/deepseek-v4.1-flash (distinct tasks), one clean, five harness-gave-up"):
        for i in range(6):
            doc = await _go_ride(gw, upstreams, {"input_tokens": 12, "output_tokens": 7}, task=f"homelab-2743-rate-{i}")
            with quiet():
                await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": "clean" if i == 0 else "harness-gave-up"})
                await gw.delete(f"/sessions/{doc['session']['id']}")
        attach_json("the Go cell's rides", store.cell_outcomes("opencode", MG))
    doc = await _admit(gw, {"tier": "light"})
    _verdict(doc, "dispatch", "openrouter", M, {"rail": "openrouter", "over": "opencode", "reason": "clean-rate"})
    await _series_is(gw, "openrouter", "clean-rate")


async def test_go_wins_no_eligible_endpoint(gw, app, store, upstreams):
    """row: no eligible openrouter endpoint: Go"""
    world(note=f"{WORLD}; the snapshot trimmed to {INELIGIBLE}")
    _seed(app, store, upstreams, only=INELIGIBLE)
    doc = await _admit(gw, {"tier": "light"})
    _verdict(doc, "dispatch", "opencode", MG, {"rail": "opencode", "over": "openrouter", "reason": "no-eligible-endpoint"})
    await _series_is(gw, "opencode", "no-eligible-endpoint")


async def test_go_wins_no_canaried_cell(gw, app, store, upstreams):
    """row: no openrouter cell has passed the entry canary yet: Go"""
    world(note=f"{WORLD}; every cell of M set back to candidate")
    body = _seed(app, store, upstreams)
    with given("every (M, provider) cell is a candidate — none has passed the entry canary (the production state of 2026-10-20)"):
        now = app.state.sessions.clock()
        for e in body["models"][M]["endpoints"]:
            store.cell_set(M, e["slug"], "candidate", None, now, None)
        attach_json("cells", store.cells_count(now))
    doc = await _admit(gw, {"tier": "light"})
    _verdict(doc, "dispatch", "opencode", MG, {"rail": "opencode", "over": "openrouter", "reason": "no-eligible-endpoint"})
    await _series_is(gw, "opencode", "no-eligible-endpoint")


async def test_both_held(gw, app, store, upstreams):
    """row: both twins held: no choice, the walk defers with the hold that lifts first"""
    world(upstream="upstream-ok", note=f"{WORLD}; the Go window full, the snapshot ineligible, deepseek/deepseek-v4-flash struck for the task")
    _seed(app, store, upstreams, only=INELIGIBLE)
    task = "homelab-2743-both-held"
    with given("the Go 5h window over its threshold; the task's earlier openrouter ride on deepseek/deepseek-v4-flash struck no-verdict"):
        await _go_ride(gw, upstreams, {"input_tokens": 30_000_000, "output_tokens": 3_200_000})
        with quiet():
            d = await open_session(gw, role="worker", harness="opencode", rail="openrouter", tier="standard", task=task)
            await gw.post(CHAT, json={"model": d["model"], "messages": []}, headers=bearer(d))
            await gw.post(f"/sessions/{d['session']['id']}/outcome", json={"class": "no-verdict"})
            await gw.delete(f"/sessions/{d['session']['id']}")
        attach_json("the task's strikes", [(s["class"], s["model"], s["scope"]) for s in store.strikes_for("platform", task)])
    doc = await _admit(gw, {"tier": "light", "task": task, "attempt": 2})
    with then("defer no-eligible-provider, retry_after_s 60 (the hold that lifts first), no rail_choice",
              answer={"expected": {"decision": "defer", "reason": "no-eligible-provider", "retry_after_s": 60}, "actual": doc}):
        assert doc == {"decision": "defer", "reason": "no-eligible-provider", "retry_after_s": 60}
    await _series_is(gw, None, None)


async def test_no_twin(gw, app, store, upstreams):
    """row: no twin at the tier: the role's order, no choice"""
    world(note=f"{WORLD}; tier standard names opencode-go/deepseek-v4.1-flash and deepseek/deepseek-v4-flash — no twin")
    _seed(app, store, upstreams)
    doc = await _admit(gw, {"tier": "standard"})
    _verdict(doc, "dispatch", "opencode", MG, None)
    await _series_is(gw, None, None)


async def test_choice_survives_failover(gw, app, store, upstreams):
    """row: the choice survives a failover: the ride's rows name the serving provider, its outcome judges that cell"""
    world(upstream="upstream-ok", note=f"{WORLD}; the Go window full; deepinfra answers 500")
    _seed(app, store, upstreams)
    with given("the Go 5h window over its threshold; the openrouter fake's deepinfra behaviour upstream-500"):
        await _go_ride(gw, upstreams, {"input_tokens": 30_000_000, "output_tokens": 3_200_000})
        upstreams["openrouter"].provider_behaviours["deepinfra"] = "upstream-500"
    # Three phases at the top level (the admission, the ride, the view) — the verdicts of each phase
    # are checks INSIDE its then step, never a flat run of then_eq steps (CONVENTIONS § STEP_NOISE).
    body = {"tier": "light"}
    with when(f"POST /sessions body {body}"):
        r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "harness": "opencode", "task": "homelab-2743-choice", **body})
    doc = r.json()
    with then("status 200; decision dispatch, rail openrouter over opencode (headroom), model M"):
        check("status · decision · rail · model · rail_choice", {"status": r.status_code, **{k: doc.get(k) for k in ("decision", "rail", "model", "rail_choice")}},
              {"status": 200, "decision": "dispatch", "rail": "openrouter", "model": M, "rail_choice": {"rail": "openrouter", "over": "opencode", "reason": "headroom"}})
    with when("one ride (deepinfra 500 → atlas-cloud 200), then outcome clean"):
        r = await gw.post(CHAT, json={"model": M, "messages": []}, headers=bearer(doc))
        o = await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": "clean"})
    with then("ride 200 · outcome 200; the session's request rows (provider, status) deepinfra 500 then atlas-cloud 200"):
        rows = [(x["provider"], x["status"]) for x in store.requests_for(doc["session"]["id"])]
        check("ride status · outcome status · request rows", ((r.status_code, o.status_code), rows), ((200, 200), [("deepinfra", 500), ("atlas-cloud", 200)]))
    with then("GET /catalog/openrouter rides: atlas-cloud 1 / 1, deepinfra 0 / 0"):
        with quiet():  # the view read's exchange folds into the check (ATTACH_BULK)
            v = (await gw.get("/catalog/openrouter")).json()
        rides = {e["slug"]: e["rides"] for e in v["models"][M]["endpoints"] if e["service_tier"] is None}
        check("rides atlas-cloud · deepinfra", (rides["atlas-cloud"], rides["deepinfra"]), ({"clean": 1, "judged": 1}, {"clean": 0, "judged": 0}))


# ── the evidence age ────────────────────────────────────────────────────────────────────────
AGE_ROWS = [("age is seconds since snapshot_at", True, 600.0), ("no snapshot mounted, no series", False, None)]


@pytest.mark.parametrize(("mounted", "age"), [r[1:] for r in AGE_ROWS], ids=[r[0] for r in AGE_ROWS])
async def test_evidence_age(settings, policy, secrets, store, mcp_transport, clock, reviews, pods, tmp_path, mounted, age):
    world(note="policy-default; GATEWAY_BENCHMARKS = a scratch file")
    path = tmp_path / "benchmarks.json"
    with given(f"GATEWAY_BENCHMARKS {path.name}: " + ("a snapshot with snapshot_at T0 − 600 s" if mounted else "no such file")):
        if mounted:
            at = clock() - 600
            from agent_gateway.tiers import _iso

            path.write_text(json.dumps({"snapshot_at": _iso(at), "sources": {}, "rails": {}}), encoding="utf-8")
        attach_json("file", {"path": str(path), "exists": path.exists()})
    client = httpx.AsyncClient(transport=mcp_transport)
    app = create_app(dataclasses.replace(settings, benchmarks_path=str(path)), policy=policy, source=secrets, store=store,
                     client=client, clock=clock, reviewer=reviews, pods=pods)
    try:
        async with ObservedAsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://gw") as c:
            with when("GET /metrics"):
                text = (await c.get("/metrics")).text
    finally:
        await client.aclose()
    m = re.search(r"^gateway_tier_evidence_age_seconds (\S+)$", text, re.M)
    then_eq("gateway_tier_evidence_age_seconds", float(m.group(1)) if m else None, age,
            claim=f"gateway_tier_evidence_age_seconds {'= ' + str(age) if age is not None else 'absent'}")
    with then("HELP and TYPE declared either way"):
        check("declared", "# TYPE gateway_tier_evidence_age_seconds gauge" in text, True)
