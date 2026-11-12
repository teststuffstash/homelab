"""GW-CATALOG-GO — the Go catalog's refresh: what a refresh keeps, what a fetch sends, what a restart
serves, what /metrics says (specs/endpoints/catalog.md §The Go catalog).

World: policy-default (plan go; Go ids deepseek-v4.1-flash, claude-haiku-5-5) · the fake vendor
(tests/_catalog_world.py): the `catalog` knob is what models.dev answers, the `config` knob what the
console answers — together the `config` source — and the `docs` knob the Go page. T0 = the test clock
(2027-01-15T08:00:00Z); every refresh runs at T0 unless the row's `at` says otherwise. The tables are
the spec's, verbatim (the header is the parameter list).
"""

from __future__ import annotations

import logging
import re
import uuid

import pytest

from agent_gateway import __version__

from ._catalog_rows import T0, at_iso, at_offset, iso, joined, listed, num, verdict, verdict_block
from ._catalog_world import catalog_doc, config_doc, gw_client
from .conftest import GO_KEY, attach_json, given, quiet, rule, when, world

pytestmark = rule("GW-CATALOG-GO")

UA_CELL = "agent-gateway/<version> (go-catalog)"
UA = f"agent-gateway/{__version__} (go-catalog)"
LISTED_FIVE = ["claude-haiku-5-5", "deepseek-v4-pro", "deepseek-v4.1-flash", "longcat-2.5-preview-free", "step-5-preview"]
LAST_GOOD = "5, fetched T0"


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


def _listed_ids(cell: str) -> list[str]:
    """The `listed?` legend: `the five` = the fixture's five listed ids; `the five minus X`; `the five + X`."""
    c = cell.strip()
    if c == "the five":
        return LISTED_FIVE
    if c.startswith("the five minus "):
        return [m for m in LISTED_FIVE if m != c[len("the five minus "):]]
    if c.startswith("the five + "):
        return sorted([*LISTED_FIVE, c[len("the five + "):]])
    return listed(c)


def _ids_the_reads_carry(catalog: str, config: str) -> set[str]:
    """Every model id models.dev's answer or the console's overrides name (the `unlisted?` base)."""
    ids: set[str] = set()
    ids.update(catalog_doc(catalog).get("opencode-go", {}).get("models", {}))
    ids.update(config_doc(config).get("providers", {}).get("opencode-go", {}).get("models", {}))
    return ids


def _cost_cell(rows: list[dict]) -> str:
    """A model's cost rows as the page writes them: `in / out / cache_read / cache_write; above N: …`."""
    def one(r: dict) -> str:
        return " / ".join(num(r[k]) if r[k] is not None else "—" for k in ("in", "out", "cache_read", "cache_write"))
    return "; ".join(one(r) if r["above_tokens"] == 0 else f"above {r['above_tokens']}: {one(r)}" for r in rows)


