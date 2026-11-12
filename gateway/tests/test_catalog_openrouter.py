"""GW-CATALOG-OR — the OpenRouter rail's registry: the refresh, what it keeps, what a fetch sends,
the restart, /metrics, the view and its floors' verdict (specs/endpoints/catalog.md §The OpenRouter
catalog; homelab#2742, #2775, #2791).

World `policy-default · openrouter-catalog`: the fake MCP (tests/_orcatalog_world.py) answers the two
ranking slices and the AA benchmarks from tests/fixtures/openrouter-catalog/ (the live MCP answers of
2026-10-19, trimmed), the openrouter rail's fake serves `/v1/models/<id>/endpoints` for M =
deepseek/deepseek-v4.1-flash and G = z-ai/glm-5.3-flash (404 for the other five candidates). The account
key is the fixture Secret agent-egress/router-account-key. T0 = the test clock. The tables are the
spec's, verbatim (the header is the parameter list).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from agent_gateway import __version__

from ._catalog_rows import (
    OR_RAIL,
    G,
    M,
    SecondGateway,
    at_offset,
    canary_body,
    canary_ride,
    joined,
    num,
    or_refresh,
    or_refreshed,
    or_series,
    or_view,
    verdict,
)
from ._orcatalog_world import ACCOUNT_KEY
from .conftest import POLICY_FIXTURE, attach_json, given, quiet, rule, when, world

pytestmark = rule("GW-CATALOG-OR")
WORLD = "openrouter-catalog"
HARNESSES = ("opencode", "goose", "claude")  # the fixture policy's providers.tool_choice keys, in its order
SCHEMA = json.loads((Path(__file__).resolve().parents[1] / "specs" / "endpoints" / "catalog.schema.json").read_text(encoding="utf-8"))
T0 = 1_800_000_000


def _names(cell: str) -> str:
    return cell.replace("M, G", f"{M}, {G}").replace("M", M).replace("G", G) if cell in ("M, G", "M", "G") else cell


def _models_cell(v: dict) -> str:
    return ", ".join({M: "M", G: "G"}.get(m, m) for m in sorted(v["models"])) or "none"


def _endpoints(upstreams, cell: str) -> None:
    """The `endpoints` legend: `ok`; `<behaviour> for G` / `for M` / `for M and G`."""
    if cell == "ok":
        return
    behaviour, _, who = cell.partition(" for ")
    for name in who.split(" and "):
        upstreams[OR_RAIL].endpoints_behaviour[{"M": M, "G": G}[name]] = behaviour


def _verdicts(v: dict, model: str, slug: str) -> dict[str, dict]:
    return {e["tag"]: {"pinnable": e["pinnable"], "floor": e["floor"], "state": e["state"]} for e in v["models"][model]["endpoints"] if e["slug"] == slug}


# ── A refresh builds the snapshot ─────────────────────────────────────────────────────────────
BUILD_ROWS = [
    pytest.param("ok", "ok", "ok", "M, G", "8 (13 ranked, 8 benched)", 6, 15, 0,
                 id="a first refresh: ranked ∩ benched, then the endpoints per candidate"),
    pytest.param("ok", "endpoints-503 for G", "ok", "M", "8 (13 ranked, 8 benched)", 7, 8, 0,
                 id="a candidate whose endpoints read fails is absent; the refresh still lands ⚖"),
    pytest.param("ok", "endpoints-null-uptime for G", "ok", "M, G", "8 (13 ranked, 8 benched)", 6, 15, 1,
                 id="an endpoint without an uptime figure does not fail its model's parse ⚖"),
]


@pytest.mark.parametrize(("mcp_answer", "endpoints", "expected_outcome", "expected_models", "expected_candidates", "expected_unreadable",
                          "expected_cells", "expected_uptime_null"), BUILD_ROWS, ids=[p.id for p in BUILD_ROWS])
async def test_refresh_builds_the_snapshot(gw, app, upstreams, mcp_answer, endpoints, expected_outcome, expected_models, expected_candidates,
                                           expected_unreadable, expected_cells, expected_uptime_null):
    world(note=WORLD)
    with given(f"mcp_answer = {mcp_answer} · endpoints = {endpoints}; no snapshot yet"):
        _endpoints(upstreams, endpoints)
    outcome = await or_refresh(app)
    v = await or_view(gw)
    src = v["sources"]
    candidates = f"{src['candidates']} ({src['ranking']['ranked']} ranked, {src['benchmarks']['rows']} benched)"
    verdict(f"outcome = {expected_outcome} · models = {expected_models} · candidates = {expected_candidates} · unreadable = {expected_unreadable} · "
            f"cells = {expected_cells} · uptime_null = {expected_uptime_null}",
            expected_outcome={"expected": expected_outcome, "actual": outcome},
            expected_models={"expected": expected_models, "actual": _models_cell(v)},
            expected_candidates={"expected": expected_candidates, "actual": candidates},
            expected_unreadable={"expected": expected_unreadable, "actual": v["endpoint_failures"]},
            expected_cells={"expected": expected_cells, "actual": v["cells"]["candidate"]},
            expected_uptime_null={"expected": expected_uptime_null,
                                  "actual": sum(1 for m in v["models"].values() for e in m["endpoints"] if e["uptime_1d"] is None)},
            mcp_answer={"actual": mcp_answer}, endpoints={"actual": endpoints})


PERMASLUG_ROWS = [
    pytest.param("M-20260910 and M-20261017, both slices", "M, G", 9904923281600, 36555899534763,
                 id="a dated permaslug joins its id: two stamps of one model are one candidate ⚖"),
]


@pytest.mark.parametrize(("rankings", "expected_models", "expected_programming_tokens", "expected_tool_calling_tokens"), PERMASLUG_ROWS,
                         ids=[p.id for p in PERMASLUG_ROWS])
async def test_permaslug_joins_id(gw, app, rankings, expected_models, expected_programming_tokens, expected_tool_calling_tokens):
    world(note=WORLD)
    with given(f"rankings = {rankings}: the fixture's latest-week rows of M"):
        fixtures = Path(__file__).resolve().parent / "fixtures" / "openrouter-catalog"
        stamps = {s: sorted({r["model_permaslug"] for r in json.loads((fixtures / f"rankings-{s}.json").read_text())["data"]
                             if r["model_permaslug"].startswith(M) and r["date"] == "2026-10-12"}) for s in ("programming", "tool_calling")}
        attach_json("the stamps of M in the latest week", stamps)
        assert stamps == {s: [f"{M}-20260910", f"{M}-20261017"] for s in stamps}
    await or_refresh(app)
    v = await or_view(gw)
    verdict(f"models = {expected_models} · programming_tokens = {expected_programming_tokens} · tool_calling_tokens = {expected_tool_calling_tokens}",
            expected_models={"expected": expected_models, "actual": _models_cell(v)},
            expected_programming_tokens={"expected": expected_programming_tokens, "actual": v["models"][M]["ranking"]["programming"]},
            expected_tool_calling_tokens={"expected": expected_tool_calling_tokens, "actual": v["models"][M]["ranking"]["tool_calling"]},
            rankings={"actual": rankings})


# ── A `:free` id joins its family's AA row; the `other` bucket is never ranked (GW-CATALOG-OR §A `:free` and `other`) ──
FREE_ROWS = [
    pytest.param("the `:free` row in programming", "ok", "8 (13 ranked, 8 benched)", "requested",
                 id="a `:free` id joins its family's AA row and is a candidate under its own id ⚖"),
    pytest.param("the `:free` row in programming", "benchmarks-no-family", "7 (13 ranked, 7 benched)", "absent",
                 id="a `:free` id whose family AA does not bench is no candidate"),
]


@pytest.mark.parametrize(("rankings", "benchmarks", "expected_candidates", "expected_free_read"), FREE_ROWS, ids=[p.id for p in FREE_ROWS])
async def test_free_id_joins_family(gw, app, mcp, upstreams, rankings, benchmarks, expected_candidates, expected_free_read):
    world(note=WORLD)
    with given(f"rankings = {rankings}; benchmarks = {benchmarks}"):
        mcp.mcp = benchmarks
    await or_refresh(app)
    v = await or_view(gw)
    src = v["sources"]
    candidates = f"{src['candidates']} ({src['ranking']['ranked']} ranked, {src['benchmarks']['rows']} benched)"
    reads = [c["path"] for c in upstreams[OR_RAIL].calls if c["path"] == "/v1/models/nvidia/nemotron-3-ultra-550b-a55b:free/endpoints"]
    verdict(f"candidates = {expected_candidates} · the `:free` id's endpoints read = {expected_free_read}",
            expected_candidates={"expected": expected_candidates, "actual": candidates},
            expected_free_read={"expected": expected_free_read, "actual": "requested" if reads else "absent"},
            rankings={"actual": rankings}, benchmarks={"actual": benchmarks})


OTHER_ROWS = [
    pytest.param("the `other` row in both slices", "ok", "8 (13 ranked, 8 benched)", "absent",
                 id="the `other` bucket is never ranked and never a candidate ⚖"),
]


@pytest.mark.parametrize(("rankings", "benchmarks", "expected_candidates", "expected_other_read"), OTHER_ROWS, ids=[p.id for p in OTHER_ROWS])
async def test_other_bucket_never_ranked(gw, app, mcp, upstreams, rankings, benchmarks, expected_candidates, expected_other_read):
    world(note=WORLD)
    with given(f"rankings = {rankings}; benchmarks = {benchmarks}"):
        mcp.mcp = benchmarks
    await or_refresh(app)
    v = await or_view(gw)
    src = v["sources"]
    candidates = f"{src['candidates']} ({src['ranking']['ranked']} ranked, {src['benchmarks']['rows']} benched)"
    reads = [c["path"] for c in upstreams[OR_RAIL].calls if c["path"].startswith("/v1/models/other/")]
    verdict(f"candidates = {expected_candidates} · the `other` bucket's endpoints read = {expected_other_read}",
            expected_candidates={"expected": expected_candidates, "actual": candidates},
            expected_other_read={"expected": expected_other_read, "actual": "requested" if reads else "absent"},
            rankings={"actual": rankings}, benchmarks={"actual": benchmarks})


# ── A failed read keeps the last good ─────────────────────────────────────────────────────────
FAIL_ROWS = [
    pytest.param("2", "503", "ok", "present", "fetch-failed", 2, 1, id="the MCP answers an error: fetch-failed, the last good kept"),
    pytest.param("2", "down", "ok", "present", "fetch-failed", 2, 0, id="the MCP is unreachable: fetch-failed"),
    pytest.param("2", "malformed", "ok", "present", "parse-failed", 2, 2, id="a tool result that is not JSON is a parse failure ⚖"),
    pytest.param("2", "rankings-undated", "ok", "present", "parse-failed", 2, 2, id="rankings without dates are a parse failure"),
    pytest.param("2", "ok", "endpoints-503 for M and G", "present", "implausible", 2, 6, id="every endpoints read failing keeps the last good"),
    pytest.param("none", "benchmarks-empty", "ok", "present", "implausible", 0, 6, id="no benched candidate: implausible, nothing taken ⚖"),
    pytest.param("none", "ok", "ok", "absent", "fetch-failed", 0, 0, id="no account key: fetch-failed, no MCP call"),
]


@pytest.mark.parametrize(("last_good", "mcp_answer", "endpoints", "account_key", "expected_outcome", "expected_models", "expected_mcp_calls"),
                         FAIL_ROWS, ids=[p.id for p in FAIL_ROWS])
async def test_failed_read_keeps_last_good(gw, app, mcp, mcp_transport, upstreams, secrets, last_good, mcp_answer, endpoints, account_key,
                                           expected_outcome, expected_models, expected_mcp_calls):
    world(note=f"{WORLD}; mcp {mcp_answer}, endpoints {endpoints}, account key {account_key}")
    with given(f"last_good = {last_good}"):
        if last_good != "none":
            await or_refreshed(app)
    with given(f"mcp_answer = {mcp_answer} · endpoints = {endpoints} · account_key = {account_key}"):
        if mcp_answer == "down":
            mcp_transport.down = True
        else:
            mcp.mcp = mcp_answer
        _endpoints(upstreams, endpoints)
        if account_key == "absent":
            del secrets.secrets["agent-egress/router-account-key"]
        mcp.calls.clear()
    outcome = await or_refresh(app, " again" if last_good != "none" else "")
    v = await or_view(gw)
    verdict(f"outcome = {expected_outcome} · models = {expected_models} · mcp_calls = {expected_mcp_calls}",
            expected_outcome={"expected": expected_outcome, "actual": outcome},
            expected_models={"expected": expected_models, "actual": len(v["models"])},
            expected_mcp_calls={"expected": expected_mcp_calls, "actual": len(mcp.calls)},
            last_good={"actual": last_good}, mcp_answer={"actual": mcp_answer}, endpoints={"actual": endpoints}, account_key={"actual": account_key})


# ── What a fetch sends ────────────────────────────────────────────────────────────────────────
SEND_ROWS = [
    pytest.param("ok", "initialize, list-daily-model-rankings, initialize, list-daily-model-rankings, initialize, list-benchmarks",
                 "Bearer <the account key>", "agent-gateway/<version> (openrouter-catalog)",
                 "period week · category programming; period week · modality tool_calling",
                 id="the MCP calls carry the account key and a client identity ⚖"),
]


@pytest.mark.parametrize(("mcp_answer", "expected_calls", "expected_authorization", "expected_user_agent", "expected_ranking_arguments"), SEND_ROWS,
                         ids=[p.id for p in SEND_ROWS])
async def test_fetch_sends(gw, app, mcp, mcp_answer, expected_calls, expected_authorization, expected_user_agent, expected_ranking_arguments):
    world(note=WORLD)
    with given(f"mcp_answer = {mcp_answer}"):
        mcp.mcp = mcp_answer
    await or_refresh(app)
    calls = mcp.calls
    attach_json("the MCP requests (the key redacted)", [{"method": c["method"], "params": c["params"]} for c in calls])
    auths = {c["headers"].get("authorization") for c in calls}
    uas = {c["headers"].get("user-agent") for c in calls}
    args = [c["params"]["arguments"]["request"] for c in calls if c["method"] == "tools/call" and c["params"]["name"] == "list-daily-model-rankings"]
    verdict(f"calls = {expected_calls} · authorization = {expected_authorization} · user_agent = {expected_user_agent} · ranking_arguments = {expected_ranking_arguments}",
            expected_calls={"expected": expected_calls, "actual": ", ".join(c["params"]["name"] if c["method"] == "tools/call" else c["method"] for c in calls)},
            expected_authorization={"expected": expected_authorization, "actual": "Bearer <the account key>" if auths == {f"Bearer {ACCOUNT_KEY}"} else repr(auths)},
            expected_user_agent={"expected": expected_user_agent, "actual": uas.pop().replace(__version__, "<version>") if len(uas) == 1 else repr(uas)},
            expected_ranking_arguments={"expected": expected_ranking_arguments,
                                        "actual": "; ".join(" · ".join(f"{k} {v}" for k, v in a.items()) for a in args)},
            mcp_answer={"actual": mcp_answer})


# ── Kept across a restart ─────────────────────────────────────────────────────────────────────
RESTART_ROWS = [
    pytest.param("T0 + 600 s", 600, 2, 15, 21000, 21000, id="a PVC store keeps the snapshot and the cells across a restart"),
    pytest.param("T0 + 3600 s", 3600, 2, 15, 18000, 18000, id="a restart inside the interval refreshes nothing at start ⚖"),
    pytest.param("T0 + 21600 s", 21600, 2, 15, 0, 60, id="a restart after the interval refreshes at start"),
]


@pytest.mark.parametrize(("restart_at", "expected_age_s", "expected_models", "expected_cells", "expected_startup_delay", "expected_retry_after_s"),
                         RESTART_ROWS, ids=[p.id for p in RESTART_ROWS])
async def test_restart(gw, app, clock, settings, policy, secrets, mcp_transport, reviews, pods, restart_at, expected_age_s, expected_models,
                       expected_cells, expected_startup_delay, expected_retry_after_s):
    world(note=f"{WORLD}; a second gateway on the same DB, refresh_s 21600")
    with given("a good refresh at T0 on gateway #1"):
        await or_refreshed(app)
    clock.advance(at_offset(restart_at))
    with when(f"gateway #2 starts on the same DB at restart_at = {restart_at}; GET /catalog/openrouter and a canary on (M, fireworks) before any refresh"):
        second = SecondGateway(settings, policy, secrets, mcp_transport, reviews, pods, clock)
        v = await or_view(second.gw)
        r = await second.gw.post("/sessions", json=canary_body(M, "fireworks"))
        await second.close()
    answer = r.json()
    verdict(f"age_s = {expected_age_s} · models = {expected_models} · cells = {expected_cells} · startup_delay = {expected_startup_delay} · retry_after_s = {expected_retry_after_s}",
            expected_age_s={"expected": expected_age_s, "actual": v["age_s"]},
            expected_models={"expected": expected_models, "actual": len(v["models"])},
            expected_cells={"expected": expected_cells, "actual": v["cells"]["candidate"]},
            expected_startup_delay={"expected": expected_startup_delay, "actual": second.or_delay},
            expected_retry_after_s={"expected": expected_retry_after_s, "actual": answer.get("retry_after_s")},
            defer={"expected": {"decision": "defer", "reason": "not-in-catalog"}, "actual": {k: answer.get(k) for k in ("decision", "reason")}},
            last_attempt_at={"expected": None, "actual": v["last_attempt_at"]},
            restart_at={"actual": restart_at})


# ── What /metrics says ────────────────────────────────────────────────────────────────────────
METRIC_ROWS = [
    pytest.param("ok", "T0 + 600 s", "gateway_openrouter_catalog_age_seconds", "600", id="age is seconds since the last good refresh"),
    pytest.param("ok", "T0", "gateway_openrouter_catalog_models", "2", id="the model count of the last good snapshot"),
    pytest.param("ok, then mcp 503", "T0",
                 'gateway_openrouter_catalog_refresh_total{outcome="ok"} / gateway_openrouter_catalog_refresh_total{outcome="fetch-failed"}', "1 / 1",
                 id="every refresh is counted by outcome"),
    pytest.param("ok, then mcp 503", "T0",
                 'gateway_openrouter_catalog_last_outcome{outcome="fetch-failed"} / gateway_openrouter_catalog_last_outcome{outcome="ok"}', "1 / 0",
                 id="the last outcome is 1, the others 0"),
]


@pytest.mark.parametrize(("refreshes", "read_at", "series", "expected_value"), METRIC_ROWS, ids=[p.id for p in METRIC_ROWS])
async def test_metrics(gw, app, mcp, clock, refreshes, read_at, series, expected_value):
    world(note=f"{WORLD}; refreshes {refreshes}")
    with given(f"refreshes = {refreshes}"):
        for step in refreshes.split(", then "):
            if step.startswith("mcp "):
                mcp.mcp = step[len("mcp "):]
            with quiet():
                await app.state.orcatalog.refresh()
        attach_json("arranged refreshes", refreshes.split(", then "))
    clock.t = T0 + at_offset(read_at)
    names = [s.strip() for s in series.split(" / ")]
    with when(f"GET /metrics at read_at = {read_at}: {series}"):
        values = [await or_series(gw, n) for n in names]
    verdict(f"{series} = {expected_value}", expected_value={"expected": expected_value, "actual": " / ".join("absent" if x is None else num(x) for x in values)},
            refreshes={"actual": refreshes}, read_at={"actual": read_at}, series={"actual": series})


SHAPE_ROWS = [pytest.param("ok", "exactly the schema's required keys", id="the view's shape is the schema's")]


@pytest.mark.parametrize(("mcp_answer", "expected_shape"), SHAPE_ROWS, ids=[p.id for p in SHAPE_ROWS])
async def test_view_shape(gw, app, mcp, mcp_answer, expected_shape):
    world(note=WORLD)
    with given(f"mcp_answer = {mcp_answer}; catalog.schema.json `openrouter_output`, its model row, endpoint row and `canary`"):
        mcp.mcp = mcp_answer
    await or_refresh(app)
    with when("GET /catalog/openrouter"):
        v = await or_view(gw)
    out = SCHEMA["openrouter_output"]
    row = out["properties"]["models"]["additionalProperties"]
    want = {"view": sorted(out["required"]), "model row": sorted(row["required"]),
            "endpoint row": sorted(row["properties"]["endpoints"]["items"]["required"]), "canary": sorted(out["properties"]["canary"]["required"])}
    got = {"view": sorted(v), "model row": sorted({k for r in v["models"].values() for k in r}),
           "endpoint row": sorted({k for r in v["models"].values() for e in r["endpoints"] for k in e}), "canary": sorted(v["canary"])}
    diff = {k: {"schema": want[k], "view": got[k]} for k in want if want[k] != got[k]}
    verdict(f"shape = {expected_shape}", expected_shape={"expected": expected_shape, "actual": expected_shape if not diff else f"differs: {diff}"},
            mcp_answer={"actual": mcp_answer}, keys={"actual": got})


# ── The floors' verdict on the view (homelab#2775, #2791) ─────────────────────────────────────
def _pinnable_cell(rows: dict[str, dict]) -> str:
    per = {tuple(r["pinnable"][h] for h in HARNESSES) for r in rows.values()}
    return " / ".join(str(x).lower() for x in per.pop()) if len(per) == 1 else f"differs: {rows}"


def _floor_cell(rows: dict[str, dict]) -> str:
    per = {json.dumps(r["floor"], sort_keys=True) for r in rows.values()}
    if len(per) != 1:
        return f"differs: {rows}"
    floor = json.loads(per.pop())
    if not floor:
        return "none"
    if set(floor) == set(HARNESSES) and len(set(floor.values())) == 1:
        return f"all three: {next(iter(floor.values()))}"
    return "; ".join(f"{h}: {floor[h]}" for h in HARNESSES if h in floor)


PINNABLE_ROWS = [
    pytest.param("M@morph", "ok", "fp8", "true / true / false", "claude: no tool_choice required,function", 1,
                 id="the view says which cells selection could pin: a cell without required/function is pinnable for opencode and goose, not claude ⚖"),
    pytest.param("M@open-inference", "ok", "fp8", "false / false / false", "all three: quantization fp4 < fp8", 1,
                 id="the 2026-10-20 cell: fp4 is pinnable for no harness"),
    pytest.param("M@deepinfra", "ok", "fp8", "true / true / true", "none", 3,
                 id="a cell clearing every floor is pinnable everywhere; its service tiers carry the representative's verdict ⚖"),
    pytest.param("M@inference-net", "endpoints-null-uptime@inference-net/fp8 for M", "fp8", "false / false / false", "all three: uptime_1d unknown", 1,
                 id="a null uptime clears no floor on any harness ⚖"),
    pytest.param("M@open-inference", "ok", "fp4", "true / true / true", "none", 1, id="the flag follows the policy, not the data ⚖"),
]


@pytest.mark.parametrize(("cell", "endpoints", "quantization_floor", "expected_pinnable", "expected_floor", "expected_rows"), PINNABLE_ROWS,
                         ids=[p.id for p in PINNABLE_ROWS])
async def test_floors_verdict(gw, app, upstreams, clock, settings, secrets, mcp_transport, reviews, pods, tmp_path, cell, endpoints,
                              quantization_floor, expected_pinnable, expected_floor, expected_rows):
    world(note=f"{WORLD}; the floors of policy-default (fp8, uptime 95, tool_choice opencode/goose auto, claude auto+required+function)"
               + (f"; a second gateway under quantization_floor {quantization_floor}" if quantization_floor != "fp8" else ""))
    slug = cell.split("@", 1)[1]
    with given(f"cell = {cell} · endpoints = {endpoints}; a first good refresh"):
        _endpoints(upstreams, endpoints)
        await or_refreshed(app)
    reader, second = gw, None
    if quantization_floor != "fp8":
        with given(f"quantization_floor = {quantization_floor}: a second gateway on the same DB and snapshot, its policy the fixture with that floor (the data untouched)"):
            from agent_gateway.config import Policy

            doc = json.loads(POLICY_FIXTURE.read_text(encoding="utf-8"))
            doc["rails"][OR_RAIL]["providers"]["quantization_floor"] = quantization_floor
            path = tmp_path / f"policy-floor-{quantization_floor}.json"
            path.write_text(json.dumps(doc), encoding="utf-8")
            second = SecondGateway(settings, Policy.load(path), secrets, mcp_transport, reviews, pods, clock)
            reader = second.gw
    with when(f"GET /catalog/openrouter → the rows of {cell} (quantization_floor = {quantization_floor})"):
        v = await or_view(reader)
        rows = _verdicts(v, M, slug)
        attach_json(f"the view's rows of {cell}", rows)
    if second is not None:
        await second.close()
    verdict(f"pinnable = {expected_pinnable} · floor = {expected_floor} · rows = {expected_rows}",
            expected_pinnable={"expected": expected_pinnable, "actual": _pinnable_cell(rows)},
            expected_floor={"expected": expected_floor, "actual": _floor_cell(rows)},
            expected_rows={"expected": expected_rows, "actual": len(rows)},
            cell={"actual": cell}, endpoints={"actual": endpoints}, quantization_floor={"actual": quantization_floor})


SELECTED_ROWS = [
    pytest.param("M@open-inference (out $0.08/M) and M@deepinfra (out $0.42/M)", "deepinfra", "deepinfra", "eligible, pinnable false", "eligible, pinnable true",
                 id="selected is always a pinnable cell: the cheaper eligible fp4 cell is passed over ⚖"),
]


@pytest.mark.parametrize(("canaried", "expected_selected", "expected_order", "expected_open_inference", "expected_deepinfra"), SELECTED_ROWS,
                         ids=[p.id for p in SELECTED_ROWS])
async def test_selected_is_pinnable(gw, app, upstreams, canaried, expected_selected, expected_order, expected_open_inference, expected_deepinfra):
    world(upstream="upstream-ok", note=f"{WORLD}; clean canaries on (M, open-inference) and (M, deepinfra)")
    with given(f"a first good refresh; canaried = {canaried}: clean canary rides on both cells"):
        await or_refreshed(app)
        await canary_ride(gw, upstreams, "open-inference")
        await canary_ride(gw, upstreams, "deepinfra")
    with when("GET /catalog/openrouter → M's selected and order, the two cells' rows"):
        v = await or_view(gw)
        oi = _verdicts(v, M, "open-inference")["open-inference/fp4"]
        di = _verdicts(v, M, "deepinfra")["deepinfra/fp8"]
        attach_json("the two cells as the view shows them", {"open-inference": oi, "deepinfra": di})

    def cell_of(r: dict) -> str:
        return f"{r['state']}, pinnable {str(r['pinnable']['opencode']).lower()}"
    verdict(f"selected = {expected_selected} · order = {expected_order} · open_inference = {expected_open_inference} · deepinfra = {expected_deepinfra}",
            expected_selected={"expected": expected_selected, "actual": v["models"][M]["selected"]},
            expected_order={"expected": expected_order, "actual": joined(v["models"][M]["order"])},
            expected_open_inference={"expected": expected_open_inference, "actual": cell_of(oi)},
            expected_deepinfra={"expected": expected_deepinfra, "actual": cell_of(di)},
            canaried={"actual": canaried},
            every_selected_is_eligible_and_pinnable={
                "expected": True,
                "actual": all(next((e["state"], e["pinnable"]["opencode"]) for e in m["endpoints"] if e["slug"] == m["selected"]) == ("eligible", True)
                              for m in v["models"].values() if m["selected"] is not None)})
