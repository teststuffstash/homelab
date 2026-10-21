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
| an endpoint without an uptime figure does not fail its model's parse | endpoints-null-uptime for glm (its first endpoint's uptime_last_1d null) | none || ok | 2 (M, G) — 5 unreadable; G's row carries uptime_1d null | 15 |
| every endpoints read failing keeps the last good | endpoints-503 for both | 2 || implausible | 2 | — |
| no account key: fetch-failed, no MCP call | the ref absent | none || fetch-failed | 0 (0 MCP calls) | — |
| the MCP calls carry the account key and a client identity | mcp ok | — || — | authorization Bearer <the account key>; user-agent agent-gateway/<v> (openrouter-catalog); initialize then tools/call ×3 | — |
| a PVC store keeps the snapshot and the cells across a restart | refresh, a new gateway on the same DB, +3600 s | — || — | age_s 3600; 2 models; 15 candidate cells | — |
| a restart inside the interval refreshes nothing at start | refresh at T0, a new gateway on the same DB, +3600 s | 2 || — (the loop's first refresh waits 18000 s; last_attempt_at null; a not-in-catalog defer's retry_after_s 18000) | 2 | 15 |
| a restart after the interval refreshes at start | refresh at T0, a new gateway on the same DB, +21600 s | 2 || ok (the loop refreshes at once; fetched_at T0 + 21600 s) | 2 | 15 |

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
| a pod roll inside the window keeps the count | 3 admitted, then a new gateway on the same DB +3600 s (no refresh at start) | a 4th canary || defer | canary-budget | 3600 | 1 (admitted_this_refresh 3) |
| a pod roll after the interval refreshes and opens the next N | 3 admitted, then a new gateway on the same DB +21600 s, its refresh at start | a 4th canary || dispatch | — | — | 0 |
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

The floors' verdict on the view (homelab#2775 — operator ruling 2026-10-21, a bug: the view did not say which
cells selection could pin): `pinnable` per harness — the policy's `providers.tool_choice` keys, opencode /
goose / claude — and `floor`, the reason where it fails; `providers.eligible()`, the data plane's own predicate:

| description | cell | arrange || pinnable (opencode / goose / claude) | floor |
|---|---|---||---|---|
| the view says which cells selection could pin: a cell without required/function is pinnable for opencode and goose, not claude | M@morph (fp8, uptime 99.5, tool_choice auto only) | refresh || true / true / false | {claude: no tool_choice required,function} |
| the 2026-10-20 cell: fp4 is pinnable for no harness | M@open-inference (fp4) | refresh || false / false / false | {opencode, goose, claude: quantization fp4 < fp8} |
| a cell clearing every floor is pinnable everywhere; its service tiers carry the representative's verdict | M@deepinfra (fp8; /flex uptime 84.5 and /priority beside it) | refresh || true / true / true on all three rows | {} |
| a null uptime clears no floor on any harness | M@inference-net, endpoints-null-uptime@inference-net/fp8 | refresh || false / false / false | {opencode, goose, claude: uptime_1d unknown} |
| the flag follows the policy, not the data | M@open-inference | a second gateway on the same DB, policy-default with quantization_floor fp4 || true / true / true | {} |
| selected is always a pinnable cell: the cheaper eligible fp4 cell is passed over | M | clean canaries on (M, open-inference) 0.08 and (M, deepinfra) 0.42 || selected deepinfra; open-inference eligible, pinnable false | — |

The launcher (`scripts/canary-entrants.sh --dry-run < /dev/null`, a fake HTTP server handing it the view):

| description | the view || the walk (`== canary n/N: <cell>`, cheapest first) | the banner's skipped list |
|---|---||---|---|
| the launcher walks pinnable candidate cells cheapest-first; the skipped cells and their floor are in the banner | after a refresh: 15 candidate cells, 9 pinnable for opencode || M@deepinfra 0.42, G@near-ai 0.50, G@z-ai 0.50, M@atlas-cloud 0.54, M@morph 0.60, G@morph 0.65, G@inceptron 0.69, M@inference-net 0.715, M@baidu 1.20 — no ride (two GETs of the view, nothing else) | G@atlas-cloud (uptime_1d 77.8199 < 95), G@open-inference (quantization fp4 < fp8), G@reka (quantization unknown), M@alibaba (quantization unknown), M@open-inference (quantization fp4 < fp8), M@parasail (uptime_1d 77.4359 < 95) |
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from agent_gateway.store import iso

