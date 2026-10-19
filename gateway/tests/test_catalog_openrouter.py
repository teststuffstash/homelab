"""GW-CATALOG-OR — the OpenRouter rail's registry and its entry canary (specs/endpoints/catalog.md; homelab#2742).

World `policy-default · openrouter-catalog`: the fake MCP (tests/_orcatalog_world.py) answers the two
ranking slices and the AA benchmarks from tests/fixtures/openrouter-catalog/ (the live MCP answers of
2026-10-19, trimmed), the openrouter rail's fake serves `/v1/models/<id>/endpoints` for
deepseek/deepseek-v4.1-flash and z-ai/glm-5.3-flash (404 for the other five candidates). The account
key is the fixture Secret agent-egress/router-account-key. T0 = the test clock. M = deepseek/deepseek-v4.1-flash.

The refresh:

| description | the fakes answer | last good || outcome | models | cells (candidate) |
|---|---|---||---|---|---|
| a first refresh: ranked ∩ benched, then the endpoints per candidate | mcp ok, endpoints ok | none || ok | 2 (M, z-ai/glm-5.3-flash) of 7 candidates — 13 ranked, 7 benched, 5 unreadable | 15 |
| a dated permaslug joins its id: two stamps of one model are one candidate | the rankings carry M-20260910 and M-20261017 | — || ok | M once, its stamps' tokens summed per slice | — |
| the MCP answers an error: fetch-failed, the last good kept | mcp 503 | 2 || fetch-failed | 2 | 15 |
| the MCP is unreachable: fetch-failed | mcp down | 2 || fetch-failed | 2 | — |
| a tool result that is not JSON is a parse failure | mcp malformed | 2 || parse-failed | 2 | — |
| rankings without dates are a parse failure | rankings-undated | 2 || parse-failed | 2 | — |
| no benched candidate: implausible, nothing taken | benchmarks-empty | none || implausible | 0 | 0 |
| a candidate whose endpoints read fails is absent; the refresh still lands | endpoints-503 for glm | none || ok | 1 (M) — 6 unreadable | 8 |
| every endpoints read failing keeps the last good | endpoints-503 for both | 2 || implausible | 2 | — |
| no account key: fetch-failed, no MCP call | the ref absent | none || fetch-failed | 0 (0 MCP calls) | — |
| the MCP calls carry the account key and a client identity | mcp ok | — || — | authorization Bearer <the account key>; user-agent agent-gateway/<v> (openrouter-catalog); initialize then tools/call ×3 | — |
| a PVC store keeps the snapshot and the cells across a restart | refresh, a new gateway on the same DB, +3600 s | — || — | age_s 3600; 2 models; 15 candidate cells | — |

The entry canary (a canary = `POST /sessions` with `canary: {model, provider}`, the policy's canary role prober):

| description | arrange | body || decision | rail / model / harness | reason | retry_after_s | the cell after |
|---|---|---||---|---|---|---|---|
| a new cell is a candidate: selection does not pin it | refresh | worker ride on M (tier heavy) || dispatch | the upstream body carries no `provider` | — | — | candidate |
| a canary session is admitted on a candidate cell, pinned to it | refresh | prober, canary {M, deepinfra} || dispatch | openrouter / M / opencode | — | — | the ride's upstream body pins deepinfra, allow_fallbacks false; the row's canary_provider = deepinfra |
| a clean canary makes the cell eligible: selection pins it | the canary ride 200, outcome clean | worker ride on M || — | pinned deepinfra | — | — | eligible |
| a struck canary excludes exactly its cell | the canary ride answered upstream-500 | — || — | — | — | — | (M, deepinfra) excluded (provider-5xx) until T0 + 86400; (M, atlas-cloud) still candidate |
| an excluded cell is a candidate again after the cooldown | the same, +86400 s | prober, canary {M, deepinfra} || dispatch | openrouter / M | — | — | — |
| a canary on an eligible cell is not due | (M, deepinfra) eligible | prober, canary {M, deepinfra} || defer | — | canary-not-due | 21600 (the next refresh) | — |
| a canary on an excluded cell inside its cooldown is not due | (M, deepinfra) excluded at T0, +3600 s | prober, canary {M, deepinfra} || defer | — | canary-not-due | 82800 | — |
| a canary on a cell the snapshot lacks | refresh | prober, canary {M, fireworks} || defer | — | not-in-catalog | 21600 | — |
| a canary names a model the snapshot lacks | refresh | prober, canary {moonshotai/kimi-k3, deepinfra} || defer | — | not-in-catalog | 21600 | — |
| the canary role is the policy's | refresh | worker, canary {M, deepinfra} || 400 | — | malformed-body | — | — |
| a canary never fails over | the canary ride answered upstream-500 | — || 500 | the upstream calls: deepinfra only | — | — | — |

The budget (policy: max_per_refresh 3, usd_per_day 1.0, cooldown_s 86400):

| description | arrange | body || decision | reason | retry_after_s | `gateway_canary_budget_exhausted` |
|---|---|---||---|---|---|---|
| under budget: N entrants are canaried | refresh | 3 canaries on three cells || dispatch ×3 | — | — | 0 |
| at the cap the N+1th waits | 3 admitted this refresh | a 4th canary || defer | canary-budget | 3600 | 1 |
| a refresh opens the next N | 3 admitted, then a refresh | a 4th canary || dispatch | — | — | 0 |
| the day's spend at the cap defers | one canary ride metered $1.12 (in 5M, out 1M at deepinfra 0.14/0.42) | the next canary || defer | canary-budget | 3600 | 1 |
| the day rolls over | the same, +86400 s | the next canary || dispatch | — | — | 0 |
| spend is metered at the cell's endpoint price | the same ride || — | — | `gateway_canary_spend_usd` 1.12 | — |

| description | event || series | value |
|---|---||---|---|
| age is seconds since the last good refresh | refresh at T0, read at T0 + 600 s || gateway_openrouter_catalog_age_seconds | 600 |
| the model count of the last good snapshot | refresh || gateway_openrouter_catalog_models | 2 |
| every refresh is counted by outcome | refresh ok, then mcp 503 || gateway_openrouter_catalog_refresh_total{outcome="ok"} / {outcome="fetch-failed"} | 1 / 1 |
| the last outcome is 1, the others 0 | the same || gateway_openrouter_catalog_last_outcome{outcome="fetch-failed"} / {outcome="ok"} | 1 / 0 |
| cells are counted by state | refresh, one clean canary on (M, deepinfra), one struck on (M, atlas-cloud) || gateway_openrouter_cells{state="candidate"} / eligible / excluded | 13 / 1 / 1 |
| canary verdicts are counted | the same || gateway_canary_rides_total{outcome="eligible"} / {outcome="excluded"} | 1 / 1 |
| the view's shape is the schema's | refresh, GET /catalog/openrouter || exactly the schema's required keys | — |
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from .conftest import attach_json, bearer, check, given, open_session, quiet, rule, then, then_eq, when, world

pytestmark = rule("GW-CATALOG-OR")
M = "deepseek/deepseek-v4.1-flash"
G = "z-ai/glm-5.3-flash"
RAIL = "openrouter"
WORLD = "openrouter-catalog"
PATH = "/openai/v1/chat/completions"
SCHEMA = json.loads((Path(__file__).resolve().parents[1] / "specs" / "endpoints" / "catalog.schema.json").read_text(encoding="utf-8"))
T0 = 1_800_000_000


async def _refresh(app, label: str = "") -> str:
    with when(f"the catalog refreshes{label}"):
        return await app.state.orcatalog.refresh()


async def _view(gw) -> dict:
    r = await gw.get("/catalog/openrouter")
    assert r.status_code == 200, r.text
    return r.json()


def _cells(v: dict) -> dict[str, int]:
    return v["cells"]


def _states(store, model: str) -> dict[str, str]:
    return {p: r["state"] for p, r in store.cell_states(model).items()}


async def _series(gw, name: str) -> float | None:
    import re

    with quiet():
        text = (await gw.get("/metrics")).text
    m = re.search("^" + re.escape(name) + r" (\S+)$", text, re.M)
    attach_json(f"sample: {name}", {"line": m.group(0) if m else None})
    return float(m.group(1)) if m else None


async def _canary(gw, model: str, provider: str, label: str = "", **extra):
    body = {"stack": "platform", "role": "prober", "task": f"canary-{model}-{provider}", "canary": {"model": model, "provider": provider}, **extra}
    with when(f"POST /sessions {body}{label}"):
        return await gw.post("/sessions", json=body)


def _verdict(doc: dict, expected: dict) -> None:
    claim = "expected " + ", ".join(f"{k} = {v}" for k, v in expected.items())
    with then(claim, **{k: {"expected": v, "actual": doc.get(k)} for k, v in expected.items()}):
        assert {k: doc.get(k) for k in expected} == expected, f"{claim}: got {doc}"


# -- the refresh -------------------------------------------------------------------------------------
async def test_first_refresh(gw, app, store, mcp):
    """row: a first refresh: ranked ∩ benched, then the endpoints per candidate"""
    world(note=WORLD)
    outcome = await _refresh(app)
    then_eq("outcome", outcome, "ok")
    v = await _view(gw)
    then_eq("models in the snapshot", sorted(v["models"]), [M, G])
    then_eq("sources: (ranked, benched, candidates, unreadable)",
            (v["sources"]["ranking"]["ranked"], v["sources"]["benchmarks"]["rows"], v["sources"]["candidates"], v["endpoint_failures"]), (13, 7, 7, 5))
    then_eq("cells", _cells(v), {"candidate": 15, "eligible": 0, "excluded": 0})


async def test_permaslug_joins_id(gw, app, mcp):
    """row: a dated permaslug joins its id: two stamps of one model are one candidate"""
    world(note=f"{WORLD}; the programming slice carries {M}-20260910 and {M}-20261017")
    await _refresh(app)
    v = await _view(gw)
    stamps = [r["model_permaslug"] for r in json.loads((Path(__file__).resolve().parent / "fixtures" / "openrouter-catalog" / "rankings-programming.json").read_text())["data"]
              if r["model_permaslug"].startswith(M)]
    then_eq("the fixture's stamps of M", sorted(set(stamps)), [f"{M}-20260910", f"{M}-20261017"])
    then_eq("M in the snapshot once, its stamps' tokens summed per slice", (M in v["models"], v["models"][M]["ranking"]),
            (True, {"programming": 8550881819200 + 1354041462400, "tool_calling": 32832415061947 + 3723484472816}))


FAIL_ROWS = [
    ("the MCP answers an error: fetch-failed, the last good kept", "503", None, "fetch-failed", 2),
    ("the MCP is unreachable: fetch-failed", "down", None, "fetch-failed", 2),
    ("a tool result that is not JSON is a parse failure", "malformed", None, "parse-failed", 2),
    ("rankings without dates are a parse failure", "rankings-undated", None, "parse-failed", 2),
    ("every endpoints read failing keeps the last good", "ok", {M: "endpoints-503", G: "endpoints-503"}, "implausible", 2),
]


@pytest.mark.parametrize(("mcp_behaviour", "endpoints", "outcome", "models"), [r[1:] for r in FAIL_ROWS], ids=[r[0] for r in FAIL_ROWS])
async def test_refresh_keeps_last_good(gw, app, mcp, mcp_transport, upstreams, mcp_behaviour, endpoints, outcome, models):
    world(note=f"{WORLD}; mcp {mcp_behaviour}, endpoints {endpoints or 'ok'}")
    with given("a first good refresh (2 models)"):
        with quiet():
            assert await app.state.orcatalog.refresh() == "ok"
    if mcp_behaviour == "down":
        mcp_transport.down = True
    else:
        mcp.mcp = mcp_behaviour
    upstreams[RAIL].endpoints_behaviour.update(endpoints or {})
    got = await _refresh(app, " again")
    then_eq("outcome", got, outcome)
    then_eq("models (the last good)", len((await _view(gw))["models"]), models)


async def test_no_benched_candidate(gw, app, mcp):
    """row: no benched candidate: implausible, nothing taken"""
    world(note=f"{WORLD}; benchmarks-empty")
    mcp.mcp = "benchmarks-empty"
    outcome = await _refresh(app)
    then_eq("outcome", outcome, "implausible")
    v = await _view(gw)
    then_eq("models · cells", (len(v["models"]), _cells(v)["candidate"]), (0, 0))


async def test_unreadable_candidate_absent(gw, app, upstreams):
    """row: a candidate whose endpoints read fails is absent; the refresh still lands"""
    world(note=f"{WORLD}; endpoints-503 for {G}")
    upstreams[RAIL].endpoints_behaviour[G] = "endpoints-503"
    outcome = await _refresh(app)
    then_eq("outcome", outcome, "ok")
    v = await _view(gw)
    then_eq("models · unreadable · candidate cells", (sorted(v["models"]), v["endpoint_failures"], _cells(v)["candidate"]), ([M], 6, 8))


async def test_no_account_key(gw, app, mcp, secrets):
    """row: no account key: fetch-failed, no MCP call"""
    world(note=f"{WORLD}; the account-key Secret absent")
    del secrets.secrets["agent-egress/router-account-key"]
    outcome = await _refresh(app)
    then_eq("outcome · MCP calls", (outcome, len(mcp.calls)), ("fetch-failed", 0))


async def test_mcp_identity(gw, app, mcp):
    """row: the MCP calls carry the account key and a client identity"""
    world(note=WORLD)
    await _refresh(app)
    from agent_gateway import __version__

    calls = mcp.calls
    then_eq("the calls, in order", [c["method"] + (":" + c["params"]["name"] if c["method"] == "tools/call" else "") for c in calls],
            ["initialize", "tools/call:list-daily-model-rankings", "initialize", "tools/call:list-daily-model-rankings", "initialize", "tools/call:list-benchmarks"])
    then_eq("every call's authorization · user-agent", {(c["headers"]["authorization"], c["headers"]["user-agent"]) for c in calls},
            {("Bearer sk-or-v1-test-account-key", f"agent-gateway/{__version__} (openrouter-catalog)")})
    then_eq("the ranking arguments", [c["params"]["arguments"] for c in calls if c["method"] == "tools/call" and c["params"]["name"] == "list-daily-model-rankings"],
            [{"request": {"period": "week", "category": "programming"}}, {"request": {"period": "week", "modality": "tool_calling"}}])


async def test_pvc_keeps_snapshot(gw, app, clock, settings, policy, secrets, mcp_transport, reviews, pods):
    """row: a PVC store keeps the snapshot and the cells across a restart"""
    world(note=f"{WORLD}; a second gateway on the same DB")
    await _refresh(app)
    clock.advance(3600)
    import httpx

    from agent_gateway.app import create_app
    from agent_gateway.store import Store

    from .conftest import ObservedAsyncClient

    with given("a new gateway built on the same DB path, +3600 s, no refresh"):
        client = httpx.AsyncClient(transport=mcp_transport)
        second = create_app(settings, policy=policy, source=secrets, store=Store(settings.db_path), client=client, clock=clock, reviewer=reviews, pods=pods)
    async with ObservedAsyncClient(transport=httpx.ASGITransport(app=second), base_url="http://gw2") as c:
        with when("GET /catalog/openrouter on the second gateway"):
            v = (await c.get("/catalog/openrouter")).json()
    await client.aclose()
    then_eq("age_s · models · candidate cells", (v["age_s"], len(v["models"]), _cells(v)["candidate"]), (3600.0, 2, 15))


# -- the entry canary --------------------------------------------------------------------------------
async def test_new_cell_not_pinned(gw, app, upstreams):
    """row: a new cell is a candidate: selection does not pin it"""
    world(upstream="upstream-ok", note=WORLD)
    await _refresh(app)
    with given("a worker session on rail openrouter, tier heavy (M)"):
        doc = await open_session(gw, role="worker", harness="opencode", rail=RAIL, tier="heavy")
    with when("POST /openai/v1/chat/completions"):
        r = await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 200)
    then_eq("the upstream body's provider key", (upstreams[RAIL].calls[-1]["body"] or {}).get("provider"), None)


async def test_canary_admitted(gw, app, store, upstreams):
    """row: a canary session is admitted on a candidate cell, pinned to it"""
    world(upstream="upstream-ok", note=WORLD)
    await _refresh(app)
    r = await _canary(gw, M, "deepinfra")
    then_eq("status", r.status_code, 200)
    doc = r.json()
    _verdict(doc, {"decision": "dispatch", "rail": RAIL, "model": M, "harness": "opencode"})
    with when("the canary's ride: POST /openai/v1/chat/completions"):
        rr = await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(doc))
    then_eq("status", rr.status_code, 200)
    then_eq("the upstream body's provider block", (upstreams[RAIL].calls[-1]["body"] or {}).get("provider"), {"order": ["deepinfra"], "allow_fallbacks": False})
    then_eq("the session row's canary_provider", store.get_session(doc["session"]["id"]).canary_provider, "deepinfra")


async def _canary_ride(gw, app, upstreams, provider: str = "deepinfra", behaviour: str = "upstream-ok", outcome: str | None = "clean") -> dict:
    with quiet():
        r = await gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": f"canary-{provider}", "canary": {"model": M, "provider": provider}})
        assert r.json()["decision"] == "dispatch", r.text
        doc = r.json()
        upstreams[RAIL].provider_behaviours[provider] = behaviour
        rr = await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(doc))
        upstreams[RAIL].provider_behaviours.pop(provider, None)
        if outcome:
            await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": outcome})
    attach_json(f"canary ride on ({M}, {provider})", {"session": doc["session"]["id"], "upstream": behaviour, "status": rr.status_code, "outcome": outcome})
    return doc


async def test_clean_canary_eligible(gw, app, store, upstreams):
    """row: a clean canary makes the cell eligible: selection pins it"""
    world(upstream="upstream-ok", note=WORLD)
    await _refresh(app)
    with given("a canary ride on (M, deepinfra): 200, outcome clean"):
        await _canary_ride(gw, app, upstreams)
    then_eq("the cell", _states(store, M)["deepinfra"], "eligible")
    with given("a worker session on rail openrouter, tier heavy (M)"):
        doc = await open_session(gw, role="worker", harness="opencode", rail=RAIL, tier="heavy")
    with when("POST /openai/v1/chat/completions"):
        r = await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(doc))
    then_eq("status · the pin", (r.status_code, ((upstreams[RAIL].calls[-1]["body"] or {}).get("provider") or {}).get("order")), (200, ["deepinfra"]))


async def test_struck_canary_excluded(gw, app, store, upstreams):
    """row: a struck canary excludes exactly its cell"""
    world(upstream="upstream-500", note=f"{WORLD}; deepinfra answers 500 to the canary")
    await _refresh(app)
    with given("a canary ride on (M, deepinfra) answered upstream-500 (the gateway's provider-5xx), no consumer outcome"):
        await _canary_ride(gw, app, upstreams, behaviour="upstream-500", outcome=None)
    row = store.cell_get(M, "deepinfra")
    then_eq("(M, deepinfra): (state, class, cooldown_until)", (row["state"], row["class"], row["cooldown_until"]), ("excluded", "provider-5xx", T0 + 86400))
    then_eq("(M, atlas-cloud)", _states(store, M)["atlas-cloud"], "candidate")


async def test_excluded_cell_returns(gw, app, store, upstreams, clock):
    """row: an excluded cell is a candidate again after the cooldown"""
    world(upstream="upstream-500", note=f"{WORLD}; the exclusion's cooldown_s 86400 passes")
    await _refresh(app)
    with given("(M, deepinfra) excluded at T0 by a struck canary"):
        await _canary_ride(gw, app, upstreams, behaviour="upstream-500", outcome=None)
    clock.advance(86400)
    r = await _canary(gw, M, "deepinfra", " (+86400 s)")
    _verdict(r.json(), {"decision": "dispatch", "rail": RAIL, "model": M})


async def test_canary_on_eligible_not_due(gw, app, store, upstreams):
    """row: a canary on an eligible cell is not due"""
    world(upstream="upstream-ok", note=WORLD)
    await _refresh(app)
    with given("(M, deepinfra) eligible (a clean canary)"):
        await _canary_ride(gw, app, upstreams)
    r = await _canary(gw, M, "deepinfra")
    _verdict(r.json(), {"decision": "defer", "reason": "canary-not-due", "retry_after_s": 21600})


async def test_canary_on_excluded_not_due(gw, app, store, upstreams, clock):
    """row: a canary on an excluded cell inside its cooldown is not due"""
    world(upstream="upstream-500", note=WORLD)
    await _refresh(app)
    with given("(M, deepinfra) excluded at T0"):
        await _canary_ride(gw, app, upstreams, behaviour="upstream-500", outcome=None)
    clock.advance(3600)
    r = await _canary(gw, M, "deepinfra", " (+3600 s)")
    _verdict(r.json(), {"decision": "defer", "reason": "canary-not-due", "retry_after_s": 82800})


NOT_IN_CATALOG_ROWS = [
    ("a canary on a cell the snapshot lacks", M, "fireworks"),
    ("a canary names a model the snapshot lacks", "moonshotai/kimi-k3", "deepinfra"),
]


@pytest.mark.parametrize(("model", "provider"), [r[1:] for r in NOT_IN_CATALOG_ROWS], ids=[r[0] for r in NOT_IN_CATALOG_ROWS])
async def test_canary_not_in_catalog(gw, app, model, provider):
    world(note=WORLD)
    await _refresh(app)
    r = await _canary(gw, model, provider)
    _verdict(r.json(), {"decision": "defer", "reason": "not-in-catalog", "retry_after_s": 21600})


async def test_canary_role(gw, app):
    """row: the canary role is the policy's"""
    world(note=WORLD)
    await _refresh(app)
    r = await _canary(gw, M, "deepinfra", role="worker")
    then_eq("status · code", (r.status_code, r.json()["error"]["code"]), (400, "malformed-body"))


