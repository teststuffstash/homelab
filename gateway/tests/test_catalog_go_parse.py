"""GW-CATALOG-GO-PARSE — what the Go catalog's two reads say: the dialect, the page's limits and
constants, the config's cost rows, the view's shape; and the policy's plan (specs/endpoints/catalog.md
§The Go catalog).

World: policy-default (plan go) · the fake vendor (tests/_catalog_world.py): `catalog-ok` =
models.dev's `opencode-go` (five listed models + one deprecated row), `config-ok` = the console's
override-only answer, `docs-ok` = the vendor's Go page. T0 = the test clock. The tables are the
spec's, verbatim (the header is the parameter list).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from ._catalog_rows import num, verdict
from ._catalog_world import gw_client
from .conftest import POLICY_FIXTURE, attach_json, given, rule, when, world

pytestmark = rule("GW-CATALOG-GO-PARSE")

SCHEMA = json.loads((Path(__file__).resolve().parents[1] / "specs" / "endpoints" / "catalog.schema.json").read_text(encoding="utf-8"))


async def _view(app) -> dict:
    async with gw_client(app) as c:
        r = await c.get("/catalog/opencode")
    assert r.status_code == 200, r.text
    return r.json()


def _cost_cell(rows: list[dict]) -> str:
    def one(r: dict) -> str:
        return " / ".join(num(r[k]) if r[k] is not None else "—" for k in ("in", "out", "cache_read", "cache_write"))
    return "; ".join(one(r) if r["above_tokens"] == 0 else f"above {r['above_tokens']}: {one(r)}" for r in rows)


def _usd(v) -> str:
    return "unlimited" if v == "unlimited" else "none" if v is None else f"${num(v)}"


# ── The model's dialect ──────────────────────────────────────────────────────────────────────
DIALECT_ROWS = [
    pytest.param("catalog-ok", "claude-haiku-5-5", "anthropic", id="a provider override of @ai-sdk/anthropic is the anthropic dialect"),
    pytest.param("catalog-ok", "deepseek-v4.1-flash", "openai", id="a model with no provider override is the openai dialect"),
    pytest.param("catalog-google", "gemini-4-argon", "absent", id="an npm the parser does not know drops the row ⚖"),
]


@pytest.mark.parametrize(("catalog", "model", "expected_dialect"), DIALECT_ROWS, ids=[p.id for p in DIALECT_ROWS])
async def test_model_dialect(cworld, vendor, catalog, model, expected_dialect):
    world(upstream=f"{catalog} · config-ok")
    app = cworld.build()
    with given(f"catalog = {catalog}: models.dev's answer carries model = {model}'s provider override (or none)"):
        vendor.catalog = catalog
    with when(f"the config source refreshes; the config snapshot's row {model}"):
        assert await app.state.catalog.refresh_source("config") == "ok"
        row = app.state.catalog.snapshots["config"].body["models"].get(model)
        attach_json(f"snapshot row {model}", row)
    verdict(f"dialect = {expected_dialect}", expected_dialect={"expected": expected_dialect, "actual": row.get("dialect") if row else "absent"},
            catalog={"actual": catalog}, model={"actual": model})


# ── What the page says, per model ────────────────────────────────────────────────────────────
LIMIT_ROWS = [
    pytest.param("deepseek-v4.1-flash", "$80", "$160", "—", "0.3 / 1.2 / 0.006 / —", id="a plain row gives the monthly limit per plan"),
    pytest.param("step-5-preview", "$60", "$240", "4", "—", id="a promotion reads the current limit, not the struck one"),
    pytest.param("longcat-2.5-preview-free", "unlimited", "unlimited", "—", "—", id="Unlimited is unlimited"),
    pytest.param("claude-haiku-5-5", "$15", "$60", "—", "—", id="context-tier rows are one model with one limit"),
]


@pytest.mark.parametrize(("model", "expected_go", "expected_go_plus", "expected_bonus", "expected_peak"), LIMIT_ROWS,
                         ids=[p.id for p in LIMIT_ROWS])
async def test_page_per_model(cworld, vendor, model, expected_go, expected_go_plus, expected_bonus, expected_peak):
    world(upstream="catalog-ok · config-ok · docs-ok")
    app = cworld.build()
    with given(f"both sources refreshed once: catalog-ok + config-ok + docs-ok; the page's rows of model = {model}"):
        await app.state.catalog.refresh()
    with when(f"GET /catalog/opencode → models.{model} (plan go); the docs snapshot's go-plus row"):
        v = await _view(app)
        row = v["models"][model]
        plus = app.state.catalog.snapshots["docs"].body["plans"]["go-plus"].get(model)
        attach_json(f"models.{model}", row)
    peak = row["peak"]
    got_peak = " / ".join(num(peak[k]) if peak[k] is not None else "—" for k in ("in", "out", "cache_read", "cache_write")) if peak else "—"
    verdict(f"go = {expected_go} · go_plus = {expected_go_plus} · bonus = {expected_bonus} · peak = {expected_peak}",
            expected_go={"expected": expected_go, "actual": _usd(row["monthly_limit_usd"])},
            expected_go_plus={"expected": expected_go_plus, "actual": _usd(plus)},
            expected_bonus={"expected": expected_bonus, "actual": num(row["bonus"]) if row["bonus"] is not None else "—"},
            expected_peak={"expected": expected_peak, "actual": got_peak},
            model={"actual": model})


# ── The page's constants ─────────────────────────────────────────────────────────────────────
def _constant(v: dict, docs: dict, field: str) -> str:
    if field == "plan_fees":
        return " / ".join(f"{p} {num(x)}" for p, x in docs["plan_fees"].items())
    if field == "peak_hours_utc":
        return ", ".join(f"{a:02d}-{b:02d}" for a, b in v["peak_hours_utc"])
    if field == "peak_weekdays":
        return ", ".join(v["peak_weekdays"])
    if field == "window_shares":
        return " · ".join(f"{w} {num(x)}" for w, x in v["window_shares"].items())
    if field.startswith("models.") and field.endswith(".windows_usd"):
        model = field[len("models."):-len(".windows_usd")]
        return " · ".join(f"{w} {num(x)}" for w, x in v["models"][model]["windows_usd"].items())
    raise ValueError(field)


CONSTANT_ROWS = [
    pytest.param("docs-ok", "plan_fees", "go 10 / go-plus 40", id="the plan fees come from the page ⚖"),
    pytest.param("docs-ok", "peak_hours_utc", "01-04, 06-10", id="the peak hours come from the page ⚖"),
    pytest.param("docs-ok", "peak_weekdays", "mon, tue, wed, thu, fri", id="the peak weekdays come from the page"),
    pytest.param("docs-ok", "window_shares", "5h 0.2 · 7d 0.5 · 30d 1", id="the window shares come from the page ⚖"),
    pytest.param("docs-ok", "models.deepseek-v4.1-flash.windows_usd", "5h 16 · 7d 40 · 30d 80",
                 id="a model's windows are its monthly limit times the shares"),
]


@pytest.mark.parametrize(("docs", "field", "expected_value"), CONSTANT_ROWS, ids=[p.id for p in CONSTANT_ROWS])
async def test_page_constants(cworld, vendor, docs, field, expected_value):
    world(upstream=f"catalog-ok · config-ok · {docs}")
    app = cworld.build()
    with given(f"docs = {docs}: the vendor's Go page; both sources refresh"):
        vendor.docs = docs
        await app.state.catalog.refresh()
    with when(f"GET /catalog/opencode → field = {field}"):
        v = await _view(app)
        snap = app.state.catalog.snapshots["docs"].body
        got = _constant(v, snap, field)
        attach_json(field, got)
    verdict(f"{field} = {expected_value}", expected_value={"expected": expected_value, "actual": got}, docs={"actual": docs}, field={"actual": field})


# ── The model's cost rows ────────────────────────────────────────────────────────────────────
COST_ROWS = [
    pytest.param("catalog-ok", "claude-haiku-5-5", "0.1 / 0.5 / 0.01 / 0.125; above 100000: 0.5 / 2.5 / 0.05 / 0.625",
                 id="the config's prices are the model's cost rows"),
]


@pytest.mark.parametrize(("catalog", "model", "expected_cost"), COST_ROWS, ids=[p.id for p in COST_ROWS])
async def test_cost_rows(cworld, vendor, catalog, model, expected_cost):
    world(upstream=f"{catalog} · config-ok")
    app = cworld.build()
    with given(f"catalog = {catalog}: models.dev's `cost` and its `tiers[]` for model = {model}"):
        vendor.catalog = catalog
    with when(f"the config source refreshes; GET /catalog/opencode → models.{model}.cost"):
        await app.state.catalog.refresh_source("config")
        rows = (await _view(app))["models"][model]["cost"]
        attach_json(f"models.{model}.cost", rows)
    verdict(f"cost = {expected_cost}", expected_cost={"expected": expected_cost, "actual": _cost_cell(rows)},
            catalog={"actual": catalog}, model={"actual": model})


# ── A model the page tabulates but the config does not list ─────────────────────────────────
UNLISTED_ROWS = [
    pytest.param("catalog-trimmed", "docs-ok", "step-5-preview", "false", "$60",
                 id="a model the page tabulates but the config does not list is shown unlisted"),
]


@pytest.mark.parametrize(("catalog", "docs", "model", "expected_listed", "expected_monthly_limit_usd"), UNLISTED_ROWS,
                         ids=[p.id for p in UNLISTED_ROWS])
async def test_tabulated_but_unlisted(cworld, vendor, catalog, docs, model, expected_listed, expected_monthly_limit_usd):
    world(upstream=f"{catalog} · config-ok · {docs}")
    app = cworld.build()
    with given(f"catalog = {catalog} (no {model} row) · docs = {docs} (its plan rows tabulate {model})"):
        vendor.catalog, vendor.docs = catalog, docs
    with when(f"both sources refresh; GET /catalog/opencode → models.{model}"):
        await app.state.catalog.refresh()
        row = (await _view(app))["models"][model]
        attach_json(f"models.{model}", row)
    verdict(f"listed = {expected_listed} · monthly_limit_usd = {expected_monthly_limit_usd}",
            expected_listed={"expected": expected_listed, "actual": str(row["listed"]).lower()},
            expected_monthly_limit_usd={"expected": expected_monthly_limit_usd, "actual": _usd(row["monthly_limit_usd"])},
            catalog={"actual": catalog}, docs={"actual": docs}, model={"actual": model})


# ── The view's shape ─────────────────────────────────────────────────────────────────────────
SHAPE_ROWS = [pytest.param("catalog-ok", "docs-ok", "exactly the schema's required keys", id="the view's shape is the schema's")]


@pytest.mark.parametrize(("catalog", "docs", "expected_shape"), SHAPE_ROWS, ids=[p.id for p in SHAPE_ROWS])
async def test_view_shape(cworld, vendor, catalog, docs, expected_shape):
    world(upstream=f"{catalog} · config-ok · {docs}")
    app = cworld.build()
    with given(f"catalog = {catalog} · docs = {docs}; catalog.schema.json `output`, its model row and `$defs.source_state`"):
        vendor.catalog, vendor.docs = catalog, docs
    with when("both sources refresh; GET /catalog/opencode"):
        await app.state.catalog.refresh()
        v = await _view(app)
    out = SCHEMA["output"]
    want = {"view": sorted(out["required"]), "model row": sorted(out["properties"]["models"]["additionalProperties"]["required"]),
            "source state": sorted(SCHEMA["$defs"]["source_state"]["required"])}
    got = {"view": sorted(v), "model row": sorted({k for r in v["models"].values() for k in r}), "source state": sorted(v["sources"]["config"])}
    diff = {k: {"schema": want[k], "view": got[k]} for k in want if want[k] != got[k]}
    verdict(f"shape = {expected_shape}", expected_shape={"expected": expected_shape, "actual": expected_shape if not diff else f"differs: {diff}"},
            catalog={"actual": catalog}, docs={"actual": docs}, keys={"actual": got})


# ── The plan ─────────────────────────────────────────────────────────────────────────────────
PLAN_ROWS = [
    pytest.param("opencode", "go", "loads; the view's plan is go", id="the declared plan picks the limits' tab"),
    pytest.param("opencode", "absent", "refused, naming rails.opencode.plan", id="no plan refuses the load"),
    pytest.param("opencode", "pro", "refused, naming rails.opencode.plan", id="an unknown plan refuses the load"),
    pytest.param("openrouter", "go", "refused, naming rails.openrouter.plan", id="a plan on another rail refuses the load"),
]


def _load(doc: dict) -> tuple[object | None, str | None]:
    from agent_gateway.config import Policy, PolicyError

    try:
        return Policy.from_dict(doc), None
    except PolicyError as e:
        return None, str(e)


def _load_cell(error: str | None, expected_load: str, loads_text: str) -> str:
    """The `load?` cell the system produced: `refused, naming <x>` holds when the error names x."""
    if error is None:
        return loads_text
    if expected_load.startswith("refused, naming ") and expected_load[len("refused, naming "):] in error:
        return expected_load
    return f"refused: {error}"


@pytest.mark.parametrize(("rail", "plan", "expected_load"), PLAN_ROWS, ids=[p.id for p in PLAN_ROWS])
async def test_plan(cworld, rail, plan, expected_load):
    world()
    doc = json.loads(POLICY_FIXTURE.read_text(encoding="utf-8"))
    with given(f"policy-default with rails.{rail}.plan = {plan} (rail = {rail} · plan = {plan})"):
        if plan == "absent":
            doc["rails"][rail].pop("plan")
        else:
            doc["rails"][rail]["plan"] = plan
    with when("the policy loads"):
        loaded, error = _load(doc)
        attach_json("load result", {"loaded": loaded is not None, "error": error})
        view_plan = None
        if loaded is not None:
            cworld.policy = loaded
            view_plan = (await _view(cworld.build()))["plan"]
    verdict(f"load = {expected_load}", expected_load={"expected": expected_load, "actual": _load_cell(error, expected_load, f"loads; the view's plan is {view_plan}")},
            rail={"actual": rail}, plan={"actual": plan})


# ── What the policy no longer holds (ruling 5) ─────────────────────────────────────────────────
RULES_ONLY_ROWS = [
    pytest.param("window_draw.prices", "the old deepseek-v4.1-flash price row", "refused, naming prices", id="a price row in the policy refuses the load"),
    pytest.param("window_draw.fallback", "9.00 / 9.00", "refused, naming fallback", id="a fallback price refuses the load"),
    pytest.param("window_draw.windows.5h.budget_usd", "12", "refused, naming budget_usd", id="a window budget refuses the load"),
    pytest.param("window_draw.windows.1d", "threshold 0.8, anchor weekly, weekday mon", "refused, naming windows.1d",
                 id="a window the vendor gives no share refuses the load"),
    pytest.param("latch_scope", "rail", "refused, naming latch_scope", id="an unknown latch scope refuses the load"),
]
VALUES = {
    "the old deepseek-v4.1-flash price row": {"opencode-go/deepseek-v4.1-flash": {"in": 0.15, "out": 0.60, "cache_read": 0.003, "cache_write": None}},
    "9.00 / 9.00": {"in": 9.0, "out": 9.0, "cache_read": 0, "cache_write": 0},
    "12": 12.0,
    "threshold 0.8, anchor weekly, weekday mon": {"threshold": 0.8, "anchor": "weekly", "weekday": "mon"},
    "rail": "rail",
}


@pytest.mark.parametrize(("path", "value", "expected_load"), RULES_ONLY_ROWS, ids=[p.id for p in RULES_ONLY_ROWS])
def test_rules_only(path, value, expected_load):
    world()
    doc = json.loads(POLICY_FIXTURE.read_text(encoding="utf-8"))
    with given(f"policy-default with rails.opencode.admission.{path} = {value} (path = {path} · value = {value})"):
        node = doc["rails"]["opencode"]["admission"]
        *parents, leaf = path.split(".")
        for k in parents:
            node = node[k]
        node[leaf] = VALUES[value]
        attach_json("rails.opencode.admission", node)
    with when("the policy loads"):
        _, error = _load(doc)
        attach_json("load result", {"error": error})
    verdict(f"load = {expected_load}", expected_load={"expected": expected_load, "actual": _load_cell(error, expected_load, "loads")},
            path={"actual": path}, value={"actual": value})