from .conftest import (
    POLICY_FIXTURE,
    attach_json,
    bearer,
    check,
    given,
    open_session,
    quiet,
    rule,
    then,
    then_eq,
    when,
    world,
)

pytestmark = rule("GW-CATALOG-OR")
M = "deepseek/deepseek-v4.1-flash"
G = "z-ai/glm-5.3-flash"
RAIL = "openrouter"
WORLD = "openrouter-catalog"
PATH = "/openai/v1/chat/completions"
ISLAND = Path(__file__).resolve().parents[1]
SCHEMA = json.loads((ISLAND / "specs" / "endpoints" / "catalog.schema.json").read_text(encoding="utf-8"))
LAUNCHER = ISLAND / "scripts" / "canary-entrants.sh"
HARNESSES = ("opencode", "goose", "claude")  # the fixture policy's providers.tool_choice keys, in its order
T0 = 1_800_000_000


async def _refresh(app, label: str = "") -> str:
    with when(f"the catalog refreshes{label}"):
        with quiet():  # the MCP + endpoints exchanges fold into one attachment (ATTACH_BULK)
            outcome = await app.state.orcatalog.refresh()
        attach_json("the refresh", {"outcome": outcome, "sources": app.state.orcatalog.sources,
                                    "endpoint_failures": app.state.orcatalog.endpoint_failures})
        return outcome


async def _refreshed(app, label: str = "a first good refresh (M and G, 15 candidate cells)") -> None:
    """The refresh as ARRANGE (one given step, exchanges muted) — for the rows whose call under test is the view."""
    with given(label):
        with quiet():
            assert await app.state.orcatalog.refresh() == "ok"


async def _view(gw) -> dict:
    r = await gw.get("/catalog/openrouter")
    assert r.status_code == 200, r.text
    return r.json()


def _verdicts(v: dict, model: str, slug: str) -> dict[str, dict]:
    """`{tag: {pinnable, floor, state}}` of every view row of (model, slug) — a provider's service tiers are one cell."""
    return {e["tag"]: {"pinnable": e["pinnable"], "floor": e["floor"], "state": e["state"]} for e in v["models"][model]["endpoints"] if e["slug"] == slug}


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
    with given(f"a first good refresh (2 models); then mcp_behaviour = {mcp_behaviour!r}, endpoints = {endpoints or 'ok'!r}"):
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


async def test_null_uptime_kept(gw, app, upstreams):
    """row: an endpoint without an uptime figure does not fail its model's parse"""
    world(note=f"{WORLD}; endpoints-null-uptime for {G}")
    upstreams[RAIL].endpoints_behaviour[G] = "endpoints-null-uptime"
    outcome = await _refresh(app)
    then_eq("outcome", outcome, "ok")
    v = await _view(gw)
    first = v["models"][G]["endpoints"][0]
    attach_json(f"{G}'s first endpoint as the view shows it", first)
    then_eq("models · unreadable · candidate cells", (sorted(v["models"]), v["endpoint_failures"], _cells(v)["candidate"]), ([M, G], 5, 15))
    then_eq(f"{G}'s first endpoint's uptime_1d", first["uptime_1d"], None)


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


class _SecondGateway:
    """A new gateway on the same DB (a pod roll): `startup_delay` is the loop's first decision —
    `run()` is not started (ASGI transports run no lifespan), the test calls the helper it wraps."""

    def __init__(self, settings, policy, secrets, mcp_transport, reviews, pods, clock):
        import httpx

        from agent_gateway.app import create_app
        from agent_gateway.store import Store

        from .conftest import ObservedAsyncClient

        self.client = httpx.AsyncClient(transport=mcp_transport)
        self.app = create_app(settings, policy=policy, source=secrets, store=Store(settings.db_path), client=self.client, clock=clock,
                              reviewer=reviews, pods=pods)
        self.gw = ObservedAsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="http://gw2")
        self.delay = self.app.state.orcatalog.startup_delay(clock())
        attach_json("the second gateway's startup_delay", {"startup_delay_s": self.delay, "served_from": iso(self.app.state.orcatalog.served_from)})

    async def close(self) -> None:
        await self.gw.aclose()
        await self.client.aclose()


