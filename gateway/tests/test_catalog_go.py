"""GW-CATALOG-GO — the Go rail's vendor facts, read from the vendor (specs/endpoints/catalog.md).

World: policy-default (plan go; Go ids deepseek-v4.1-flash, claude-haiku-5-5) · the fake vendor
(tests/_catalog_world.py): catalog-* answers models.dev's api.json (the catalog read), config-* the
console config (the overlay read) — together the `config` source — and docs-* the Go page. T0 =
the test clock, 2027-01-15T08:00:00Z.

| description | last good (config) | the fake answers | outcome | snapshot | models |
|---|---|---|---|---|---|
| a first good fetch becomes the snapshot | none | catalog-ok + config-ok | ok | the new one, fetched_at T0 | 5 |
| a deprecated catalog row is not listed | none | catalog-ok (6 rows, step-5-preview-free deprecated) | ok | step-5-preview-free absent | 5 |
| an override-only console answer lists the catalog as is | none | config-ok (opencode-go.models {}) | ok | the catalog's five | 5 |
| a disabled override unlists the row | 5, fetched T0 | config-disables (deepseek-v4-pro) | ok | deepseek-v4-pro absent | 4 |
| a cost or limit override wins | 5, fetched T0 | config-reprices (claude-haiku-5-5) | ok | the override's cost, context 200000, output the catalog's | 5 |
| a console-only row with a cost and both limits is listed | 5, fetched T0 | config-adds (deepseek-v4-flash) | ok | deepseek-v4-flash listed | 6 |
| a console-only row without them lists nothing | 5, fetched T0 | config-adds-bare | ok | deepseek-v4-flash absent | 5 |
| a later good fetch replaces it | 5, fetched T0 | catalog-ok + config-ok at T0 + 21600 s | ok | fetched_at T0 + 21600 s | 5 |
| an upstream error on the catalog read keeps the last good | 5, fetched T0 | catalog-503 | fetch-failed | the last good | 5 |
| an upstream error on the console read keeps the last good | 5, fetched T0 | config-503 | fetch-failed | the last good | 5 |
| an unreachable catalog host keeps the last good | 5, fetched T0 | catalog-down | fetch-failed | the last good | 5 |
| an unreachable console keeps the last good | 5, fetched T0 | config-down | fetch-failed | the last good | 5 |
| a catalog row without its cost is a parse failure | 5, fetched T0 | catalog-malformed | parse-failed | the last good | 5 |
| a legacy context_over_200k row with no tiers is a parse failure | 5, fetched T0 | catalog-legacy-tier | parse-failed | the last good | 5 |
| an override whose cost is not a cost is a parse failure | 5, fetched T0 | config-malformed | parse-failed | the last good | 5 |
| a catalog without the Go provider is a parse failure | 5, fetched T0 | catalog-no-provider | parse-failed | the last good | 5 |
| a console answer without the Go provider is a parse failure | 5, fetched T0 | config-no-provider | parse-failed | the last good | 5 |
| a drop below half the models is implausible | 5, fetched T0 | catalog-shrunk (2) | implausible | the last good | 5 |
| a drop to half or more is taken | 5, fetched T0 | catalog-trimmed (3) | ok | the new one | 3 |
| zero models is implausible with no last good | none | catalog-empty | implausible | none | 0 |

| description | last good (docs) | the fake answers | outcome | snapshot |
|---|---|---|---|---|
| the page parses | none | docs-ok | ok | 5 models |
| a 404 keeps the last good — the page moved | 5 | docs-404 | fetch-failed | the last good |
| a plan row naming a model the Endpoints table lacks is a parse failure | 5 | docs-unknown-model | parse-failed | the last good |
| an Endpoints row with one cell is a parse failure | 5 | docs-short-endpoint-row | parse-failed | the last good |
| a renamed limit column is a parse failure | 5 | docs-header-drift | parse-failed | the last good |
| peak rows without the peak-hours sentence are a parse failure | 5 | docs-no-peak-hours | parse-failed | the last good |
| no share sentence is a parse failure | 5 | docs-no-shares | parse-failed | the last good |
| no plan table is a parse failure | 5 | docs-no-plan-table | parse-failed | the last good |
| a drop below half the models is implausible | 5 | docs-shrunk (2) | implausible | the last good |

| description | model | plan go | plan go-plus | bonus | peak row |
|---|---|---|---|---|---|
| a plain row gives the monthly limit per plan | deepseek-v4.1-flash | 80 | 160 | — | 0.30 / 1.20 / 0.006 / null |
| a promotion reads the current limit, not the struck one | step-5-preview | 60 | 240 | 4 | — |
| Unlimited is unlimited | longcat-2.5-preview-free | unlimited | unlimited | — | — |
| context-tier rows are one model with one limit | claude-haiku-5-5 | 15 | 60 | — | — |

| description | input | the snapshot reads |
|---|---|---|
| the plan fees come from the page | docs-ok | plan_fee_usd_month 10 (plan go); the docs snapshot's plan_fees go 10 / go-plus 40 |
| the peak hours come from the page | docs-ok | [[1, 4], [6, 10]], mon–fri |
| the window shares come from the page | docs-ok | 0.2 / 0.5 / 1.0; deepseek-v4.1-flash windows 16 / 40 / 80 |
| the config's prices are the model's cost rows | catalog-ok claude-haiku-5-5 | base 0.10/0.50/0.01/0.125, above 100000 0.50/2.50/0.05/0.625 |
| a model the page tabulates but the config does not list is shown unlisted | catalog-trimmed + docs-ok | step-5-preview listed false, limit 60 |
| the view's shape is the schema's | catalog-ok + docs-ok | exactly the schema's required keys |

| description | rails.<rail>.plan | the policy load |
|---|---|---|
| the declared plan picks the limits' tab | opencode go | loads; view plan go |
| no plan refuses the load | opencode absent | refused, naming rails.opencode.plan |
| an unknown plan refuses the load | opencode pro | refused, naming rails.opencode.plan |
| a plan on another rail refuses the load | openrouter go | refused, naming rails.openrouter.plan |

| description | rails.opencode.admission edit | the policy load |
|---|---|---|
| a price row in the policy refuses the load | window_draw.prices | refused, naming prices |
| a fallback price refuses the load | window_draw.fallback | refused, naming fallback |
| a window budget refuses the load | windows.5h.budget_usd | refused, naming budget_usd |
| a window the vendor gives no share refuses the load | windows.1d | refused, naming windows.1d |
| an unknown latch scope refuses the load | latch_scope: rail | refused, naming latch_scope |

| description | source | authorization | user-agent | x-opencode-session |
|---|---|---|---|---|
| the console read carries the key and a client identity | config | Bearer <key> | agent-gateway/<v> (go-catalog) | a UUID, new per fetch |
| the catalog read carries no credential | catalog | absent | agent-gateway/<v> (go-catalog) | absent |
| the docs fetch carries no credential | docs | absent | agent-gateway/<v> (go-catalog) | absent |
| no key, no config fetch | config, no key | — no request on either read; fetch-failed | — | — |
| the key never reaches a log line | config-401-echo | — every gateway.catalog line free of the key | — | — |

| description | sequence | after the restart |
|---|---|---|
| a PVC store keeps the snapshot | ok + ok, new gateway on the same DB, +3600 s | both served; age_s 3600; models{config} 5 |
| a corrupt stored snapshot is ignored | a stored config row that is not JSON | no config snapshot |

| description | event | series | value |
|---|---|---|---|
| age is seconds since the last good fetch | catalog-ok at T0, read at T0 + 600 s | gateway_go_catalog_age_seconds{source="config"} | 600 |
| no snapshot, no age | nothing fetched | gateway_go_catalog_age_seconds{source="config"} | absent |
| the model count of the last good snapshot | catalog-ok, then catalog-shrunk | gateway_go_catalog_models{source="config"} | 5 |
| every refresh is counted by outcome | catalog-ok, then catalog-malformed | refresh_total ok / parse-failed | 1 / 1 |
| the last outcome is 1, the others 0 | catalog-ok, then catalog-malformed | last_outcome parse-failed / ok | 1 / 0 |
| every policy Go model listed: none missing | catalog-ok | policy_models_missing{source="config"} | 0 |
| policy Go models the config does not list are counted | catalog-shrunk | policy_models_missing{source="config"} | 1 |
| policy Go models without a limit row under the plan are counted | docs-shrunk | policy_models_missing{source="docs"} | 1 |
"""