# ── What a refresh keeps: the `config` source (the catalog read + the console overlay) ────────
# (description, last_good, catalog, config, at, outcome?, fetched_at?, models?, listed?, unlisted?)
CONFIG_ROWS = [
    # a good fetch lands
    pytest.param("none", "catalog-ok", "config-ok", "T0", "ok", "T0", 5, "the five", "step-5-preview-free",
                 id="a first good fetch becomes the snapshot"),
    pytest.param(LAST_GOOD, "catalog-ok", "config-ok", "T0", "ok", "T0", 5, "the five", "step-5-preview-free",
                 id="an override-only console answer lists the catalog as is ⚖"),
    pytest.param(LAST_GOOD, "catalog-ok", "config-ok", "T0 + 21600 s", "ok", "T0 + 21600 s", 5, "the five", "step-5-preview-free",
                 id="a later good fetch replaces it"),
    # which rows the merged listing holds
    pytest.param("none", "catalog-ok", "config-ok", "T0", "ok", "T0", 5, "the five", "step-5-preview-free",
                 id="a deprecated catalog row is not listed"),
    pytest.param("none", "catalog-ok", "config-disables", "T0", "ok", "T0", 4, "the five minus deepseek-v4-pro",
                 "deepseek-v4-pro, step-5-preview-free", id="a disabled override unlists the row"),
    pytest.param("none", "catalog-ok", "config-adds", "T0", "ok", "T0", 6, "the five + deepseek-v4-flash", "step-5-preview-free",
                 id="a console-only row with a cost and both limits is listed ⚖"),
    pytest.param("none", "catalog-ok", "config-adds-bare", "T0", "ok", "T0", 5, "the five", "deepseek-v4-flash, step-5-preview-free",
                 id="a console-only row without them lists nothing ⚖"),
    pytest.param("none", "catalog-google", "config-ok", "T0", "ok", "T0", 5, "the five", "gemini-4-argon, step-5-preview-free",
                 id="the unknown dialect drops that model, the refresh keeps the others ⚖"),
    pytest.param("none", "catalog-google", "config-adds-gemini", "T0", "ok", "T0", 5, "the five", "gemini-4-argon, step-5-preview-free",
                 id="a dropped id is not re-listed by the console overlay ⚖"),
    # a failed read keeps the last good
    pytest.param(LAST_GOOD, "catalog-503", "config-ok", "T0", "fetch-failed", "T0", 5, "the five", "step-5-preview-free",
                 id="an upstream error on the catalog read keeps the last good"),
    pytest.param(LAST_GOOD, "catalog-ok", "config-503", "T0", "fetch-failed", "T0", 5, "the five", "step-5-preview-free",
                 id="an upstream error on the console read keeps the last good"),
    pytest.param(LAST_GOOD, "catalog-down", "config-ok", "T0", "fetch-failed", "T0", 5, "the five", "step-5-preview-free",
                 id="an unreachable catalog host keeps the last good"),
    pytest.param(LAST_GOOD, "catalog-ok", "config-down", "T0", "fetch-failed", "T0", 5, "the five", "step-5-preview-free",
                 id="an unreachable console keeps the last good"),
    # a shape the parser does not know
    pytest.param(LAST_GOOD, "catalog-malformed", "config-ok", "T0", "parse-failed", "T0", 5, "the five", "step-5-preview-free",
                 id="a catalog row without its cost is a parse failure"),
    pytest.param(LAST_GOOD, "catalog-legacy-tier", "config-ok", "T0", "parse-failed", "T0", 5, "the five", "step-5-preview-free",
                 id="a legacy context_over_200k row with no tiers is a parse failure ⚖"),
    pytest.param(LAST_GOOD, "catalog-ok", "config-malformed", "T0", "parse-failed", "T0", 5, "the five", "step-5-preview-free",
                 id="an override whose cost is not a cost is a parse failure"),
    pytest.param(LAST_GOOD, "catalog-no-provider", "config-ok", "T0", "parse-failed", "T0", 5, "the five", "none",
                 id="a catalog without the Go provider is a parse failure"),
    pytest.param(LAST_GOOD, "catalog-ok", "config-no-provider", "T0", "parse-failed", "T0", 5, "the five", "step-5-preview-free",
                 id="a console answer without the Go provider is a parse failure"),
    # the half rule
    pytest.param(LAST_GOOD, "catalog-shrunk", "config-ok", "T0", "implausible", "T0", 5, "the five", "none",
                 id="a drop below half the models is implausible ⚖"),
    pytest.param(LAST_GOOD, "catalog-trimmed", "config-ok", "T0", "ok", "T0", 3, "claude-haiku-5-5, deepseek-v4-pro, deepseek-v4.1-flash",
                 "none", id="a drop to half or more is taken ⚖"),
    pytest.param("none", "catalog-empty", "config-ok", "T0", "implausible", "none", 0, "none", "none",
                 id="zero models is implausible with no last good"),
]


