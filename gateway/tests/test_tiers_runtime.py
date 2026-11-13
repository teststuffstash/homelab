"""GW-MODEL-TIERS §The derivation at a refresh — the gateway derives the tier lists itself after every good
catalog refresh, keeps the last good derivation, and shows it on GET /catalog/tiers beside the lists the
admission walks (specs/endpoints/catalog.md; homelab#3307, the shadow step of the runtime-tiers Goal).

Worlds: `policy-default · openrouter-endpoints` with the Go catalog (catalog-ok + docs-ok, T0 = the test clock)
and, per row, either the real legs (the openrouter-catalog fakes: the trigger, failed-input and restart rows)
or a hand-written openrouter view standing in for the OpenRouter leg's evidence (specs/worlds/README.md §The
tier derivation world). The tables are the spec's, verbatim (the header is the parameter list).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from ._catalog_rows import SecondGateway, at_iso, iso, or_refresh, or_refreshed, verdict
from .conftest import attach_json, given, quiet, rule, when, world

pytestmark = rule("GW-MODEL-TIERS")
WORLD = "openrouter-endpoints + the Go catalog"
SCHEMA = json.loads((Path(__file__).resolve().parents[1] / "specs" / "endpoints" / "catalog.schema.json").read_text(encoding="utf-8"))
T0 = 1_800_000_000.0
TIERS = ("heavy", "standard", "light")  # the page's reading order

V4, V41, GLM = "deepseek/deepseek-v4-flash", "deepseek/deepseek-v4.1-flash", "z-ai/glm-5.3-flash"
ABBR = {V4: "V4", V41: "V41", GLM: "GLM", **{f"claude/fx{c}": f"FX{c.upper()}" for c in "abcde"}}
OUT = {V4: 0.3, V41: 0.2, GLM: 0.1}
BENCH = {V4: 50, V41: 40, GLM: 30, **{f"anthropic/claude-fx{c}-1.0": v for c, v in zip("abcd", (20, 40, 60, 80), strict=True)}}
WALKED = {
    "openrouter": {"heavy": (V41,), "standard": (V41, V4), "light": (V4, V41)},
    "anthropic": {"light": ("claude/fxa", "claude/fxb"), "standard": ("claude/fxc",), "heavy": ("claude/fxd",)},
}


def hand_view(*, glm_intelligence="30", priced=True, at: float = T0) -> dict:
    """The OpenRouter leg's evidence as `GET /catalog/openrouter` carries it (the hand-written world)."""
    bench = {mid: {"intelligence": v, "coding": None, "agentic": None} for mid, v in BENCH.items()}
    bench[GLM]["intelligence"] = None if glm_intelligence == "null" else float(glm_intelligence)
    if glm_intelligence == "null":
        bench[GLM]["coding"] = 70
    models = {mid: {"selected": "p", "endpoints": [{"slug": "p", "service_tier": None, "in_price": 0.05, "uptime_1d": 100.0,
                                                     "out_price": price if priced else None, "rides": {"clean": 0, "judged": 0}}]}
              for mid, price in OUT.items()}
    return {"fetched_at": iso(at), "sources": {"benchmarks": {"as_of": "2027-01-14T00:00:00Z"}}, "benchmarks": bench, "models": models}


def _abbr(ids) -> str:
    return ", ".join(ABBR.get(i, i) for i in ids) or "none"


def _lists(rail: dict) -> str:
    return " · ".join(f"{t} {_abbr(rail['tiers'][t]['list'])}" for t in TIERS)


def _flags(rail: dict) -> str:
    return " · ".join(f"{t} {str(rail['tiers'][t]['equals_walked']).lower()}" for t in TIERS)


def _rails_of(view: dict) -> dict:
    return {r: {t: v["tiers"][t]["list"] for t in TIERS} for r, v in view["rails"].items()}


async def tiers_view(gw) -> dict:
    r = await gw.get("/catalog/tiers")
    assert r.status_code == 200, r.text
    return r.json()


def _walk(policy, rail: str) -> None:
    for tier, ids in WALKED[rail].items():
        policy.rails[rail].models[tier] = ids


# ── The refresh runs the derivation ──────────────────────────────────────────────────────────
TRIGGER_ROWS = [
    pytest.param("the Go catalog (the world's) at T0, no derivation", "openrouter leg ok at T0 + 21600 s", "T0 + 21600 s",
                 id="a good openrouter refresh derives ⚖"),
    pytest.param("the openrouter leg refreshed at T0", "Go leg docs source ok at T0 + 21600 s", "T0 + 21600 s",
                 id="a good Go refresh derives too ⚖"),
]