async def test_restart_inside_interval(gw, app, clock, settings, policy, secrets, mcp_transport, reviews, pods):
    """row: a restart inside the interval refreshes nothing at start"""
    world(note=f"{WORLD}; a second gateway on the same DB, refresh_s 21600")
    await _refresh(app)
    clock.advance(3600)
    with given("a new gateway built on the same DB path, +3600 s"):
        second = _SecondGateway(settings, policy, secrets, mcp_transport, reviews, pods, clock)
    r = await _canary(second.gw, M, "fireworks", " on the second gateway (a cell the snapshot lacks)")
    v = await _view(second.gw)
    await second.close()
    then_eq("the loop's first refresh waits (startup_delay)", second.delay, 18000.0)
    then_eq("last_attempt_at · models · candidate cells", (v["last_attempt_at"], len(v["models"]), _cells(v)["candidate"]), (None, 2, 15))
    _verdict(r.json(), {"decision": "defer", "reason": "not-in-catalog", "retry_after_s": 18000})


async def test_restart_after_interval(gw, app, clock, settings, policy, secrets, mcp_transport, reviews, pods):
    """row: a restart after the interval refreshes at start"""
    world(note=f"{WORLD}; a second gateway on the same DB, refresh_s 21600")
    await _refresh(app)
    clock.advance(21600)
    with given("a new gateway built on the same DB path, +21600 s"):
        second = _SecondGateway(settings, policy, secrets, mcp_transport, reviews, pods, clock)
    then_eq("the loop refreshes at once (startup_delay)", second.delay, 0.0)
    outcome = await _refresh(second.app, " on the second gateway, at start")
    v = await _view(second.gw)
    await second.close()
    then_eq("outcome · fetched_at · models · candidate cells", (outcome, v["fetched_at"], len(v["models"]), _cells(v)["candidate"]),
            ("ok", iso(T0 + 21600), 2, 15))


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
    doc = r.json()
    _verdict(doc, {"decision": "dispatch", "rail": RAIL, "model": M, "harness": "opencode"})
    with then("the canary's ride pins deepinfra with fallbacks off; the row's canary_provider = deepinfra"):
        with quiet():
            rr = await gw.post(PATH, json={"model": M, "messages": []}, headers=bearer(doc))
        check("ride (status, the upstream body's provider block, canary_provider)",
              (rr.status_code, (upstreams[RAIL].calls[-1]["body"] or {}).get("provider"), store.get_session(doc["session"]["id"]).canary_provider),
              (200, {"order": ["deepinfra"], "allow_fallbacks": False}, "deepinfra"))


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