@pytest.mark.parametrize(("last_good", "catalog", "config", "at", "expected_outcome", "expected_fetched_at", "expected_models",
                          "expected_listed", "expected_unlisted"), CONFIG_ROWS, ids=[p.id for p in CONFIG_ROWS])
async def test_config_refresh(cworld, vendor, vendor_transport, clock, last_good, catalog, config, at, expected_outcome,
                              expected_fetched_at, expected_models, expected_listed, expected_unlisted):
    world(upstream=f"{catalog} · {config}")
    app = cworld.build()
    with given(f"last_good = {last_good}"):
        if last_good != "none":
            vendor.catalog, vendor.config = "catalog-ok", "config-ok"
            with quiet():  # the arrange's two vendor exchanges fold into one summary (ATTACH_BULK)
                assert await app.state.catalog.refresh_source("config") == "ok"
            attach_json("arranged: one good config refresh (catalog-ok · config-ok) at T0", {"last_good": last_good, "outcome": "ok"})
    clock.t = T0 + at_offset(at)
    with given(f"catalog = {catalog} (models.dev) · config = {config} (the console) · at = {at}"):
        vendor.catalog, vendor.config = catalog, config
        for read, b in (("catalog", catalog), ("config", config)):
            if b.endswith("-down"):
                vendor_transport.down.add(read)
    with when(f"the config source refreshes at {at}"):
        got = await app.state.catalog.refresh_source("config")
        v = await _view(app)
    cfg = v["sources"]["config"]
    got_listed = sorted(m for m, r in v["models"].items() if r["listed"])
    got_unlisted = joined(sorted(_ids_the_reads_carry(catalog, config) - set(got_listed))) if got_listed else "none"
    verdict(f"outcome = {expected_outcome} · fetched_at = {expected_fetched_at} · models = {expected_models} · listed = {expected_listed} · unlisted = {expected_unlisted}",
            expected_outcome={"expected": expected_outcome, "actual": got},
            expected_fetched_at={"expected": at_iso(expected_fetched_at), "actual": cfg["fetched_at"]},
            expected_models={"expected": expected_models, "actual": cfg["models"]},
            expected_listed={"expected": _listed_ids(expected_listed), "actual": got_listed},
            expected_unlisted={"expected": expected_unlisted, "actual": got_unlisted},
            last_good={"actual": last_good}, catalog={"actual": catalog}, config={"actual": config}, at={"actual": at},
            last_outcome={"actual": cfg["last_outcome"]})
    if catalog == "catalog-google":
        with verdict_block("the rows that landed keep their dialects (anthropic for claude-haiku-5-5, openai for the rest)"):
            body = app.state.catalog.snapshots["config"].body["models"]
            assert [body[m].get("dialect") for m in sorted(LISTED_FIVE)] == ["anthropic", "openai", "openai", "openai", "openai"]


# ── An override's fields win ────────────────────────────────────────────────────────────────
FIELD_ROWS = [
    pytest.param("config-reprices", "claude-haiku-5-5", "claude-haiku", "true",
                 "0.2 / 1 / 0.02 / 0.25; above 200000: 1 / 5 / 0.1 / 1.25", 200000, 128000,
                 id="a cost or limit override wins"),
    pytest.param("config-adds", "deepseek-v4-flash", "deepseek-flash", "true", "0.14 / 0.28 / 0.028 / —", 1000000, 384000,
                 id="a console-only row's fields are the override's ⚖"),
]


@pytest.mark.parametrize(("config", "model", "expected_family", "expected_tools", "expected_cost", "expected_context", "expected_output"),
                         FIELD_ROWS, ids=[p.id for p in FIELD_ROWS])