from __future__ import annotations

import json
import logging
import re
import uuid
from pathlib import Path

import pytest

from agent_gateway import __version__

from ._catalog_world import gw_client
from .conftest import GO_KEY, attach_json, check, given, quiet, rule, then, then_eq, when, world

pytestmark = rule("GW-CATALOG-GO")

SCHEMA = json.loads((Path(__file__).resolve().parents[1] / "specs" / "endpoints" / "catalog.schema.json").read_text(encoding="utf-8"))
T0 = 1_800_000_000.0


def _iso(ts: float) -> str:
    import datetime as dt
    return dt.datetime.fromtimestamp(ts, tz=dt.UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


async def _view(app) -> dict:
    async with gw_client(app) as c:
        r = await c.get("/catalog/opencode")
    assert r.status_code == 200, r.text
    return r.json()


async def _metrics(app) -> str:
    async with gw_client(app) as c:
        with quiet():
            return (await c.get("/metrics")).text


def _value(text: str, series: str) -> float | None:
    m = re.search(r"^" + re.escape(series) + r" (\S+)$", text, re.M)
    return float(m.group(1)) if m else None


async def _arrange_good(app, vendor, source: str) -> None:
    """The last good snapshot: one ok refresh at T0 (the fixture's five models)."""
    with given(f"last good ({source}): one refresh at T0 answered by the fixture — 5 models"):
        if source == "config":
            vendor.catalog, vendor.config = "catalog-ok", "config-ok"
        else:
            vendor.docs = "docs-ok"
        assert await app.state.catalog.refresh_source(source) == "ok"


# ── What a refresh keeps: config (the catalog read + the console overlay) ─────────────────────
LAST_GOOD = "5, fetched T0"
OK = ("catalog-ok", "config-ok")
LISTED_FIVE = ["claude-haiku-5-5", "deepseek-v4-pro", "deepseek-v4.1-flash", "longcat-2.5-preview-free", "step-5-preview"]
# (description, last good, (catalog knob, config knob), at, outcome, fetched_at, models, listed ids after)
CONFIG_ROWS = [
    ("a first good fetch becomes the snapshot", "none", OK, "T0", "ok", T0, 5, LISTED_FIVE),
    ("a deprecated catalog row is not listed", "none", OK, "T0", "ok", T0, 5, LISTED_FIVE),
    ("an override-only console answer lists the catalog as is", "none", OK, "T0", "ok", T0, 5, LISTED_FIVE),
    ("a disabled override unlists the row", LAST_GOOD, ("catalog-ok", "config-disables"), "T0", "ok", T0, 4,
     [m for m in LISTED_FIVE if m != "deepseek-v4-pro"]),
    ("a cost or limit override wins", LAST_GOOD, ("catalog-ok", "config-reprices"), "T0", "ok", T0, 5, LISTED_FIVE),
    ("a console-only row with a cost and both limits is listed", LAST_GOOD, ("catalog-ok", "config-adds"), "T0", "ok", T0, 6,
     sorted([*LISTED_FIVE, "deepseek-v4-flash"])),
    ("a console-only row without them lists nothing", LAST_GOOD, ("catalog-ok", "config-adds-bare"), "T0", "ok", T0, 5, LISTED_FIVE),
    ("a later good fetch replaces it", LAST_GOOD, OK, "T0 + 21600 s", "ok", T0 + 21600, 5, LISTED_FIVE),
    ("an upstream error on the catalog read keeps the last good", LAST_GOOD, ("catalog-503", "config-ok"), "T0", "fetch-failed", T0, 5, LISTED_FIVE),
    ("an upstream error on the console read keeps the last good", LAST_GOOD, ("catalog-ok", "config-503"), "T0", "fetch-failed", T0, 5, LISTED_FIVE),
    ("an unreachable catalog host keeps the last good", LAST_GOOD, ("catalog-down", "config-ok"), "T0", "fetch-failed", T0, 5, LISTED_FIVE),
    ("an unreachable console keeps the last good", LAST_GOOD, ("catalog-ok", "config-down"), "T0", "fetch-failed", T0, 5, LISTED_FIVE),
    ("a catalog row without its cost is a parse failure", LAST_GOOD, ("catalog-malformed", "config-ok"), "T0", "parse-failed", T0, 5, LISTED_FIVE),
    ("a legacy context_over_200k row with no tiers is a parse failure", LAST_GOOD, ("catalog-legacy-tier", "config-ok"), "T0", "parse-failed", T0, 5, LISTED_FIVE),
    ("an override whose cost is not a cost is a parse failure", LAST_GOOD, ("catalog-ok", "config-malformed"), "T0", "parse-failed", T0, 5, LISTED_FIVE),
    ("a catalog without the Go provider is a parse failure", LAST_GOOD, ("catalog-no-provider", "config-ok"), "T0", "parse-failed", T0, 5, LISTED_FIVE),
    ("a console answer without the Go provider is a parse failure", LAST_GOOD, ("catalog-ok", "config-no-provider"), "T0", "parse-failed", T0, 5, LISTED_FIVE),
    ("a drop below half the models is implausible", LAST_GOOD, ("catalog-shrunk", "config-ok"), "T0", "implausible", T0, 5, LISTED_FIVE),
    ("a drop to half or more is taken", LAST_GOOD, ("catalog-trimmed", "config-ok"), "T0", "ok", T0, 3,
     ["claude-haiku-5-5", "deepseek-v4-pro", "deepseek-v4.1-flash"]),
    ("zero models is implausible with no last good", "none", ("catalog-empty", "config-ok"), "T0", "implausible", None, 0, []),
]


@pytest.mark.parametrize(("last", "knobs", "at", "outcome", "fetched", "models", "listed"),
                         [r[1:] for r in CONFIG_ROWS], ids=[r[0] for r in CONFIG_ROWS])
async def test_config_refresh(cworld, vendor, vendor_transport, clock, last, knobs, at, outcome, fetched, models, listed):
    catalog_b, config_b = knobs
    world(upstream=f"{catalog_b} · {config_b}")
    app = cworld.build()
    with given(f"last good (config): {last}"):
        if last != "none":
            vendor.catalog, vendor.config = OK
            assert await app.state.catalog.refresh_source("config") == "ok"
    if at != "T0":
        clock.t = T0 + 21600
    with given(f"the fake vendor answers {catalog_b} (models.dev) and {config_b} (the console) at {at}"):
        vendor.catalog, vendor.config = catalog_b, config_b
        for read, b in (("catalog", catalog_b), ("config", config_b)):
            if b.endswith("-down"):
                vendor_transport.down.add(read)
    with when(f"the config source refreshes at {at}"):
        got = await app.state.catalog.refresh_source("config")
    then_eq("outcome", got, outcome)
    with then(f"GET /catalog/opencode: config fetched_at {fetched and _iso(fetched)}, {models} models, listed {listed}"):
        v = await _view(app)
        cfg = v["sources"]["config"]
        check("sources.config", {k: cfg[k] for k in ("fetched_at", "models", "last_outcome")},
              {"fetched_at": _iso(fetched) if fetched else None, "models": models, "last_outcome": outcome})
        check("listed ids", sorted(m for m, r in v["models"].items() if r["listed"]), listed)
    if config_b == "config-reprices":
        with then("claude-haiku-5-5: the override's two cost rows, context 200000 (the override), output 128000 (the catalog's)"):
            row = v["models"]["claude-haiku-5-5"]
            check("cost", row["cost"], [{"above_tokens": 0, "in": 0.2, "out": 1.0, "cache_read": 0.02, "cache_write": 0.25},
                                        {"above_tokens": 200000, "in": 1.0, "out": 5.0, "cache_read": 0.1, "cache_write": 1.25}])
            check("(context, output)", (row["context"], row["output"]), (200000, 128000))
    if config_b == "config-adds":
        with then("deepseek-v4-flash: the console-only row's cost, limits, family and tools"):
            row = v["models"]["deepseek-v4-flash"]
            check("row", {k: row[k] for k in ("family", "tools", "context", "output", "cost")},
                  {"family": "deepseek-flash", "tools": True, "context": 1000000, "output": 384000,
                   "cost": [{"above_tokens": 0, "in": 0.14, "out": 0.28, "cache_read": 0.028, "cache_write": None}]})


# ── What a refresh keeps: docs ───────────────────────────────────────────────────────────────
DOCS_ROWS = [
    ("the page parses", "none", "docs-ok", "ok"),
    ("a 404 keeps the last good — the page moved", "5", "docs-404", "fetch-failed"),
    ("a plan row naming a model the Endpoints table lacks is a parse failure", "5", "docs-unknown-model", "parse-failed"),
    ("an Endpoints row with one cell is a parse failure", "5", "docs-short-endpoint-row", "parse-failed"),
    ("a renamed limit column is a parse failure", "5", "docs-header-drift", "parse-failed"),
    ("peak rows without the peak-hours sentence are a parse failure", "5", "docs-no-peak-hours", "parse-failed"),
    ("no share sentence is a parse failure", "5", "docs-no-shares", "parse-failed"),
    ("no plan table is a parse failure", "5", "docs-no-plan-table", "parse-failed"),
    ("a drop below half the models is implausible", "5", "docs-shrunk", "implausible"),
]


@pytest.mark.parametrize(("last", "behaviour", "outcome"), [r[1:] for r in DOCS_ROWS], ids=[r[0] for r in DOCS_ROWS])
async def test_docs_refresh(cworld, vendor, clock, last, behaviour, outcome):
    world(upstream=behaviour)
    app = cworld.build()
    with given(f"last good (docs): {'none' if last == 'none' else last + ' models, fetched T0'}"):
        if last != "none":
            vendor.docs = "docs-ok"
            assert await app.state.catalog.refresh_source("docs") == "ok"
    clock.advance(60)
    with given(f"the fake vendor's Go page answers {behaviour}"):
        vendor.docs = behaviour
    with when(f"the docs source refreshes at T0 + 60 s ({behaviour})"):
        got = await app.state.catalog.refresh_source("docs")
    then_eq("outcome", got, outcome)
    expected_at = T0 + 60 if outcome == "ok" else T0
    with then(f"the docs snapshot: 5 models, fetched_at {_iso(expected_at)}"):
        v = await _view(app)
        check("sources.docs", {k: v["sources"]["docs"][k] for k in ("models", "fetched_at")},
              {"models": 5, "fetched_at": _iso(expected_at)})


# ── What the page says, per model ────────────────────────────────────────────────────────────
PEAK_V41 = {"in": 0.30, "out": 1.20, "cache_read": 0.006, "cache_write": None}
LIMIT_ROWS = [
    ("a plain row gives the monthly limit per plan", "deepseek-v4.1-flash", 80.0, 160.0, "—", PEAK_V41),
    ("a promotion reads the current limit, not the struck one", "step-5-preview", 60.0, 240.0, "4", None),
    ("Unlimited is unlimited", "longcat-2.5-preview-free", "unlimited", "unlimited", "—", None),
    ("context-tier rows are one model with one limit", "claude-haiku-5-5", 15.0, 60.0, "—", None),
]


@pytest.mark.parametrize(("model", "go", "go_plus", "bonus", "peak"), [r[1:] for r in LIMIT_ROWS], ids=[r[0] for r in LIMIT_ROWS])
async def test_page_per_model(cworld, vendor, model, go, go_plus, bonus, peak):
    world(upstream="catalog-ok · docs-ok")
    app = cworld.build()
    with given("both sources refreshed once: catalog-ok + docs-ok"):
        await app.state.catalog.refresh()
    with when(f"GET /catalog/opencode → models.{model}; the docs snapshot's go-plus row"):
        v = await _view(app)
        row = v["models"][model]
        plus = app.state.catalog.snapshots["docs"].body["plans"]["go-plus"].get(model)
    with then(f"plan go {go} · go-plus {go_plus} · bonus {bonus} · peak {peak}"):
        check(f"models.{model} (plan go) + the go-plus row",
              {"go": row["monthly_limit_usd"], "go-plus": plus, "bonus": row["bonus"], "peak": row["peak"]},
              {"go": go, "go-plus": go_plus, "bonus": None if bonus == "—" else int(bonus), "peak": peak})


async def test_peak_hours_from_page(cworld, vendor):
    """row: the peak hours come from the page"""
    world(upstream="docs-ok")
    app = cworld.build()
    with when("the docs source refreshes (docs-ok)"):
        await app.state.catalog.refresh_source("docs")
    with then("peak_hours_utc [[1, 4], [6, 10]], peak_weekdays mon–fri"):
        v = await _view(app)
        check("peak_hours_utc", v["peak_hours_utc"], [[1, 4], [6, 10]])
        check("peak_weekdays", v["peak_weekdays"], ["mon", "tue", "wed", "thu", "fri"])


async def test_plan_fees_from_page(cworld, vendor):
    """row: the plan fees come from the page"""
    world(upstream="docs-ok")
    app = cworld.build()
    with when("the docs source refreshes (docs-ok)"):
        await app.state.catalog.refresh_source("docs")
    with then("plan_fee_usd_month 10 (plan go); the docs snapshot's plan_fees go 10 / go-plus 40"):
        v = await _view(app)
        check("plan_fee_usd_month", v["plan_fee_usd_month"], 10.0)
        check("docs snapshot plan_fees", app.state.catalog.snapshots["docs"].body["plan_fees"], {"go": 10.0, "go-plus": 40.0})


async def test_window_shares_from_page(cworld, vendor):
    """row: the window shares come from the page"""
    world(upstream="catalog-ok · docs-ok")
    app = cworld.build()
    with when("both sources refresh"):
        await app.state.catalog.refresh()
    with then("window_shares 0.2 / 0.5 / 1.0; deepseek-v4.1-flash windows_usd 16 / 40 / 80"):
        v = await _view(app)
        check("window_shares", v["window_shares"], {"5h": 0.2, "7d": 0.5, "30d": 1.0})
        check("deepseek-v4.1-flash windows_usd", v["models"]["deepseek-v4.1-flash"]["windows_usd"], {"5h": 16.0, "7d": 40.0, "30d": 80.0})


async def test_config_prices_are_cost_rows(cworld, vendor):
    """row: the config's prices are the model's cost rows"""
    world(upstream="catalog-ok")
    app = cworld.build()
    with when("the config source refreshes (catalog-ok)"):
        await app.state.catalog.refresh_source("config")
    with then("claude-haiku-5-5 cost: base 0.10/0.50/0.01/0.125, above 100000 tokens 0.50/2.50/0.05/0.625"):
        v = await _view(app)
        check("models.claude-haiku-5-5.cost", v["models"]["claude-haiku-5-5"]["cost"], [
            {"above_tokens": 0, "in": 0.1, "out": 0.5, "cache_read": 0.01, "cache_write": 0.125},
            {"above_tokens": 100000, "in": 0.5, "out": 2.5, "cache_read": 0.05, "cache_write": 0.625}])


async def test_tabulated_but_unlisted(cworld, vendor):
    """row: a model the page tabulates but the config does not list is shown unlisted"""
    world(upstream="catalog-trimmed · docs-ok")
    app = cworld.build()
    with given("the config answers catalog-trimmed (no step-5-preview), the page docs-ok"):
        vendor.catalog = "catalog-trimmed"
    with when("both sources refresh"):
        await app.state.catalog.refresh()
    with then("step-5-preview: listed false, monthly_limit_usd 60"):
        v = await _view(app)
        check("models.step-5-preview.listed", v["models"]["step-5-preview"]["listed"], False)
        check("models.step-5-preview.monthly_limit_usd", v["models"]["step-5-preview"]["monthly_limit_usd"], 60.0)


# ── The plan ───────────────────────────────────────────────────────────────────────────────
ABSENT = object()
PLAN_ROWS = [
    ("the declared plan picks the limits' tab", "opencode", "go", "loads"),
    ("no plan refuses the load", "opencode", ABSENT, "rails.opencode.plan"),
    ("an unknown plan refuses the load", "opencode", "pro", "rails.opencode.plan"),
    ("a plan on another rail refuses the load", "openrouter", "go", "rails.openrouter.plan"),
]


@pytest.mark.parametrize(("rail", "plan", "refused"), [r[1:] for r in PLAN_ROWS], ids=[r[0] for r in PLAN_ROWS])
async def test_plan(cworld, rail, plan, refused):
    world()
    from agent_gateway.config import Policy, PolicyError

    from .conftest import POLICY_FIXTURE
    doc = json.loads(POLICY_FIXTURE.read_text(encoding="utf-8"))
    shown = "absent" if plan is ABSENT else plan
    with given(f"policy-default with rails.{rail}.plan {shown}"):
        if plan is ABSENT:
            doc["rails"][rail].pop("plan")
        else:
            doc["rails"][rail]["plan"] = plan
    with when("the policy loads"):
        try:
            loaded, error = Policy.from_dict(doc), None
        except PolicyError as e:
            loaded, error = None, str(e)
        attach_json("load result", {"loaded": loaded is not None, "error": error})
    if refused == "loads":
        cworld.policy = loaded
        v = await _view(cworld.build())
        then_eq("view plan", v["plan"], "go", claim="loads; the view's plan is 'go'")
    else:
        with then(f"refused, naming {refused}", refused={"expected": refused, "actual": error}):
            assert error is not None and refused in error, error


# ── What the policy no longer holds (ruling 5) ─────────────────────────────────────────────────
def _set(doc: dict, path: str, value) -> None:
    node = doc["rails"]["opencode"]["admission"]
    *parents, leaf = path.split(".")
    for k in parents:
        node = node[k]
    node[leaf] = value


RULES_ONLY_ROWS = [
    ("a price row in the policy refuses the load", "window_draw.prices",
     {"opencode-go/deepseek-v4.1-flash": {"in": 0.15, "out": 0.60, "cache_read": 0.003, "cache_write": None}}, "prices"),
    ("a fallback price refuses the load", "window_draw.fallback", {"in": 9.0, "out": 9.0, "cache_read": 0, "cache_write": 0}, "fallback"),
    ("a window budget refuses the load", "window_draw.windows.5h.budget_usd", 12.0, "budget_usd"),
    ("a window the vendor gives no share refuses the load", "window_draw.windows.1d", {"threshold": 0.8, "anchor": "weekly", "weekday": "mon"}, "windows.1d"),
    ("an unknown latch scope refuses the load", "latch_scope", "rail", "latch_scope"),
]


@pytest.mark.parametrize(("path", "value", "named"), [r[1:] for r in RULES_ONLY_ROWS], ids=[r[0] for r in RULES_ONLY_ROWS])
def test_rules_only(path, value, named):
    world()
    from agent_gateway.config import Policy, PolicyError

    from .conftest import POLICY_FIXTURE
    doc = json.loads(POLICY_FIXTURE.read_text(encoding="utf-8"))
    with given(f"policy-default with rails.opencode.admission.{path} = {value!r}"):
        _set(doc, path, value)
    with when("the policy loads"):
        try:
            Policy.from_dict(doc)
            error = None
        except PolicyError as e:
            error = str(e)
        attach_json("load result", {"error": error})
    with then(f"refused, naming {named}", refused={"expected": named, "actual": error}):
        assert error is not None and named in error, error


# ── What a fetch sends ───────────────────────────────────────────────────────────────────────
UA = f"agent-gateway/{__version__} (go-catalog)"


async def test_config_fetch_identity(cworld, vendor):
    """row: the console read carries the key and a client identity"""
    world(upstream="catalog-ok · config-ok")
    app = cworld.build()
    with when("the config source refreshes twice"):
        await app.state.catalog.refresh_source("config")
        await app.state.catalog.refresh_source("config")
    calls = [c for c in vendor.calls if c["source"] == "config"]
    then_eq("console reads seen", len(calls), 2)
    with then(f"authorization Bearer <the Go key>, user-agent {UA}, x-opencode-session a UUID new per fetch"):
        check("authorization is the Go key", [c["headers"].get("authorization") == f"Bearer {GO_KEY}" for c in calls], [True, True])
        check("user-agent", [c["headers"].get("user-agent") for c in calls], [UA, UA])
        sessions = [c["headers"].get("x-opencode-session") for c in calls]
        check("x-opencode-session parse as UUIDs", [str(uuid.UUID(s)) == s for s in sessions], [True, True])
        check("x-opencode-session differs per fetch", sessions[0] != sessions[1], True)


async def test_catalog_fetch_no_credential(cworld, vendor):
    """row: the catalog read carries no credential"""
    world(upstream="catalog-ok · config-ok")
    app = cworld.build()
    with when("the config source refreshes"):
        await app.state.catalog.refresh_source("config")
    (call,) = [c for c in vendor.calls if c["source"] == "catalog"]
    with then(f"no authorization, no x-opencode-session; user-agent {UA}"):
        check("authorization", call["headers"].get("authorization"), None)
        check("x-opencode-session", call["headers"].get("x-opencode-session"), None)
        check("user-agent", call["headers"].get("user-agent"), UA)


async def test_docs_fetch_no_credential(cworld, vendor):
    """row: the docs fetch carries no credential"""
    world(upstream="docs-ok")
    app = cworld.build()
    with when("the docs source refreshes"):
        await app.state.catalog.refresh_source("docs")
    (call,) = [c for c in vendor.calls if c["source"] == "docs"]
    with then(f"no authorization, no x-opencode-session; user-agent {UA}"):
        check("authorization", call["headers"].get("authorization"), None)
        check("x-opencode-session", call["headers"].get("x-opencode-session"), None)
        check("user-agent", call["headers"].get("user-agent"), UA)


async def test_no_key_no_fetch(cworld, vendor):
    """row: no key, no config fetch"""
    world(upstream="catalog-ok · config-ok", note="OPENCODE_GO_API_KEY unset")
    app = cworld.build(key=None)
    with when("the config source refreshes with no key"):
        got = await app.state.catalog.refresh_source("config")
    then_eq("outcome", got, "fetch-failed")
    then_eq("requests the vendor saw (models.dev or the console)", len(vendor.calls), 0)


async def test_key_never_logged(cworld, vendor, caplog):
    """row: the key never reaches a log line"""
    world(upstream="catalog-ok · config-401-echo")
    from agent_gateway.logging import RedactingFormatter
    caplog.set_level(logging.DEBUG, logger="gateway.catalog")
    app = cworld.build()
    with given("the console answers 401 with the key in its body (config-401-echo)"):
        vendor.config = "config-401-echo"
    with when("the config source refreshes"):
        got = await app.state.catalog.refresh_source("config")
    fmt = RedactingFormatter("%(message)s")
    lines = [fmt.format(r) for r in caplog.records if r.name == "gateway.catalog"]
    raw = [r.getMessage() for r in caplog.records if r.name == "gateway.catalog"]
    attach_json("gateway.catalog log lines", lines)
    then_eq("outcome", got, "fetch-failed")
    with then("no gateway.catalog line carries the key, before or after the redacting formatter"):
        check("lines carrying the key (formatted)", [x for x in lines if GO_KEY in x], [])
        check("lines carrying the key (raw message)", [x for x in raw if GO_KEY in x], [])


# ── Kept across a restart ────────────────────────────────────────────────────────────────────
async def test_pvc_keeps_snapshot(cworld, vendor, clock):
    """row: a PVC store keeps the snapshot"""
    world(upstream="catalog-ok · docs-ok")
    first = cworld.build()
    with given("both sources refreshed at T0 on gateway #1"):
        await first.state.catalog.refresh()
    clock.advance(3600)
    with when("gateway #2 starts on the same DB at T0 + 3600 s — no refresh"):
        second = cworld.build()
        v = await _view(second)
        text = await _metrics(second)
    with then("both snapshots served, age_s 3600, gateway_go_catalog_models{source=\"config\"} 5"):
        check("sources.config.age_s", v["sources"]["config"]["age_s"], 3600)
        check("sources.docs.age_s", v["sources"]["docs"]["age_s"], 3600)
        check("sources.config.last_outcome (this process attempted none)", v["sources"]["config"]["last_outcome"], None)
        check('gateway_go_catalog_models{source="config"}', _value(text, 'gateway_go_catalog_models{source="config"}'), 5)


async def test_corrupt_snapshot_ignored(cworld, vendor):
    """row: a corrupt stored snapshot is ignored"""
    world()
    with given("the store holds a config snapshot row whose body is not JSON"):
        from agent_gateway.store import Store
        s = Store(cworld.db)
        with s._lock:
            s._db.execute("INSERT INTO catalog_snapshots (source, fetched_at, body) VALUES ('config', ?, '{not json')", (T0,))
        s.close()
    with when("a gateway starts on that DB"):
        app = cworld.build()
        v = await _view(app)
    then_eq("sources.config.models", v["sources"]["config"]["models"], 0)
    then_eq("sources.config.fetched_at", v["sources"]["config"]["fetched_at"], None)


# ── What /metrics says ───────────────────────────────────────────────────────────────────────
async def test_metric_age(cworld, vendor, clock):
    """row: age is seconds since the last good fetch"""
    world(upstream="catalog-ok")
    app = cworld.build()
    with given("catalog-ok at T0"):
        await app.state.catalog.refresh_source("config")
    clock.advance(600)
    with when("GET /metrics at T0 + 600 s"):
        text = await _metrics(app)
        attach_json("sample: gateway_go_catalog_age_seconds", [x for x in text.splitlines() if x.startswith("gateway_go_catalog_age")])
    then_eq('gateway_go_catalog_age_seconds{source="config"}', _value(text, 'gateway_go_catalog_age_seconds{source="config"}'), 600)


async def test_metric_no_age(cworld):
    """row: no snapshot, no age"""
    world()
    app = cworld.build()
    with when("GET /metrics with nothing fetched"):
        text = await _metrics(app)
        attach_json("sample: gateway_go_catalog_* lines", [x for x in text.splitlines() if x.startswith("gateway_go_catalog")])
    then_eq('gateway_go_catalog_age_seconds{source="config"}', _value(text, 'gateway_go_catalog_age_seconds{source="config"}'), None)
    then_eq('gateway_go_catalog_models{source="config"}', _value(text, 'gateway_go_catalog_models{source="config"}'), 0)


async def test_metric_models_and_outcomes(cworld, vendor):
    """row: the model count of the last good snapshot"""
    world(upstream="catalog-ok · catalog-shrunk")
    app = cworld.build()
    await _arrange_good(app, vendor, "config")
    with when("the config answers catalog-shrunk and refreshes"):
        vendor.catalog = "catalog-shrunk"
        await app.state.catalog.refresh_source("config")
        text = await _metrics(app)
    then_eq('gateway_go_catalog_models{source="config"}', _value(text, 'gateway_go_catalog_models{source="config"}'), 5)


async def test_metric_refresh_counted(cworld, vendor):
    """row: every refresh is counted by outcome"""
    world(upstream="catalog-ok · catalog-malformed")
    app = cworld.build()
    await _arrange_good(app, vendor, "config")
    with when("the config answers catalog-malformed and refreshes"):
        vendor.catalog = "catalog-malformed"
        await app.state.catalog.refresh_source("config")
        text = await _metrics(app)
    with then("refresh_total{config,ok} 1 · {config,parse-failed} 1"):
        check("ok", _value(text, 'gateway_go_catalog_refresh_total{source="config",outcome="ok"}'), 1)
        check("parse-failed", _value(text, 'gateway_go_catalog_refresh_total{source="config",outcome="parse-failed"}'), 1)


async def test_metric_last_outcome(cworld, vendor):
    """row: the last outcome is 1, the others 0"""
    world(upstream="catalog-ok · catalog-malformed")
    app = cworld.build()
    await _arrange_good(app, vendor, "config")
    with when("the config answers catalog-malformed and refreshes"):
        vendor.catalog = "catalog-malformed"
        await app.state.catalog.refresh_source("config")
        text = await _metrics(app)
    with then("last_outcome{config,parse-failed} 1 · {config,ok} 0"):
        check("parse-failed", _value(text, 'gateway_go_catalog_last_outcome{source="config",outcome="parse-failed"}'), 1)
        check("ok", _value(text, 'gateway_go_catalog_last_outcome{source="config",outcome="ok"}'), 0)


MISSING_ROWS = [
    ("every policy Go model listed: none missing", "config", "catalog-ok", []),
    ("policy Go models the config does not list are counted", "config", "catalog-shrunk", ["claude-haiku-5-5"]),
    ("policy Go models without a limit row under the plan are counted", "docs", "docs-shrunk", ["claude-haiku-5-5"]),
]


@pytest.mark.parametrize(("source", "behaviour", "missing"), [r[1:] for r in MISSING_ROWS], ids=[r[0] for r in MISSING_ROWS])
async def test_metric_policy_missing(cworld, vendor, policy, source, behaviour, missing):
    world(upstream=behaviour)
    app = cworld.build()
    ids = app.state.catalog.policy_models
    with given(f"policy-default's Go ids (tiers + side_models, wire spelling): {', '.join(ids)}; the {source} source answers {behaviour}"):
        attach_json("policy Go ids", list(ids))
        setattr(vendor, "catalog" if behaviour.startswith("catalog-") else source, behaviour)
    with when(f"the {source} source refreshes ({behaviour}); GET /metrics + /catalog/opencode"):
        await app.state.catalog.refresh_source(source)
        text = await _metrics(app)
        v = await _view(app)
    series = f'gateway_go_catalog_policy_models_missing{{source="{source}"}}'
    then_eq(series, _value(text, series), len(missing))
    key = "listed" if source == "config" else "monthly_limit_usd"
    with then(f"the view names the missing: {', '.join(missing) or 'none'}"):
        uncovered = sorted(m for m, r in v["policy_models"].items() if (r[key] is False if key == "listed" else r[key] is None))
        check(f"policy_models whose {key} is uncovered", uncovered, missing)


async def test_view_keys_are_the_schema(cworld, vendor):
    """row: the view's shape is the schema's"""
    world(upstream="catalog-ok · docs-ok")
    app = cworld.build()
    with when("both sources refresh; GET /catalog/opencode"):
        await app.state.catalog.refresh()
        v = await _view(app)
    out = SCHEMA["output"]
    row_schema = out["properties"]["models"]["additionalProperties"]
    with then("the view's keys, each model row's and each source state's are exactly the schema's required set"):
        check("view keys", sorted(v), sorted(out["required"]))
        check("model row keys", sorted({k for r in v["models"].values() for k in r}), sorted(row_schema["required"]))
        check("source state keys", sorted(v["sources"]["config"]), sorted(SCHEMA["$defs"]["source_state"]["required"]))