@pytest.mark.parametrize(("store_before", "refresh", "expected_derived_at"), TRIGGER_ROWS, ids=[p.id for p in TRIGGER_ROWS])
async def test_refresh_runs_the_derivation(gw, app, clock, store_before, refresh, expected_derived_at):
    world(note=f"{WORLD}; the real legs")
    with given(f"store_before = {store_before}"):
        if store_before.startswith("the openrouter leg"):
            await or_refreshed(app)
        assert (await tiers_view(gw))["derived_at"] is None or store_before.startswith("the openrouter leg")
        clock.advance(21600)
    if refresh.startswith("openrouter"):
        await or_refresh(app)
    else:
        with when("the Go catalog's docs source refreshes"):
            with quiet():
                assert await app.state.catalog.refresh_source("docs") == "ok"
    v = await tiers_view(gw)
    attach_json("GET /catalog/tiers", v)
    verdict(f"derived_at = {expected_derived_at}", expected_derived_at={"expected": at_iso(expected_derived_at), "actual": v["derived_at"]},
            store_before={"actual": store_before}, refresh={"actual": refresh})


# ── The derivation at a refresh ──────────────────────────────────────────────────────────────
DERIVE_ROWS = [
    pytest.param("catalogs and benched rows at T0, no derivation", "ok", "openrouter", "T0 + 21600 s",
                 "heavy V4 · standard V41, V4 · light GLM, V41, V4", "none", "none", "heavy false · standard true · light false",
                 id="a good refresh derives every rail's tiers ⚖"),
    pytest.param("a derivation at T0", "GLM intelligence 30 → 48", "openrouter", "T0 + 21600 s",
                 "heavy GLM, V4 · standard GLM, V41, V4 · light GLM, V41, V4", "none", "none", "heavy false · standard false · light false",
                 id="the feed moves, the lists move with no commit ⚖"),
    pytest.param("a derivation at T0: heavy V4 · standard V41, V4 · light GLM, V41, V4", "every openrouter price null", "openrouter", "T0 + 21600 s",
                 "heavy V4 · standard V41, V4 · light GLM, V41, V4", "heavy, standard, light", "none", "heavy false · standard true · light false",
                 id="a tier with no priced candidate is undecided and keeps its last derived list ⚖"),
    pytest.param("catalogs at T0", "GLM intelligence null", "openrouter", "T0 + 21600 s",
                 "heavy V4 · standard V41, V4 · light V41, V4", "none", "GLM", "heavy false · standard true · light false",
                 id="a benched candidate with no value on the score axis is in no list and is named ⚖"),
    pytest.param("policy rails.anthropic.models naming four aliases", "ok", "anthropic", "T0 + 21600 s",
                 "heavy FXD · standard FXC, FXD · light FXB, FXC, FXD", "none", "none", "heavy true · standard false · light false",
                 id="a subscription rail's candidates are the policy's ids ⚖"),
]


@pytest.mark.parametrize(("store_before", "refresh", "rail", "expected_derived_at", "expected_lists", "expected_undecided",
                          "expected_unscored", "expected_equals_walked"), DERIVE_ROWS, ids=[p.id for p in DERIVE_ROWS])
async def test_derivation_at_a_refresh(gw, app, policy, clock, store_before, refresh, rail, expected_derived_at, expected_lists,
                                       expected_undecided, expected_unscored, expected_equals_walked):
    world(note=f"{WORLD}; a hand-written openrouter view")
    td = app.state.tier_derivation
    with given(f"store_before = {store_before}; the policy's lists as the world's legend"):
        _walk(policy, "openrouter")
        _walk(policy, "anthropic")
        td.or_view = lambda: hand_view()
        if store_before.startswith("a derivation"):
            assert td.run()
        else:
            assert (await tiers_view(gw))["derived_at"] is None
        clock.advance(21600)
        change = {"ok": {}, "GLM intelligence 30 → 48": {"glm_intelligence": "48"}, "every openrouter price null": {"priced": False},
                  "GLM intelligence null": {"glm_intelligence": "null"}}[refresh]
        td.or_view = lambda: hand_view(at=clock(), **change)
    with when(f"the OpenRouter leg's good refresh at T0 + 21600 s ({refresh}) fires its hook"):
        app.state.orcatalog.on_refresh()
    v = await tiers_view(gw)
    r = v["rails"][rail]
    attach_json("GET /catalog/tiers", v)
    undecided = ", ".join(t for t in TIERS if t in r["undecided"]) or "none"
    verdict(f"derived_at = {expected_derived_at} · lists = {expected_lists} · undecided = {expected_undecided} · unscored = {expected_unscored} · "
            f"equals_walked = {expected_equals_walked}",
            expected_derived_at={"expected": at_iso(expected_derived_at), "actual": v["derived_at"]},
            expected_lists={"expected": expected_lists, "actual": _lists(r)},
            expected_undecided={"expected": expected_undecided, "actual": undecided},
            expected_unscored={"expected": expected_unscored, "actual": _abbr(r["unscored"])},
            expected_equals_walked={"expected": expected_equals_walked, "actual": _flags(r)},
            store_before={"actual": store_before}, refresh={"actual": refresh}, rail={"actual": rail})