async def test_override_fields(cworld, vendor, config, model, expected_family, expected_tools, expected_cost, expected_context,
                               expected_output):
    world(upstream=f"catalog-ok · {config}")
    app = cworld.build()
    with given(f"config = {config}: the console's override on model = {model}; models.dev answers catalog-ok"):
        vendor.config = config
    with when(f"the config source refreshes; GET /catalog/opencode → models.{model}"):
        assert await app.state.catalog.refresh_source("config") == "ok"
        row = (await _view(app))["models"][model]
    verdict(f"family = {expected_family} · tools = {expected_tools} · cost = {expected_cost} · context = {expected_context} · output = {expected_output}",
            expected_family={"expected": expected_family, "actual": row["family"]},
            expected_tools={"expected": expected_tools, "actual": str(row["tools"]).lower()},
            expected_cost={"expected": expected_cost, "actual": _cost_cell(row["cost"])},
            expected_context={"expected": expected_context, "actual": row["context"]},
            expected_output={"expected": expected_output, "actual": row["output"]},
            config={"actual": config}, model={"actual": model})


# ── What a refresh keeps: the `docs` source ──────────────────────────────────────────────────
GO_TEAMS = "**Go Teams**"
# (description, last_good, docs, outcome?, models?, promotion?, limits?, plan_fees?, passed_over?)
DOCS_ROWS = [
    pytest.param("none", "docs-ok", "ok", 5, "none", "none", "go 10 / go-plus 40", "none", id="the page parses"),
    pytest.param("5", "docs-404", "fetch-failed", 5, "none", "none", "go 10 / go-plus 40", "none",
                 id="a 404 keeps the last good — the page moved"),
    pytest.param("5", "docs-shrunk", "implausible", 5, "none", "none", "go 10 / go-plus 40", "none",
                 id="a drop below half the models is implausible"),
    pytest.param("5", "docs-unknown-model", "parse-failed", 5, "none", "none", "go 10 / go-plus 40", "none",
                 id="a plan row naming a model the Endpoints table lacks is a parse failure"),
    pytest.param("5", "docs-short-endpoint-row", "parse-failed", 5, "none", "none", "go 10 / go-plus 40", "none",
                 id="an Endpoints row with one cell is a parse failure"),
    pytest.param("5", "docs-header-drift", "parse-failed", 5, "none", "none", "go 10 / go-plus 40", "none",
                 id="a renamed limit column is a parse failure"),
    pytest.param("5", "docs-no-peak-hours", "parse-failed", 5, "none", "none", "go 10 / go-plus 40", "none",
                 id="peak rows without the peak-hours sentence are a parse failure"),
    pytest.param("5", "docs-no-shares", "parse-failed", 5, "none", "none", "go 10 / go-plus 40", "none",
                 id="no share sentence is a parse failure ⚖"),
    pytest.param("5", "docs-no-plan-table", "parse-failed", 5, "none", "none", "go 10 / go-plus 40", "none",
                 id="no plan table is a parse failure ⚖"),
    pytest.param("5", "docs-no-go-plus", "parse-failed", 5, "none", "none", "go 10 / go-plus 40", "none",
                 id="a Plan table without the Go Plus row is a parse failure"),
    pytest.param("5", "docs-promo", "ok", 6, "gemini-4-argon ×0.5", "gemini-4-argon $30 / $120", "go 10 / go-plus 40", "none",
                 id="a plan row's (50% off) suffix is a promotion multiplier, the name is the Endpoints row ⚖"),
    pytest.param("5", "docs-teams", "ok", 5, "none", "none", "go 10 / go-plus 40", GO_TEAMS,
                 id="a Plan-table row naming a plan the leg does not model is passed over ⚖"),
]


def _docs_cells(docs_body: dict | None) -> dict[str, str]:
    if not docs_body:
        return {"promotion": "none", "limits": "none", "plan_fees": "none"}
    promo = docs_body.get("promotion") or {}
    fees = docs_body.get("plan_fees")
    return {"promotion": ", ".join(f"{m} ×{num(x)}" for m, x in sorted(promo.items())) or "none",
            "limits": ", ".join(f"{m} ${num(docs_body['plans']['go'][m])} / ${num(docs_body['plans']['go-plus'][m])}" for m in sorted(promo)) or "none",
            "plan_fees": " / ".join(f"{p} {num(x)}" for p, x in fees.items()) if fees else "none"}