async def _three_admitted(gw, app) -> None:
    with given("3 canaries admitted this refresh"):
        with quiet():
            for p in ("deepinfra", "atlas-cloud", "morph"):
                assert (await gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": f"c-{p}", "canary": {"model": M, "provider": p}})).json()["decision"] == "dispatch"


async def test_budget_survives_roll(gw, app, clock, settings, policy, secrets, mcp_transport, reviews, pods):
    """row: a pod roll inside the window keeps the count"""
    world(note=f"{WORLD}; a second gateway on the same DB, refresh_s 21600")
    await _refresh(app)
    await _three_admitted(gw, app)
    clock.advance(3600)
    with given("a new gateway built on the same DB path, +3600 s — no refresh at start"):
        second = _SecondGateway(settings, policy, secrets, mcp_transport, reviews, pods, clock)
    r = await _canary(second.gw, M, "inference-net", " (the 4th, on the second gateway)")
    v = await _view(second.gw)
    exhausted = await _series(second.gw, "gateway_canary_budget_exhausted")
    await second.close()
    _verdict(r.json(), {"decision": "defer", "reason": "canary-budget", "retry_after_s": 3600})
    then_eq("startup_delay · admitted_this_refresh · gateway_canary_budget_exhausted", (second.delay, v["canary"]["admitted_this_refresh"], exhausted), (18000.0, 3, 1))


async def test_budget_roll_after_interval(gw, app, clock, settings, policy, secrets, mcp_transport, reviews, pods):
    """row: a pod roll after the interval refreshes and opens the next N"""
    world(note=f"{WORLD}; a second gateway on the same DB, refresh_s 21600")
    await _refresh(app)
    await _three_admitted(gw, app)
    clock.advance(21600)
    with given("a new gateway built on the same DB path, +21600 s — its refresh at start"):
        second = _SecondGateway(settings, policy, secrets, mcp_transport, reviews, pods, clock)
        await _refresh(second.app, " on the second gateway, at start")
    r = await _canary(second.gw, M, "inference-net", " (the 4th, on the second gateway)")
    exhausted = await _series(second.gw, "gateway_canary_budget_exhausted")
    await second.close()
    _verdict(r.json(), {"decision": "dispatch", "rail": RAIL, "model": M})
    then_eq("startup_delay · gateway_canary_budget_exhausted", (second.delay, exhausted), (0.0, 0))


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


# -- the floors' verdict on the view (homelab#2775) ------------------------------------------------
PINNABLE_ROWS = [
    ("the view says which cells selection could pin: a cell without required/function is pinnable for opencode and goose, not claude",
     "morph", {"opencode": True, "goose": True, "claude": False}, {"claude": "no tool_choice required,function"}),
    ("the 2026-10-20 cell: fp4 is pinnable for no harness",
     "open-inference", {"opencode": False, "goose": False, "claude": False}, {h: "quantization fp4 < fp8" for h in HARNESSES}),
    ("a cell clearing every floor is pinnable everywhere; its service tiers carry the representative's verdict",
     "deepinfra", {"opencode": True, "goose": True, "claude": True}, {}),
]


@pytest.mark.parametrize(("slug", "pinnable", "floor"), [r[1:] for r in PINNABLE_ROWS], ids=[r[0] for r in PINNABLE_ROWS])
async def test_pinnable_per_harness(gw, app, slug, pinnable, floor):
    world(note=f"{WORLD}; the floors of policy-default (fp8, uptime 95, tool_choice opencode/goose auto, claude auto+required+function)")
    await _refreshed(app, f"a first good refresh; the rows of M@{slug!r} are read for pinnable = {pinnable}, floor = {floor}")
    with when("GET /catalog/openrouter"):
        v = await _view(gw)
    rows = _verdicts(v, M, slug)
    attach_json(f"the view's rows of M@{slug}", rows)
    then_eq(f"every row of M@{slug}: (pinnable, floor)", {t: (r["pinnable"], r["floor"]) for t, r in rows.items()},
            {t: (pinnable, floor) for t in rows})
    then_eq("rows of the provider (its service tiers are one cell)", len(rows), 3 if slug == "deepinfra" else 1)


async def test_pinnable_null_uptime(gw, app, upstreams):
    """row: a null uptime clears no floor on any harness"""
    world(note=f"{WORLD}; endpoints-null-uptime@inference-net/fp8 for M (the one M endpoint every harness could otherwise pin)")
    upstreams[RAIL].endpoints_behaviour[M] = "endpoints-null-uptime@inference-net/fp8"
    await _refreshed(app)
    with when("GET /catalog/openrouter"):
        v = await _view(gw)
    row = _verdicts(v, M, "inference-net")["inference-net/fp8"]
    attach_json("M@inference-net as the view shows it", next(e for e in v["models"][M]["endpoints"] if e["slug"] == "inference-net"))
    then_eq("uptime_1d · pinnable · floor", (next(e["uptime_1d"] for e in v["models"][M]["endpoints"] if e["slug"] == "inference-net"), row["pinnable"], row["floor"]),
            (None, {h: False for h in HARNESSES}, {h: "uptime_1d unknown" for h in HARNESSES}))


async def test_pinnable_follows_policy(gw, app, clock, settings, secrets, mcp_transport, reviews, pods, tmp_path):
    """row: the flag follows the policy, not the data"""
    world(note=f"{WORLD}; a second gateway on the same DB, policy-default with providers.quantization_floor fp4")
    await _refreshed(app)
    import httpx

    from agent_gateway.app import create_app
    from agent_gateway.config import Policy
    from agent_gateway.store import Store

    from .conftest import ObservedAsyncClient

    with given("a second gateway on the same DB and the same snapshot, its policy the fixture with quantization_floor = fp4 (the data untouched)"):
        doc = json.loads(POLICY_FIXTURE.read_text(encoding="utf-8"))
        doc["rails"][RAIL]["providers"]["quantization_floor"] = "fp4"
        path = tmp_path / "policy-floor-fp4.json"
        path.write_text(json.dumps(doc), encoding="utf-8")
        client = httpx.AsyncClient(transport=mcp_transport)
        second = create_app(settings, policy=Policy.load(path), source=secrets, store=Store(settings.db_path), client=client, clock=clock,
                            reviewer=reviews, pods=pods)
    async with ObservedAsyncClient(transport=httpx.ASGITransport(app=second), base_url="http://gw2") as c:
        with when("GET /catalog/openrouter on both gateways"):
            low = (await c.get("/catalog/openrouter")).json()
            with quiet():
                default = await _view(gw)
    await client.aclose()
    then_eq("M@open-inference (fp4) under the fp8 floor: (pinnable, floor)", tuple(_verdicts(default, M, "open-inference")["open-inference/fp4"][k] for k in ("pinnable", "floor")),
            ({h: False for h in HARNESSES}, {h: "quantization fp4 < fp8" for h in HARNESSES}))
    then_eq("the same row under the fp4 floor", tuple(_verdicts(low, M, "open-inference")["open-inference/fp4"][k] for k in ("pinnable", "floor")),
            ({h: True for h in HARNESSES}, {}))


async def test_selected_is_pinnable(gw, app, upstreams):
    """row: selected is always a pinnable cell: the cheaper eligible fp4 cell is passed over"""
    world(upstream="upstream-ok", note=f"{WORLD}; clean canaries on (M, open-inference) and (M, deepinfra)")
    await _refreshed(app)
    with given("clean canary rides on (M, open-inference) — out $0.08/M, fp4 — and (M, deepinfra) — out $0.42/M, fp8"):
        await _canary_ride(gw, app, upstreams, "open-inference")
        await _canary_ride(gw, app, upstreams, "deepinfra")
    with when("GET /catalog/openrouter"):
        v = await _view(gw)
    oi, di = _verdicts(v, M, "open-inference")["open-inference/fp4"], _verdicts(v, M, "deepinfra")["deepinfra/fp8"]
    then_eq("(state, pinnable[opencode]) of M@open-inference · M@deepinfra", ((oi["state"], oi["pinnable"]["opencode"]), (di["state"], di["pinnable"]["opencode"])),
            (("eligible", False), ("eligible", True)))
    then_eq("M's selected · order", (v["models"][M]["selected"], v["models"][M]["order"]), ("deepinfra", ["deepinfra"]))
    with then("every model's selected provider is an eligible row that is pinnable for the canary harness (opencode)"):
        picked = {mid: next((e["state"], e["pinnable"]["opencode"]) for e in m["endpoints"] if e["slug"] == m["selected"])
                  for mid, m in v["models"].items() if m["selected"] is not None}
        check("(state, pinnable[opencode]) per selected", picked, {mid: ("eligible", True) for mid in picked})


async def test_launcher_walk(gw, app):
    """row: the launcher walks pinnable candidate cells cheapest-first; the skipped cells and their floor are in the banner"""
    world(note=f"{WORLD}; a fake HTTP server hands scripts/canary-entrants.sh the view; stdin /dev/null; --dry-run")
    await _refreshed(app)
    body = json.dumps(await _view(gw)).encode()
    seen: list[str] = []

    class View(BaseHTTPRequestHandler):
        def do_GET(self):
            seen.append(self.path)
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), View)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        with when("bash scripts/canary-entrants.sh --dry-run < /dev/null, AGENT_GATEWAY_URL = the fake serving the view"):
            r = subprocess.run(["bash", str(LAUNCHER), "--dry-run"], env={**os.environ, "AGENT_GATEWAY_URL": f"http://127.0.0.1:{srv.server_port}"},
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120, check=False)
            attach_json("the launcher's output", {"exit": r.returncode, "stdout": r.stdout, "stderr": r.stderr})
    finally:
        srv.shutdown()
        srv.server_close()
    then_eq("exit · the fake's requests (the view, then `== after:`) · ride attempts", (r.returncode, seen, r.stdout.count("ride did not dispatch")),
            (0, ["/catalog/openrouter", "/catalog/openrouter"], 0))
    then_eq("the walk, in order", re.findall(r"^== canary \d+/\d+: (\S+)$", r.stdout, re.M),
            [f"{M}@deepinfra", f"{G}@near-ai", f"{G}@z-ai", f"{M}@atlas-cloud", f"{M}@morph", f"{G}@morph", f"{G}@inceptron", f"{M}@inference-net", f"{M}@baidu"])
    then_eq("the banner's skipped cells, each with its floor", _banner_section(r.stdout, "== skipped"),
            [f"{M}@alibaba (quantization unknown)", f"{M}@open-inference (quantization fp4 < fp8)", f"{M}@parasail (uptime_1d 77.4359 < 95)",
             f"{G}@atlas-cloud (uptime_1d 77.8199 < 95)", f"{G}@open-inference (quantization fp4 < fp8)", f"{G}@reka (quantization unknown)"])


def _banner_section(out: str, head: str) -> list[str]:
    lines = out.splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith(head))
    body = []
    for line in lines[start + 1:]:
        if line.startswith("=="):
            break
        body.append(line.strip())
    return body


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