# ── What a failed input leaves ───────────────────────────────────────────────────────────────
FAIL_ROWS = [
    pytest.param("empty store", "openrouter leg fetch-failed", "none", "none", id="no benched rows, no derivation"),
    pytest.param("a derivation at T0", "openrouter leg fetch-failed at T0 + 21600 s", "T0", "the T0 lists", id="a failed refresh keeps the last good derivation"),
    pytest.param("benched rows present, no Go catalog", "ok", "T0 + 21600 s", "opencode: none; the other rails derived",
                 id="one rail's input missing holds that rail only ⚖"),
    pytest.param("a derivation at T0", "none (restart at T0 + 3600 s)", "T0", "the T0 lists", id="the derivation survives a restart"),
]


@pytest.mark.parametrize(("store_before", "refresh", "expected_derived_at", "expected_lists"), FAIL_ROWS, ids=[p.id for p in FAIL_ROWS])
async def test_failed_input(gw, app, mcp, clock, settings, policy, secrets, reviews, pods, mcp_transport, store_before, refresh,
                            expected_derived_at, expected_lists):
    world(note=f"{WORLD}; the real legs")
    at_t0: dict = {}
    with given(f"store_before = {store_before}"):
        if store_before == "empty store":
            pass
        else:
            if "no Go catalog" in store_before:
                app.state.catalog.snapshots.pop("config")
            else:
                await or_refreshed(app)
                at_t0 = _rails_of(await tiers_view(gw))
                assert at_t0, "the derivation at T0 holds rails"
        clock.advance(3600 if refresh.startswith("none") else 21600)
    second = None
    if refresh.startswith("none"):
        with when("a new gateway starts on the same store (a pod roll) at T0 + 3600 s"):
            second = SecondGateway(settings, policy, secrets, mcp_transport, reviews, pods, clock)
            v = await tiers_view(second.gw)
        await second.close()
    else:
        mcp.mcp = "503" if "fetch-failed" in refresh else "ok"
        await or_refresh(app)
        v = await tiers_view(gw)
    attach_json("GET /catalog/tiers", v)
    rails = _rails_of(v)
    if expected_lists == "none":
        actual = "none" if not rails else f"{sorted(rails)}"
    elif expected_lists == "the T0 lists":
        actual = "the T0 lists" if rails == at_t0 else f"differs: {rails} vs {at_t0}"
    else:
        actual = expected_lists if "opencode" not in rails and set(rails) == {"anthropic", "openrouter"} else f"{sorted(rails)}"
    verdict(f"derived_at = {expected_derived_at} · lists = {expected_lists}",
            expected_derived_at={"expected": at_iso(expected_derived_at), "actual": v["derived_at"]},
            expected_lists={"expected": expected_lists, "actual": actual}, store_before={"actual": store_before}, refresh={"actual": refresh})


# ── The manual rows on the derivation ────────────────────────────────────────────────────────
MANUAL_ROWS = [
    pytest.param("a file", "FXE = 90", "claude/fxe 90", "used anthropic/claude-fxe-1.0 · retired none · refused none",
                 id="the derivation scores a manual row for an alias the feed lacks ⚖"),
    pytest.param("a file", "FXD = 95", "claude/fxd 80", "used none · retired anthropic/claude-fxd-1.0 · refused none",
                 id="a row the feed carries is reported retired and does not score ⚖"),
    pytest.param("none", "FXE = 90", "claude/fxd 80", "used none · retired none · refused none", id="no file, no manual rows"),
    pytest.param("a file", "no source", "claude/fxd 80", "used none · retired none · refused naming source_url",
                 id="a malformed file is refused whole and the derivation runs without it ⚖"),
]