@pytest.mark.parametrize(("last_good", "docs", "expected_outcome", "expected_models", "expected_promotion", "expected_limits",
                          "expected_plan_fees", "expected_passed_over"), DOCS_ROWS, ids=[p.id for p in DOCS_ROWS])
async def test_docs_refresh(cworld, vendor, clock, caplog, last_good, docs, expected_outcome, expected_models, expected_promotion,
                            expected_limits, expected_plan_fees, expected_passed_over):
    caplog.set_level(logging.INFO, logger="gateway.catalog")
    world(upstream=docs)
    app = cworld.build()
    with given(f"last_good = {last_good} (docs-ok at T0)" if last_good != "none" else "last_good = none"):
        if last_good != "none":
            vendor.docs = "docs-ok"
            assert await app.state.catalog.refresh_source("docs") == "ok"
    clock.advance(60)
    caplog.clear()
    with given(f"docs = {docs}: the fake vendor's Go page"):
        vendor.docs = docs
    with when(f"the docs source refreshes at T0 + 60 s (docs = {docs})"):
        got = await app.state.catalog.refresh_source("docs")
        v = await _view(app)
        lines = [r.getMessage() for r in caplog.records if r.name == "gateway.catalog"]
        snap = app.state.catalog.snapshots.get("docs")
        attach_json("gateway.catalog lines", lines)
    cells = _docs_cells(snap.body if snap else None)
    passed_over = [m.group(1) for m in (re.match(r"^catalog: docs plan row passed over — (.+?) \(", x) for x in lines) if m]
    expected_at = iso(T0 + 60) if expected_outcome == "ok" else (iso(T0) if last_good != "none" else None)
    verdict(f"outcome = {expected_outcome} · models = {expected_models} · promotion = {expected_promotion} · limits = {expected_limits} · "
            f"plan_fees = {expected_plan_fees} · passed_over = {expected_passed_over}",
            expected_outcome={"expected": expected_outcome, "actual": got},
            expected_models={"expected": expected_models, "actual": v["sources"]["docs"]["models"]},
            expected_promotion={"expected": expected_promotion, "actual": cells["promotion"]},
            expected_limits={"expected": expected_limits, "actual": cells["limits"]},
            expected_plan_fees={"expected": expected_plan_fees, "actual": cells["plan_fees"]},
            expected_passed_over={"expected": expected_passed_over, "actual": joined(passed_over)},
            fetched_at={"expected": expected_at, "actual": v["sources"]["docs"]["fetched_at"]},
            last_good={"actual": last_good}, docs={"actual": docs})
    if docs == "docs-promo":
        with verdict_block("every other model's plan rows are unchanged; the bonus map stays the Nx multipliers only"):
            body = snap.body
            assert sorted(set(body["plans"]["go"]) - {"gemini-4-argon"}) == sorted(LISTED_FIVE)
            assert sorted(set(body["plans"]["go-plus"]) - {"gemini-4-argon"}) == sorted(LISTED_FIVE)
            assert body["bonus"].get("gemini-4-argon") is None


# ── What a fetch sends ───────────────────────────────────────────────────────────────────────
SEND_ROWS = [
    pytest.param("config", "Bearer <the Go key>", UA_CELL, "a UUID, new on every fetch", id="the console read carries the key and a client identity"),
    pytest.param("catalog", "absent", UA_CELL, "absent", id="the catalog read carries no credential"),
    pytest.param("docs", "absent", UA_CELL, "absent", id="the docs fetch carries no credential"),
]


@pytest.mark.parametrize(("read", "expected_authorization", "expected_user_agent", "expected_x_opencode_session"), SEND_ROWS,
                         ids=[p.id for p in SEND_ROWS])