async def test_canary_never_fails_over(gw, app, upstreams):
    """row: a canary never fails over"""
    world(upstream="upstream-500", note=f"{WORLD}; deepinfra answers 500")
    await _refresh(app)
    with given("a canary session on (M, deepinfra)"):
        with quiet():
            doc = (await gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "canary-nf", "canary": {"model": M, "provider": "deepinfra"}})).json()
    upstreams[RAIL].provider_behaviours["deepinfra"] = "upstream-500"
    with when("the canary's ride"):
        r = await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(doc))
    then_eq("status", r.status_code, 500)
    then_eq("the upstream calls (pins)", [((c["body"] or {}).get("provider") or {}).get("order", [None])[0] for c in upstreams[RAIL].calls if c["path"] == "/v1/chat/completions"], ["deepinfra"])


# -- the budget ----------------------------------------------------------------------------------------
async def test_budget_under(gw, app, store):
    """row: under budget: N entrants are canaried"""
    world(note=WORLD)
    await _refresh(app)
    out = []
    for i, p in enumerate(("deepinfra", "atlas-cloud", "morph")):
        out.append((await _canary(gw, M, p)).json()["decision"])
        if i == 1:
            then_eq("gateway_canary_budget_exhausted after two of three", await _series(gw, "gateway_canary_budget_exhausted"), 0)
    then_eq("three canary admissions", out, ["dispatch"] * 3)


