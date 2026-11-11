"""GW-RAIL-CHOICE — the twin rule and the admission's rail choice between a model's twin cells on two
rails (specs/endpoints/catalog.md §The tier evidence; homelab#2743).

World `policy-default · openrouter-endpoints` (the snapshot of deepseek/deepseek-v4.1-flash = M seeded, every
cell eligible) with the Go catalog (`catalog-ok` + `docs-ok`, plan go: fee $10/month; deepseek-v4.1-flash
$80/month at list 0.15 in / 0.60 out). T0 = 1_800_000_000 (Fri 2027-01-15 08:00:00Z, a Go peak hour).
A worker with harness opencode at tier LIGHT: opencode names opencode-go/deepseek-v4.1-flash (MG), openrouter
names deepseek/deepseek-v4-flash then M — M and MG are twins. The tables are the spec's, verbatim (the
header is the parameter list).
"""

from __future__ import annotations

import re

import pytest

from agent_gateway.tiers import same_model

from ._catalog_rows import CHAT, M, joined, verdict
from .conftest import (
    attach_json,
    bearer,
    given,
    open_session,
    quiet,
    rule,
    seed_openrouter_endpoints,
    when,
    world,
)

pytestmark = rule("GW-RAIL-CHOICE")
MG = "opencode-go/deepseek-v4.1-flash"
M2 = "deepseek/deepseek-v4-flash"
WORLD = "openrouter-endpoints + the Go catalog"
INELIGIBLE = ("open-inference/fp4", "alibaba", "parasail/fp8")
MESSAGES = "/anthropic/v1/messages"
NEAR_SHARE = "the Go window near its share"
LOW_RATE = "six judged Go rides on MG, one clean"
TRIMMED = "the snapshot trimmed to the ineligible endpoints"
ALL_CANDIDATE = "every cell of M candidate"
BOTH_HELD = f"{NEAR_SHARE}; {TRIMMED}; the task's earlier ride struck no-verdict on deepseek/deepseek-v4-flash"


# ── The twin rule ────────────────────────────────────────────────────────────────────────────
TWIN_ROWS = [
    pytest.param("opencode-go/deepseek-v4.1-flash", "deepseek/deepseek-v4.1-flash", "yes", id="a Go id and its openrouter spelling are twins ⚖"),
    pytest.param("opencode-go/claude-haiku-5-5", "anthropic/claude-haiku-5.5", "yes", id="the dotted and the dashed version are twins"),
    pytest.param("inclusionai/ling-3.0-flash:free", "inclusionai/ling-3.0-flash", "yes", id="a variant twins its family"),
    pytest.param("deepseek/deepseek-v4.1-flash", "other/deepseek-v4.1-flash", "no", id="two vendors' spellings are not twins ⚖"),
    pytest.param("opencode-go/glm-5.3", "z-ai/glm-5.3-flash", "no", id="a suffix is not a twin"),
    pytest.param("claude/haiku", "opencode-go/claude-haiku-5-5", "no", id="an alias twins nothing ⚖"),
    pytest.param("deepseek/deepseek-v4.1-flash", "deepseek/deepseek-v4.1-flash", "no", id="the same id is not a twin"),
]


@pytest.mark.parametrize(("a", "b", "expected_twins"), TWIN_ROWS, ids=[p.id for p in TWIN_ROWS])
def test_twins(a, b, expected_twins):
    world(note="two hand-written policy ids")
    with given(f"policy ids a = {a} · b = {b}"):
        attach_json("ids", [a, b])
    with when(f"same_model({a!r}, {b!r}) and the reverse"):
        got = (same_model(a, b), same_model(b, a))
    verdict(f"twins = {expected_twins}", expected_twins={"expected": expected_twins, "actual": "yes" if got == (True, True) else "no" if got == (False, False) else repr(got)},
            a={"actual": a}, b={"actual": b})