async def test_fetch_sends(cworld, vendor, read, expected_authorization, expected_user_agent, expected_x_opencode_session):
    world(upstream="catalog-ok · config-ok · docs-ok")
    app = cworld.build()
    source = "docs" if read == "docs" else "config"
    with when(f"the {source} source refreshes twice; the vendor's journal of the {read} read"):
        await app.state.catalog.refresh_source(source)
        await app.state.catalog.refresh_source(source)
        calls = [c for c in vendor.calls if c["source"] == read]
        attach_json(f"the {read} read's request headers (the key redacted)", [c["headers"] for c in calls])
    assert len(calls) == 2, calls
    auths = [c["headers"].get("authorization") for c in calls]
    uas = {c["headers"].get("user-agent") for c in calls}
    sessions = [c["headers"].get("x-opencode-session") for c in calls]
    got_auth = "Bearer <the Go key>" if auths == [f"Bearer {GO_KEY}"] * 2 else "absent" if auths == [None, None] else repr(auths)
    got_ua = uas.pop().replace(__version__, "<version>") if len(uas) == 1 else repr(uas)
    if sessions == [None, None]:
        got_session = "absent"
    else:
        try:
            got_session = "a UUID, new on every fetch" if all(str(uuid.UUID(s)) == s for s in sessions) and sessions[0] != sessions[1] else repr(sessions)
        except ValueError:
            got_session = repr(sessions)
    verdict(f"authorization = {expected_authorization} · user_agent = {expected_user_agent} · x_opencode_session = {expected_x_opencode_session}",
            expected_authorization={"expected": expected_authorization, "actual": got_auth},
            expected_user_agent={"expected": expected_user_agent, "actual": got_ua},
            expected_x_opencode_session={"expected": expected_x_opencode_session, "actual": got_session},
            read={"actual": read})


KEY_ROWS = [
    pytest.param("config-ok", "unset", "fetch-failed", 0, 0, id="no key, no config fetch"),
    pytest.param("config-401-echo", "set", "fetch-failed", 2, 0, id="the key never reaches a log line"),
]


@pytest.mark.parametrize(("config", "key", "expected_outcome", "expected_requests", "expected_log_lines_with_key"), KEY_ROWS,
                         ids=[p.id for p in KEY_ROWS])
async def test_key_handling(cworld, vendor, caplog, config, key, expected_outcome, expected_requests, expected_log_lines_with_key):
    from agent_gateway.logging import RedactingFormatter

    caplog.set_level(logging.DEBUG, logger="gateway.catalog")
    world(upstream=f"catalog-ok · {config}", note=f"OPENCODE_GO_API_KEY {key}")
    app = cworld.build(key=GO_KEY if key == "set" else None)
    with given(f"config = {config} · key = {key}"):
        vendor.config = config
    with when(f"the config source refreshes (key = {key})"):
        got = await app.state.catalog.refresh_source("config")
        fmt = RedactingFormatter("%(message)s")
        lines = [fmt.format(r) for r in caplog.records if r.name == "gateway.catalog"]
        raw = [r.getMessage() for r in caplog.records if r.name == "gateway.catalog"]
        attach_json("gateway.catalog lines (formatted)", lines)
    verdict(f"outcome = {expected_outcome} · requests = {expected_requests} · log_lines_with_key = {expected_log_lines_with_key}",
            expected_outcome={"expected": expected_outcome, "actual": got},
            expected_requests={"expected": expected_requests, "actual": len(vendor.calls)},
            expected_log_lines_with_key={"expected": expected_log_lines_with_key, "actual": len([x for x in lines + raw if GO_KEY in x])},
            config={"actual": config}, key={"actual": key})