async def test_budget_cap(gw, app, store):
    """row: at the cap the N+1th waits"""
    world(note=WORLD)
    await _refresh(app)
    with given("3 canaries admitted this refresh"):
        with quiet():
            for p in ("deepinfra", "atlas-cloud", "morph"):
                assert (await gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": f"c-{p}", "canary": {"model": M, "provider": p}})).json()["decision"] == "dispatch"
    r = await _canary(gw, M, "inference-net", " (the 4th)")
    _verdict(r.json(), {"decision": "defer", "reason": "canary-budget", "retry_after_s": 3600})
    then_eq("gateway_canary_budget_exhausted", await _series(gw, "gateway_canary_budget_exhausted"), 1)


async def test_budget_refresh_resets(gw, app, store, clock):
    """row: a refresh opens the next N"""
    world(note=WORLD)
    await _refresh(app)
    with given("3 canaries admitted this refresh"):
        with quiet():
            for p in ("deepinfra", "atlas-cloud", "morph"):
                assert (await gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": f"c-{p}", "canary": {"model": M, "provider": p}})).json()["decision"] == "dispatch"
    clock.advance(1)
    await _refresh(app, " again")
    r = await _canary(gw, M, "inference-net", " (the 4th, after the refresh)")
    _verdict(r.json(), {"decision": "dispatch", "rail": RAIL, "model": M})
    then_eq("gateway_canary_budget_exhausted", await _series(gw, "gateway_canary_budget_exhausted"), 0)


async def _spend_ride(gw, app, upstreams) -> dict:
    """One canary ride on (M, deepinfra) with the claude harness (the anthropic dialect's usage knob): in 5M, out 1M
    at deepinfra 0.14 / 0.42 $/M = $0.70 + $0.42 = $1.12."""
    with quiet():
        doc = (await gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "canary-spend", "harness": "claude",
                                                "canary": {"model": M, "provider": "deepinfra"}})).json()
        assert doc["decision"] == "dispatch", doc
        upstreams[RAIL].behaviour, upstreams[RAIL].usage = "upstream-ok-usage", {"input_tokens": 5_000_000, "output_tokens": 1_000_000}
        rr = await gw.post("/anthropic/v1/messages", json={"model": M, "max_tokens": 8, "messages": []}, headers={"x-api-key": doc["session"]["token"]})
        upstreams[RAIL].behaviour, upstreams[RAIL].usage = "upstream-ok", None
    attach_json("the metered canary ride", {"status": rr.status_code, "usage": {"in": 5_000_000, "out": 1_000_000}, "price": "deepinfra 0.14 / 0.42"})
    return doc