def _manual_doc(cell: str) -> dict:
    row = {"id": "anthropic/claude-fxe-1.0", "intelligence": 90, "coding": None, "agentic": None, "source_url": "https://bench.example/fx",
           "read_at": "2027-01-10", "note": "fx"}
    if cell == "FXD = 95":
        row |= {"id": "anthropic/claude-fxd-1.0", "intelligence": 95}
    if cell == "no source":
        del row["source_url"]
    return {"rows": [row]}


@pytest.mark.parametrize(("file", "manual_row", "expected_anthropic_heavy", "expected_manual"), MANUAL_ROWS, ids=[p.id for p in MANUAL_ROWS])
async def test_manual_rows(gw, app, policy, tmp_path, file, manual_row, expected_anthropic_heavy, expected_manual):
    world(note=f"{WORLD}; a hand-written openrouter view")
    td = app.state.tier_derivation
    with given(f"file = {file} · manual_row = {manual_row}; the policy declares claude/fxa … claude/fxe"):
        _walk(policy, "anthropic")
        policy.rails["anthropic"].models["heavy"] = ("claude/fxd", "claude/fxe")
        td.or_view = lambda: hand_view()
        if file == "a file":
            path = tmp_path / "benchmarks-manual.json"
            path.write_text(json.dumps(_manual_doc(manual_row)), encoding="utf-8")
            td.manual_path = str(path)
    with when("the OpenRouter leg's good refresh fires its hook"):
        app.state.orcatalog.on_refresh()
    v = await tiers_view(gw)
    attach_json("GET /catalog/tiers", v)
    heavy = v["rails"]["anthropic"]["tiers"]["heavy"]
    top = " ".join(f"{i} {heavy['evidence'][i]['score']:g}" for i in heavy["list"])
    m = v["manual"]
    refused = "none" if not m["refused"] else "naming source_url" if "source_url" in m["refused"] else m["refused"]
    cell = f"used {', '.join(m['used']) or 'none'} · retired {', '.join(m['retired']) or 'none'} · refused {refused}"
    verdict(f"anthropic_heavy = {expected_anthropic_heavy} · manual = {expected_manual}",
            expected_anthropic_heavy={"expected": expected_anthropic_heavy, "actual": top},
            expected_manual={"expected": expected_manual, "actual": cell}, file={"actual": file}, manual_row={"actual": manual_row})


# ── The view's shape (tiers) ─────────────────────────────────────────────────────────────────
SHAPE_ROWS = [
    pytest.param("a derivation at T0", "exactly the schema's required keys", id="the view's shape is the schema's"),
    pytest.param("empty store", "`derived_at` null, no rails", id="no derivation is an empty view, never an error"),
]


@pytest.mark.parametrize(("state", "expected_shape"), SHAPE_ROWS, ids=[p.id for p in SHAPE_ROWS])
async def test_view_shape(gw, app, state, expected_shape):
    world(note=f"{WORLD}; the real legs")
    with given(f"state = {state}; catalog.schema.json `tiers_output`, `derived_tier`"):
        if state == "a derivation at T0":
            await or_refreshed(app)
    with when("GET /catalog/tiers"):
        v = await tiers_view(gw)
    attach_json("GET /catalog/tiers", v)
    if state == "empty store":
        actual = expected_shape if v["derived_at"] is None and v["rails"] == {} else f"differs: {v}"
    else:
        out = SCHEMA["tiers_output"]
        tier = SCHEMA["$defs"]["derived_tier"]
        ev = tier["properties"]["evidence"]["additionalProperties"]
        want = {"view": sorted(out["required"]), "rail": sorted(out["properties"]["rails"]["additionalProperties"]["required"]),
                "tier": sorted(tier["required"]), "evidence row": sorted(ev["required"]), "manual": sorted(out["properties"]["manual"]["required"])}
        rails = v["rails"].values()
        got = {"view": sorted(v), "rail": sorted({k for r in rails for k in r}), "tier": sorted({k for r in rails for t in r["tiers"].values() for k in t}),
               "evidence row": sorted({k for r in rails for t in r["tiers"].values() for e in t["evidence"].values() for k in e}),
               "manual": sorted(v["manual"])}
        diff = {k: {"schema": want[k], "view": got[k]} for k in want if want[k] != got[k]}
        actual = expected_shape if not diff and rails else f"differs: {diff}"
    verdict(f"shape = {expected_shape}", expected_shape={"expected": expected_shape, "actual": actual}, state={"actual": state})