# ── Kept across a restart ────────────────────────────────────────────────────────────────────
BOTH = "both snapshots at T0"
CORRUPT = "a config row that is not JSON, no docs row"
# (description, stored, restart_at, age_s?, models?, startup_delay?, retry_after_s?)
RESTART_ROWS = [
    pytest.param(BOTH, "T0 + 600 s", "600 · 600", 5, 21000, 21000, id="a PVC store keeps the snapshot"),
    pytest.param(CORRUPT, "T0", "none · none", 0, 0, 60, id="a corrupt stored snapshot is ignored ⚖"),
    pytest.param(BOTH, "T0 + 3600 s", "3600 · 3600", 5, 18000, 18000, id="a restart inside the interval refreshes nothing at start ⚖"),
    pytest.param(BOTH, "T0 + 21600 s", "21600 · 21600", 5, 0, 60, id="a restart after the interval refreshes at start"),
]


@pytest.mark.parametrize(("stored", "restart_at", "expected_age_s", "expected_models", "expected_startup_delay", "expected_retry_after_s"),
                         RESTART_ROWS, ids=[p.id for p in RESTART_ROWS])
async def test_restart(cworld, vendor, clock, stored, restart_at, expected_age_s, expected_models, expected_startup_delay,
                       expected_retry_after_s):
    world(upstream="catalog-ok · docs-ok", note="refresh_s 21600")
    with given(f"stored = {stored}"):
        if stored == BOTH:
            first = cworld.build()
            with quiet():  # the arrange's three vendor exchanges fold into one summary (ATTACH_BULK)
                await first.state.catalog.refresh()
            attach_json("arranged: gateway #1 refreshed both sources at T0 (catalog-ok · config-ok · docs-ok)", {"fetched_at": iso(T0)})
        else:
            from agent_gateway.store import Store

            s = Store(cworld.db)
            with s._lock:
                s._db.execute("INSERT INTO catalog_snapshots (source, fetched_at, body) VALUES ('config', ?, '{not json')", (T0,))
            s.close()
    clock.t = T0 + at_offset(restart_at)
    with when(f"gateway #2 starts on the same DB at restart_at = {restart_at}; GET /catalog/opencode before any refresh"):
        second = cworld.build()
        delay = second.state.catalog.startup_delay(clock())
        retry = second.state.catalog.retry_at(clock(), 60) - clock()
        v = await _view(second)
        attach_json("startup_delay · retry_at − now", {"startup_delay_s": delay, "retry_after_s": retry})
    ages = " · ".join(num(v["sources"][s]["age_s"]) for s in ("config", "docs"))
    verdict(f"age_s = {expected_age_s} · models = {expected_models} · startup_delay = {expected_startup_delay} · retry_after_s = {expected_retry_after_s}",
            expected_age_s={"expected": expected_age_s, "actual": ages},
            expected_models={"expected": expected_models, "actual": v["sources"]["config"]["models"]},
            expected_startup_delay={"expected": expected_startup_delay, "actual": delay},
            expected_retry_after_s={"expected": expected_retry_after_s, "actual": retry},
            last_attempt_at={"expected": None, "actual": v["sources"]["config"]["last_attempt_at"]},
            stored={"actual": stored}, restart_at={"actual": restart_at})


# ── What /metrics says ───────────────────────────────────────────────────────────────────────
AGE = 'gateway_go_catalog_age_seconds{source="config"}'
METRIC_ROWS = [
    pytest.param("catalog-ok", "T0 + 600 s", AGE, "600", id="age is seconds since the last good fetch"),
    pytest.param("none", "T0", AGE, "absent", id="no snapshot, no age"),
    pytest.param("catalog-ok, then catalog-shrunk", "T0", 'gateway_go_catalog_models{source="config"}', "5",
                 id="the model count of the last good snapshot"),
    pytest.param("catalog-ok, then catalog-malformed", "T0",
                 'gateway_go_catalog_refresh_total{source="config",outcome="ok"} / gateway_go_catalog_refresh_total{source="config",outcome="parse-failed"}',
                 "1 / 1", id="every refresh is counted by outcome"),
    pytest.param("catalog-ok, then catalog-malformed", "T0",
                 'gateway_go_catalog_last_outcome{source="config",outcome="parse-failed"} / gateway_go_catalog_last_outcome{source="config",outcome="ok"}',
                 "1 / 0", id="the last outcome is 1, the others 0"),
    pytest.param("catalog-google", "T0",
                 'gateway_go_catalog_models_dropped_total{source="config",reason="unknown-dialect"} / gateway_go_catalog_models_dropped_total{source="docs",reason="unknown-dialect"}',
                 "1 / 0", id="a model the source cannot speak is counted dropped ⚖"),
]