async def test_budget_spend_cap(gw, app, upstreams):
    """row: the day's spend at the cap defers"""
    world(upstream="upstream-ok-usage", note=f"{WORLD}; usd_per_day 1.0")
    await _refresh(app)
    with given("one canary ride metered $1.12"):
        await _spend_ride(gw, app, upstreams)
    r = await _canary(gw, M, "atlas-cloud", " (the next)")
    _verdict(r.json(), {"decision": "defer", "reason": "canary-budget", "retry_after_s": 3600})
    then_eq("gateway_canary_budget_exhausted", await _series(gw, "gateway_canary_budget_exhausted"), 1)


async def test_budget_day_rolls(gw, app, upstreams, clock):
    """row: the day rolls over"""
    world(upstream="upstream-ok-usage", note=WORLD)
    await _refresh(app)
    with given("one canary ride metered $1.12"):
        await _spend_ride(gw, app, upstreams)
    clock.advance(86400)
    r = await _canary(gw, M, "atlas-cloud", " (+86400 s)")
    _verdict(r.json(), {"decision": "dispatch", "rail": RAIL, "model": M})
    then_eq("gateway_canary_budget_exhausted", await _series(gw, "gateway_canary_budget_exhausted"), 0)


async def test_spend_metered(gw, app, upstreams):
    """row: spend is metered at the cell's endpoint price"""
    world(upstream="upstream-ok-usage", note=WORLD)
    await _refresh(app)
    with given("one canary ride: in 5M, out 1M on deepinfra (0.14 / 0.42 $/M)"):
        await _spend_ride(gw, app, upstreams)
    then_eq("gateway_canary_spend_usd", await _series(gw, "gateway_canary_spend_usd"), 1.12)
    then_eq("the view's canary.spend_usd_1d", (await _view(gw))["canary"]["spend_usd_1d"], 1.12)