# ── The rail choice ──────────────────────────────────────────────────────────────────────────
async def _go_ride(gw, upstreams, usage: dict, tier: str = "light", task: str = "homelab-2743-draw") -> dict:
    """One worker ride on opencode (the request rides the anthropic dialect — the vendor's usage shape)."""
    with quiet():
        doc = await open_session(gw, role="worker", rail="opencode", tier=tier, task=task)
        up = upstreams["opencode"]
        up.usage = usage
        r = await gw.post(MESSAGES, headers=bearer(doc), json={"max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]})
        up.usage = None
    attach_json(f"arranged Go ride: {doc['model']} usage {usage} → {r.status_code}", {"session": doc["session"]["id"], "usage": usage, "status": r.status_code})
    return doc


def _seed(app, store, upstreams, only=None):
    body = seed_openrouter_endpoints(store, upstreams["openrouter"], only=only)
    app.state.providers.reload()
    return body


async def _arrange(gw, app, store, upstreams, arrange: str, task: str) -> None:
    """The `arrange` legend of the rail-choice table."""
    _seed(app, store, upstreams, only=INELIGIBLE if TRIMMED in arrange else None)
    if NEAR_SHARE in arrange:
        await _go_ride(gw, upstreams, {"input_tokens": 30_000_000, "output_tokens": 3_200_000})
    if arrange == LOW_RATE:
        with quiet():  # the six rides' per-ride summaries fold into the cell's one ride table (ATTACH_BULK)
            for i in range(6):
                doc = await _go_ride(gw, upstreams, {"input_tokens": 12, "output_tokens": 7}, task=f"homelab-2743-rate-{i}")
                await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": "clean" if i == 0 else "harness-gave-up"})
                await gw.delete(f"/sessions/{doc['session']['id']}")
        attach_json("the Go cell's rides", store.cell_outcomes("opencode", MG))
    if arrange == ALL_CANDIDATE:
        now = app.state.sessions.clock()
        for e in seed_openrouter_endpoints(store, upstreams["openrouter"])["models"][M]["endpoints"]:
            store.cell_set(M, e["slug"], "candidate", None, now, None)
        attach_json("cells", store.cells_count(now))
    if arrange == BOTH_HELD:
        with quiet():
            d = await open_session(gw, role="worker", harness="opencode", rail="openrouter", tier="standard", task=task)
            await gw.post(CHAT, json={"model": d["model"], "messages": []}, headers=bearer(d))
            await gw.post(f"/sessions/{d['session']['id']}/outcome", json={"class": "no-verdict"})
            await gw.delete(f"/sessions/{d['session']['id']}")
        attach_json("the task's strikes", [(s["class"], s["model"], s["scope"]) for s in store.strikes_for("platform", task)])


async def _choice_series(gw) -> str:
    with quiet():
        text = (await gw.get("/metrics")).text
    found = re.findall(r'^gateway_rail_choice_total\{model="([^"]*)",rail="([^"]*)",reason="([^"]*)"\} (\S+)$', text, re.M)
    return joined([f'rail="{rail}",reason="{reason}" {value.rstrip("0").rstrip(".") if "." in value else value}' for model, rail, reason, value in found if model == M])


def _choice_cell(doc: dict) -> str:
    if doc.get("decision") != "dispatch":
        return "none"
    c = doc.get("rail_choice")
    return "null" if c is None else f"{c['rail']} over {c['over']}: {c['reason']}"


CHOICE_ROWS = [
    pytest.param("nothing", "light", "dispatch", "opencode", "MG", "opencode over openrouter: price", 'rail="opencode",reason="price" 1',
                 id="Go wins with free headroom and an equal clean rate ⚖"),
    pytest.param(NEAR_SHARE, "light", "dispatch", "openrouter", "M", "openrouter over opencode: headroom", 'rail="openrouter",reason="headroom" 1',
                 id="openrouter wins when Go's window is near its share ⚖"),
    pytest.param(LOW_RATE, "light", "dispatch", "openrouter", "M", "openrouter over opencode: clean-rate", 'rail="openrouter",reason="clean-rate" 1',
                 id="openrouter wins when Go's clean rate is lower ⚖"),
    pytest.param(TRIMMED, "light", "dispatch", "opencode", "MG", "opencode over openrouter: no-eligible-endpoint", 'rail="opencode",reason="no-eligible-endpoint" 1',
                 id="no eligible openrouter endpoint: Go ⚖"),
    pytest.param(ALL_CANDIDATE, "light", "dispatch", "opencode", "MG", "opencode over openrouter: no-eligible-endpoint", 'rail="opencode",reason="no-eligible-endpoint" 1',
                 id="no openrouter cell has passed the entry canary yet: Go ⚖"),
    pytest.param(BOTH_HELD, "light", "defer", "none", "none", "none", "none",
                 id="both twins held: no choice, the walk defers with the hold that lifts first ⚖"),
    pytest.param("nothing", "standard", "dispatch", "opencode", "MG", "null", "none", id="no twin at the tier: the role's order, no choice"),
]


@pytest.mark.parametrize(("arrange", "tier", "expected_decision", "expected_rail", "expected_model", "expected_rail_choice", "expected_counted"), CHOICE_ROWS,
                         ids=[p.id for p in CHOICE_ROWS])
async def test_rail_choice(gw, app, store, upstreams, arrange, tier, expected_decision, expected_rail, expected_model, expected_rail_choice, expected_counted):
    world(upstream="upstream-ok", note=f"{WORLD}; {arrange}")
    task = "homelab-2743-choice"
    with given(f"arrange = {arrange}; Go's promise $0.075/M vs deepinfra's $0.42/M at the prior rate"):
        await _arrange(gw, app, store, upstreams, arrange, task)
    body = {"stack": "platform", "role": "worker", "harness": "opencode", "task": task, "tier": tier, **({"attempt": 2} if arrange == BOTH_HELD else {})}
    with when(f"POST /sessions body {body} (tier = {tier})"):
        r = await gw.post("/sessions", json=body)
    doc = r.json()
    short = {M: "M", MG: "MG"}
    verdict(f"decision = {expected_decision} · rail = {expected_rail} · model = {expected_model} · rail_choice = {expected_rail_choice} · counted = {expected_counted}",
            expected_decision={"expected": expected_decision, "actual": doc.get("decision")},
            expected_rail={"expected": expected_rail, "actual": doc.get("rail") or "none"},
            expected_model={"expected": expected_model, "actual": short.get(doc.get("model"), doc.get("model") or "none")},
            expected_rail_choice={"expected": expected_rail_choice, "actual": _choice_cell(doc)},
            expected_counted={"expected": expected_counted, "actual": await _choice_series(gw)},
            status={"expected": 200, "actual": r.status_code},
            defer={"expected": {"reason": "no-eligible-provider", "retry_after_s": 60} if expected_decision == "defer" else {"reason": None, "retry_after_s": None},
                   "actual": {k: doc.get(k) for k in ("reason", "retry_after_s")}},
            arrange={"actual": arrange}, tier={"actual": tier})


# ── A preference for the strongest: no choice ───────────────────────────────────────────────
PREFER_ROWS = [
    pytest.param(NEAR_SHARE, "light", "(policy)", "dispatch", "openrouter", "M", "openrouter over opencode: headroom", 'rail="openrouter",reason="headroom" 1',
                 id="no preference: the twin's cheaper rail is chosen"),
    pytest.param(NEAR_SHARE, "light", "strongest", "dispatch", "openrouter", "M", "null", "none",
                 id="strongest makes no rail choice: the role's order, each list from its end ⚖"),
    pytest.param("nothing", "light", "strongest", "dispatch", "opencode", "MG", "null", "none",
                 id="strongest with both twins free: the role's first rail, uncounted ⚖"),
]


@pytest.mark.parametrize(("arrange", "tier", "prefer", "expected_decision", "expected_rail", "expected_model", "expected_rail_choice", "expected_counted"),
                         PREFER_ROWS, ids=[p.id for p in PREFER_ROWS])
async def test_a_preference_for_the_strongest(gw, app, store, upstreams, arrange, tier, prefer, expected_decision, expected_rail, expected_model,
                                              expected_rail_choice, expected_counted):
    world(upstream="upstream-ok", note=f"{WORLD}; {arrange}")
    task = "homelab-2743-choice"
    with given(f"arrange = {arrange}; Go's promise $0.075/M vs deepinfra's $0.42/M at the prior rate"):
        await _arrange(gw, app, store, upstreams, arrange, task)
    body = {"stack": "platform", "role": "worker", "harness": "opencode", "task": task, "tier": tier, **({} if prefer == "(policy)" else {"prefer": prefer})}
    with when(f"POST /sessions body {body} (tier = {tier} · prefer = {prefer})"):
        r = await gw.post("/sessions", json=body)
    doc = r.json()
    short = {M: "M", MG: "MG"}
    verdict(f"decision = {expected_decision} · rail = {expected_rail} · model = {expected_model} · rail_choice = {expected_rail_choice} · counted = {expected_counted}",
            expected_decision={"expected": expected_decision, "actual": doc.get("decision")},
            expected_rail={"expected": expected_rail, "actual": doc.get("rail") or "none"},
            expected_model={"expected": expected_model, "actual": short.get(doc.get("model"), doc.get("model") or "none")},
            expected_rail_choice={"expected": expected_rail_choice, "actual": _choice_cell(doc)},
            expected_counted={"expected": expected_counted, "actual": await _choice_series(gw)},
            status={"expected": 200, "actual": r.status_code},
            arrange={"actual": arrange}, tier={"actual": tier}, prefer={"actual": prefer})


FAILOVER_ROWS = [
    pytest.param(f"{NEAR_SHARE}; the openrouter fake's deepinfra answers 500", "dispatch", "openrouter", "openrouter over opencode: headroom",
                 "deepinfra 500, atlas-cloud 200", "atlas-cloud 1 / 1, deepinfra 0 / 0",
                 id="the choice survives a failover: the ride's rows name the serving provider, its outcome judges that cell ⚖"),
]


@pytest.mark.parametrize(("arrange", "expected_decision", "expected_rail", "expected_rail_choice", "expected_request_rows", "expected_rides"), FAILOVER_ROWS,
                         ids=[p.id for p in FAILOVER_ROWS])
async def test_choice_survives_failover(gw, app, store, upstreams, arrange, expected_decision, expected_rail, expected_rail_choice, expected_request_rows,
                                        expected_rides):
    world(upstream="upstream-ok", note=f"{WORLD}; the Go window full; deepinfra answers 500")
    with given(f"arrange = {arrange}"):
        _seed(app, store, upstreams)
        await _go_ride(gw, upstreams, {"input_tokens": 30_000_000, "output_tokens": 3_200_000})
        upstreams["openrouter"].provider_behaviours["deepinfra"] = "upstream-500"
    body = {"tier": "light"}
    with when(f"POST /sessions body {body}, then one ride (deepinfra 500 → atlas-cloud 200) and outcome clean"):
        r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "harness": "opencode", "task": "homelab-2743-choice", **body})
        doc = r.json()
        assert doc.get("decision") == "dispatch", doc
        rr = await gw.post(CHAT, json={"model": M, "messages": []}, headers=bearer(doc))
        o = await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": "clean"})
        with quiet():
            v = (await gw.get("/catalog/openrouter")).json()
    rows = [(x["provider"], x["status"]) for x in store.requests_for(doc["session"]["id"])]
    rides = {e["slug"]: e["rides"] for e in v["models"][M]["endpoints"] if e["service_tier"] is None}
    verdict(f"decision = {expected_decision} · rail = {expected_rail} · rail_choice = {expected_rail_choice} · request_rows = {expected_request_rows} · rides = {expected_rides}",
            expected_decision={"expected": expected_decision, "actual": doc.get("decision")},
            expected_rail={"expected": expected_rail, "actual": doc.get("rail")},
            expected_rail_choice={"expected": expected_rail_choice, "actual": _choice_cell(doc)},
            expected_request_rows={"expected": expected_request_rows, "actual": ", ".join(f"{p} {s}" for p, s in rows)},
            expected_rides={"expected": expected_rides, "actual": ", ".join(f"{p} {rides[p]['clean']} / {rides[p]['judged']}" for p in ("atlas-cloud", "deepinfra"))},
            statuses={"expected": (200, 200, 200), "actual": (r.status_code, rr.status_code, o.status_code)},
            model={"expected": M, "actual": doc.get("model")}, arrange={"actual": arrange})