@pytest.mark.parametrize(("refreshes", "read_at", "series", "expected_value"), METRIC_ROWS, ids=[p.id for p in METRIC_ROWS])
async def test_metrics(cworld, vendor, clock, refreshes, read_at, series, expected_value):
    knobs = listed(refreshes.replace(", then ", ", "))
    world(upstream=" · ".join(knobs) if knobs else None)
    app = cworld.build()
    with given(f"refreshes = {refreshes}: the config source refreshes once per models.dev answer, in order"):
        for b in knobs:
            vendor.catalog = b
            with quiet():
                await app.state.catalog.refresh_source("config")
        attach_json("arranged refreshes", knobs)
    clock.t = T0 + at_offset(read_at)
    with when(f"GET /metrics at read_at = {read_at}"):
        text = await _metrics(app)
        names = [s.strip() for s in series.split(" / ")]
        attach_json("sampled series", [x for x in text.splitlines() if any(x.startswith(n.split("{")[0]) for n in names)])
    got = " / ".join("absent" if (val := _value(text, n)) is None else num(val) for n in names)
    verdict(f"{series} = {expected_value}", expected_value={"expected": expected_value, "actual": got},
            refreshes={"actual": refreshes}, read_at={"actual": read_at}, series={"actual": series})


MISSING_ROWS = [
    pytest.param("none", "config", "catalog-ok", 0, "none", id="every policy Go model listed: none missing"),
    pytest.param("none", "config", "catalog-shrunk", 1, "claude-haiku-5-5", id="policy Go models the config does not list are counted"),
    pytest.param("none", "docs", "docs-shrunk", 1, "claude-haiku-5-5", id="policy Go models without a limit row under the plan are counted"),
]


@pytest.mark.parametrize(("last_good", "source", "behaviour", "expected_missing", "expected_uncovered"), MISSING_ROWS, ids=[p.id for p in MISSING_ROWS])
async def test_policy_models_missing(cworld, vendor, last_good, source, behaviour, expected_missing, expected_uncovered):
    world(upstream=behaviour)
    app = cworld.build()
    ids = app.state.catalog.policy_models
    with given(f"last_good = {last_good}"):
        if last_good != "none":  # one good refresh of the source first: the plausibility floor then holds a shrunk answer
            vendor.catalog, vendor.config, vendor.docs = "catalog-ok", "config-ok", "docs-ok"
            with quiet():
                assert await app.state.catalog.refresh_source(source) == "ok"
    with given(f"policy-default's Go ids (tiers + side_models, wire spelling): {', '.join(ids)}; source = {source} answers behaviour = {behaviour}"):
        attach_json("policy Go ids", list(ids))
        setattr(vendor, "catalog" if behaviour.startswith("catalog-") else source, behaviour)
    with when(f"the {source} source refreshes ({behaviour}); GET /metrics + GET /catalog/opencode"):
        await app.state.catalog.refresh_source(source)
        text = await _metrics(app)
        v = await _view(app)
    series = f'gateway_go_catalog_policy_models_missing{{source="{source}"}}'
    key = "listed" if source == "config" else "monthly_limit_usd"
    uncovered = sorted(m for m, r in v["policy_models"].items() if (r[key] is False if key == "listed" else r[key] is None))
    verdict(f"missing = {expected_missing} · uncovered = {expected_uncovered}",
            expected_missing={"expected": expected_missing, "actual": _value(text, series)},
            expected_uncovered={"expected": expected_uncovered, "actual": joined(uncovered)},
            last_good={"actual": last_good}, source={"actual": source}, behaviour={"actual": behaviour})