# -- metrics + the view ------------------------------------------------------------------------------
async def test_age(gw, app, clock):
    """row: age is seconds since the last good refresh"""
    world(note=WORLD)
    await _refresh(app)
    clock.advance(600)
    then_eq("gateway_openrouter_catalog_age_seconds", await _series(gw, "gateway_openrouter_catalog_age_seconds"), 600)


async def test_models_gauge(gw, app):
    """row: the model count of the last good snapshot"""
    world(note=WORLD)
    await _refresh(app)
    then_eq("gateway_openrouter_catalog_models", await _series(gw, "gateway_openrouter_catalog_models"), 2)


async def test_refresh_counted(gw, app, mcp):
    """row: every refresh is counted by outcome"""
    world(note=f"{WORLD}; then mcp 503")
    await _refresh(app)
    mcp.mcp = "503"
    await _refresh(app, " again")
    then_eq("refresh_total ok / fetch-failed", (await _series(gw, 'gateway_openrouter_catalog_refresh_total{outcome="ok"}'),
                                                 await _series(gw, 'gateway_openrouter_catalog_refresh_total{outcome="fetch-failed"}')), (1, 1))


async def test_last_outcome(gw, app, mcp):
    """row: the last outcome is 1, the others 0"""
    world(note=f"{WORLD}; then mcp 503")
    await _refresh(app)
    mcp.mcp = "503"
    await _refresh(app, " again")
    then_eq("last_outcome fetch-failed / ok", (await _series(gw, 'gateway_openrouter_catalog_last_outcome{outcome="fetch-failed"}'),
                                               await _series(gw, 'gateway_openrouter_catalog_last_outcome{outcome="ok"}')), (1, 0))


async def test_cells_counted(gw, app, upstreams):
    """row: cells are counted by state"""
    world(upstream="upstream-ok", note=WORLD)
    await _refresh(app)
    with given("one clean canary on (M, deepinfra), one struck on (M, atlas-cloud)"):
        await _canary_ride(gw, app, upstreams, "deepinfra")
        await _canary_ride(gw, app, upstreams, "atlas-cloud", behaviour="upstream-500", outcome=None)
    then_eq("gateway_openrouter_cells candidate / eligible / excluded",
            (await _series(gw, 'gateway_openrouter_cells{state="candidate"}'), await _series(gw, 'gateway_openrouter_cells{state="eligible"}'),
             await _series(gw, 'gateway_openrouter_cells{state="excluded"}')), (13, 1, 1))


async def test_canary_rides_counted(gw, app, upstreams):
    """row: canary verdicts are counted"""
    world(upstream="upstream-ok", note=WORLD)
    await _refresh(app)
    with given("one clean canary on (M, deepinfra), one struck on (M, atlas-cloud)"):
        await _canary_ride(gw, app, upstreams, "deepinfra")
        await _canary_ride(gw, app, upstreams, "atlas-cloud", behaviour="upstream-500", outcome=None)
    then_eq("gateway_canary_rides_total eligible / excluded",
            (await _series(gw, 'gateway_canary_rides_total{outcome="eligible"}'), await _series(gw, 'gateway_canary_rides_total{outcome="excluded"}')), (1, 1))


async def test_view_keys_are_the_schema(gw, app):
    """row: the view's shape is the schema's"""
    world(note=WORLD)
    await _refresh(app)
    with when("GET /catalog/openrouter"):
        v = await _view(gw)
    out = SCHEMA["openrouter_output"]
    row = out["properties"]["models"]["additionalProperties"]
    with then("the view's keys, each model row's and each endpoint row's are exactly the schema's required set"):
        check("view keys", sorted(v), sorted(out["required"]))
        check("model row keys", sorted({k for r in v["models"].values() for k in r}), sorted(row["required"]))
        check("endpoint row keys", sorted({k for r in v["models"].values() for e in r["endpoints"] for k in e}), sorted(row["properties"]["endpoints"]["items"]["required"]))
        check("canary keys", sorted(v["canary"]), sorted(out["properties"]["canary"]["required"]))

