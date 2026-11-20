"""GW-MODEL-TIERS §The derivation at a refresh — the gateway derives the tier lists itself after every good
catalog refresh, keeps the last good derivation, and shows it on GET /catalog/tiers beside the lists the
admission walks (specs/endpoints/catalog.md; homelab#3307, the shadow step of the runtime-tiers Goal); §The
rulings bound on such a derivation and §The evidence age (homelab#3309: no committed snapshot).

Worlds: `policy-default · openrouter-endpoints` with the Go catalog (catalog-ok + docs-ok, T0 = the test clock)
and, per row, either the real legs (the openrouter-catalog fakes: the trigger, failed-input and restart rows)
or a hand-written openrouter view standing in for the OpenRouter leg's evidence (specs/worlds/README.md §The
tier derivation world). The tables are the spec's, verbatim (the header is the parameter list).
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from agent_gateway.config import RAIL_PREFIX
from agent_gateway.tiers import PRICELESS_RAILS, join_aa_id, row_cost, same_model

from ._catalog_rows import (
    SecondGateway,
    at_iso,
    at_offset,
    iso,
    joined,
    num,
    or_refresh,
    or_refreshed,
    verdict,
)
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


AS_OF = "2027-01-14T00:00:00Z"


def hand_view(*, glm_intelligence="30", priced=True, at: float = T0, as_of: str | None = AS_OF) -> dict:
    """The OpenRouter leg's evidence as `GET /catalog/openrouter` carries it (the hand-written world)."""
    bench = {mid: {"intelligence": v, "coding": None, "agentic": None} for mid, v in BENCH.items()}
    bench[GLM]["intelligence"] = None if glm_intelligence == "null" else float(glm_intelligence)
    if glm_intelligence == "null":
        bench[GLM]["coding"] = 70
    models = {mid: {"selected": "p", "endpoints": [{"slug": "p", "service_tier": None, "in_price": 0.05, "uptime_1d": 100.0,
                                                     "out_price": price if priced else None, "rides": {"clean": 0, "judged": 0}}]}
              for mid, price in OUT.items()}
    return {"fetched_at": iso(at), "sources": {"benchmarks": {"as_of": as_of}}, "benchmarks": bench, "models": models}


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
                 "heavy V4 · standard V41, V4 · light GLM, V41, V4", "none", "none", "heavy true · standard true · light true",
                 id="a good refresh derives every rail's tiers ⚖"),
    pytest.param("a derivation at T0", "GLM intelligence 30 → 48", "openrouter", "T0 + 21600 s",
                 "heavy GLM, V4 · standard GLM, V41, V4 · light GLM, V41, V4", "none", "none", "heavy true · standard true · light true",
                 id="the feed moves, the lists move with no commit ⚖"),
    pytest.param("a derivation at T0: heavy V4 · standard V41, V4 · light GLM, V41, V4", "every openrouter price null", "openrouter", "T0 + 21600 s",
                 "heavy V4 · standard V41, V4 · light GLM, V41, V4", "heavy, standard, light", "none", "heavy true · standard true · light true",
                 id="a tier with no priced candidate is undecided and keeps its last derived list ⚖"),
    pytest.param("catalogs at T0", "GLM intelligence null", "openrouter", "T0 + 21600 s",
                 "heavy V4 · standard V41, V4 · light V41, V4", "none", "GLM", "heavy true · standard true · light true",
                 id="a benched candidate with no value on the score axis is in no list and is named ⚖"),
    pytest.param("policy rails.anthropic.models naming four aliases", "ok", "anthropic", "T0 + 21600 s",
                 "heavy FXD · standard FXC, FXD · light FXB, FXC, FXD", "none", "none", "heavy true · standard true · light true",
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


# ── The walked list is the derived one ───────────────────────────────────────────────────────
WALKED_ROWS = [pytest.param("a derivation at T0", "true on every tier", id="after the cut-over every tier equals what the admission walks ⚖")]


@pytest.mark.real_walk
@pytest.mark.parametrize(("store_state", "expected_equals_walked"), WALKED_ROWS, ids=[p.id for p in WALKED_ROWS])
async def test_the_walked_list_is_the_derived_one(gw, app, store_state, expected_equals_walked):
    world(note=f"{WORLD}; a hand-written openrouter view")
    with given("store = a derivation at T0"):
        app.state.tier_derivation.or_view = lambda: hand_view()
        assert app.state.tier_derivation.run()
    with when("GET /catalog/tiers"):
        v = await tiers_view(gw)
    attach_json("GET /catalog/tiers", v)
    flags = {f"{r}/{t}": v["rails"][r]["tiers"][t]["equals_walked"] for r in v["rails"] for t in TIERS}
    verdict("equals_walked = true on every tier", expected_equals_walked={"expected": expected_equals_walked,
                                    "actual": "true on every tier" if flags and all(flags.values()) else f"differs: {flags}"},
            store_state={"actual": store_state})


# ── The rulings, over a derivation ───────────────────────────────────────────────────────────
GLM52, UNBENCHED, UNPRICED = "z-ai/glm-5.2", "fx/unbenched", "fx/unpriced"


def ruling_view() -> dict:
    """The tier derivation's world plus the three openrouter models the rulings need (specs/worlds/README.md)."""
    v = hand_view()
    v["benchmarks"][GLM52] = {"intelligence": None, "coding": 70, "agentic": None}
    v["benchmarks"][UNPRICED] = {"intelligence": 49, "coding": None, "agentic": None}
    ep = {"slug": "p", "service_tier": None, "in_price": 0.01, "uptime_1d": 100.0, "rides": {"clean": 0, "judged": 0}}
    v["models"][GLM52] = {"selected": "p", "endpoints": [{**ep, "out_price": 0.05}]}
    v["models"][UNBENCHED] = {"selected": "p", "endpoints": [{**ep, "out_price": 0.01}]}
    v["models"][UNPRICED] = {"selected": None, "endpoints": []}
    return v


class Evidence:
    """The raw evidence the derivation read — the OpenRouter view, the Go view, the policy — read here by the
    page's candidate rule, not through the derivation, so each invariant is a second reading."""

    def __init__(self, orv: dict, gov: dict, policy):
        self.orv, self.gov, self.policy = orv, gov, policy
        self.benched = sorted(orv["benchmarks"])
        listed_go = sorted(mid for mid, m in (gov.get("models") or {}).items() if m.get("listed") and m.get("monthly_limit_usd") is not None)
        sub = {r: sorted({pid for t in ("light", "standard", "heavy") for pid in (policy.rails[r].models.get(t, ()) if r in policy.rails else ())})
               for r in PRICELESS_RAILS}
        sub_aa = [a for r in PRICELESS_RAILS for pid in sub[r] if (a := join_aa_id(pid, self.benched))]
        self.candidates = {"openrouter": sorted(orv["models"]), **sub,
                           "opencode": [RAIL_PREFIX["opencode"] + mid for mid in listed_go
                                        if not any(same_model(RAIL_PREFIX["opencode"] + mid, a) for a in sub_aa)]}

    def aa(self, pid: str) -> str | None:
        return join_aa_id(pid, self.benched)

    def score(self, pid: str):
        a = self.aa(pid)
        return self.orv["benchmarks"][a].get("intelligence") if a else None

    def price(self, rail: str, pid: str):
        if rail == "openrouter":
            m = self.orv["models"][pid]
            ep = next((e for e in m["endpoints"] if e["slug"] == m.get("selected")), None)
            return ep["out_price"] if ep else None
        if rail == "opencode":
            return (((self.gov.get("pricing") or {}).get("models") or {}).get(pid[len(RAIL_PREFIX["opencode"]):]) or {}).get("out")
        return None

    def pool(self, rail: str) -> dict[str, float]:
        return {pid: float(self.score(pid)) for pid in self.candidates.get(rail, [])
                if isinstance(self.score(pid), int | float) and (rail in PRICELESS_RAILS or self.price(rail, pid) is not None)}


def _listed(v: dict):
    """(rail, tier, id, its evidence row) for every id of every derived list on the view."""
    return [(rail, t, pid, r["tiers"][t]["evidence"][pid]) for rail, r in v["rails"].items() for t in TIERS for pid in r["tiers"][t]["list"]]


def _ruling_score(v, ev, policy):
    axis = policy.tiers.score
    out = [f"{rail}.{t}:{pid} has no {axis}" for rail, t, pid, e in _listed(v) if not isinstance(e["score"], int | float)]
    for rail, r in v["rails"].items():
        without = sorted(pid for pid in ev.candidates.get(rail, []) if ev.aa(pid) and ev.score(pid) is None)
        out += [f"{rail}:{pid} is benched with no {axis} and `unscored` does not name it" for pid in without if pid not in r["unscored"]]
        out += [f"`unscored` names {rail}:{pid}, which carries {axis} or is unbenched" for pid in r["unscored"] if pid not in without]
    return f"tiers.score: {axis}", out


def _ruling_bands(v, ev, policy):
    out = []
    for rail, t, pid, e in _listed(v):
        top = max(ev.pool(rail).values())
        if e["score"] < policy.tiers.bands[t] * top:
            out.append(f"{rail}.{t}:{pid} {num(e['score'])} < {policy.tiers.bands[t]} × {num(top)}")
    return "tiers.bands", out


def _ruling_cheapest(v, ev, policy):
    out = []
    for rail, r in v["rails"].items():
        if rail in PRICELESS_RAILS:
            continue
        for t in TIERS:
            ids = r["tiers"][t]["list"]
            costs = [row_cost({"out_price": r["tiers"][t]["evidence"][pid]["price"], "rides": r["tiers"][t]["evidence"][pid]["rides"]}, policy.tiers.cost) for pid in ids]
            if len(ids) > policy.tiers.cap:
                out.append(f"{rail}.{t} has {len(ids)} ids, over the cap")
            if costs != sorted(costs):
                out.append(f"{rail}.{t} not cost-ascending: {costs}")
    return "tiers.cap", out


def _ruling_subscription(v, ev, policy):
    out = []
    for rail in PRICELESS_RAILS:
        r = v["rails"].get(rail)
        if r is None:
            continue
        for t in TIERS:
            ev_rows = r["tiers"][t]["evidence"]
            out += [f"{rail}.{t}:{pid} priced" for pid, e in ev_rows.items() if e["price"] is not None or e["basis"] is not None]
            scores = [ev_rows[pid]["score"] for pid in r["tiers"][t]["list"]]
            if scores != sorted(set(scores)):
                out.append(f"{rail}.{t} not strictly score-ascending: {scores}")
    return "PRICELESS_RAILS", out


def _ruling_candidates(v, ev, policy):
    out = [f"{rail}.{t}:{pid} is no candidate of its rail" for rail, t, pid, _ in _listed(v) if pid not in ev.candidates.get(rail, [])]
    out += [f"openrouter.{t}:{pid} priced off {e['basis']}" for rail, t, pid, e in _listed(v) if rail == "openrouter" and e["basis"] != "endpoint"]
    out += [f"opencode.{t}:{pid} priced off {e['basis']}" for rail, t, pid, e in _listed(v)
            if rail == "opencode" and e["basis"] not in ("promise", "measured", "unlimited")]
    return "the sources", out


def _ruling_join(v, ev, policy):
    return "the rule", [f"{rail}.{t}:{pid} aa_id {e['aa_id']} ≠ {ev.aa(pid)}" for rail, t, pid, e in _listed(v) if e["aa_id"] != ev.aa(pid)]


def _ruling_unbenched(v, ev, policy):
    out = [f"{rail}.{t}:{pid} has no AA row" for rail, t, pid, e in _listed(v) if e["aa_id"] is None]
    out += [f"{rail}.{t}:{pid} unpriced on a priced rail" for rail, t, pid, e in _listed(v) if rail not in PRICELESS_RAILS and e["price"] is None]
    return "derive", out


RULINGS = {
    "every id of a derived list carries `intelligence`; a benched row without it is in no list and is named by `unscored`": _ruling_score,
    "within a rail, every id of a derived list scores ≥ its band × the rail's top score": _ruling_bands,
    "every priced-rail list has ≤ cap ids with non-decreasing cost per clean ride": _ruling_cheapest,
    "every anthropic and codex row is unpriced and each of their lists is strictly score-ascending": _ruling_subscription,
    "every id of a derived list is a candidate of its rail's source: openrouter = the OpenRouter view's ids priced at the selected endpoint; "
    "anthropic and codex = the policy's ids; opencode = the Go catalog's listed ids at the Go price, none a subscription rail's twin": _ruling_candidates,
    "every evidence row's `aa_id` is what `join_aa_id` returns over the store's benched ids": _ruling_join,
    "no id in a derived list has a null `aa_id`, nor a null price on a priced rail": _ruling_unbenched,
}
_INV = list(RULINGS)
RULING_ROWS = [
    pytest.param(_INV[0], "tiers.score: intelligence", "none", id="the score is the Artificial Analysis intelligence index ⚖"),
    pytest.param(_INV[1], "tiers.bands", "none", id="a tier is a band of the rail's best ⚖"),
    pytest.param(_INV[2], "tiers.cap", "none", id="each list is cheapest per clean ride first, capped ⚖"),
    pytest.param(_INV[3], "PRICELESS_RAILS", "none", id="the subscription rail has no price: score ascending is its cost proxy ⚖"),
    pytest.param(_INV[4], "the sources", "none", id="the candidates per rail ⚖"),
    pytest.param(_INV[5], "the rule", "none", id="the join to the AA row is a rule, not a table ⚖"),
    pytest.param(_INV[6], "derive", "none", id="unbenched never tiers ⚖"),
]


@pytest.mark.parametrize(("invariant", "expected_knob", "expected_violations"), RULING_ROWS, ids=[p.id for p in RULING_ROWS])
async def test_rulings(gw, app, policy, invariant, expected_knob, expected_violations):
    world(note=f"{WORLD}; a hand-written openrouter view + the rulings' three models")
    td = app.state.tier_derivation
    with given("the tier derivation's world with z-ai/glm-5.2 (no intelligence), fx/unbenched, fx/unpriced; "
               "rails.anthropic.models naming four aliases; one good refresh at T0"):
        _walk(policy, "anthropic")
        orv = ruling_view()
        td.or_view = lambda: orv
        attach_json("the OpenRouter view (the evidence)", orv)
        app.state.orcatalog.on_refresh()
        v = await tiers_view(gw)
        attach_json("GET /catalog/tiers (the derivation)", v)
    ev = Evidence(orv, td.go_view(), policy)
    assert v["rails"]["openrouter"]["tiers"]["light"]["list"] and v["rails"]["anthropic"]["tiers"]["heavy"]["list"], "the world derives lists to rule on"
    assert GLM52 in v["rails"]["openrouter"]["unscored"], "the world carries a benched row with no intelligence"
    with when(f"the invariant is evaluated over the derivation and its evidence: {invariant}"):
        knob, violations = RULINGS[invariant](v, ev, policy)
        attach_json("candidates per rail (the page's rule over the raw evidence)", ev.candidates)
    verdict(f"knob = {expected_knob} · violations = {expected_violations}",
            expected_knob={"expected": expected_knob, "actual": knob},
            expected_violations={"expected": expected_violations, "actual": joined(violations)},
            invariant={"actual": invariant})


# ── The evidence age ─────────────────────────────────────────────────────────────────────────
AGE_ROWS = [
    pytest.param("a derivation whose benched set is as of T0 − 600 s", "T0", "600", id="age is seconds since the walked derivation's benched `as_of` ⚖"),
    pytest.param("empty store", "T0", "absent", id="no derivation, no series"),
    pytest.param("a derivation as of T0, refreshes failing", "T0 + 43200 s", "43200", id="a kept derivation ages while refreshes fail"),
    pytest.param("a derivation with no `as_of`, fetched at T0 − 600 s", "T0", "600",
                 id="a benched set with no `as_of` ages from the OpenRouter snapshot's fetch ⚖"),
]


@pytest.mark.parametrize(("store_state", "read_at", "expected_age"), AGE_ROWS, ids=[p.id for p in AGE_ROWS])
async def test_evidence_age(gw, app, mcp, clock, store_state, read_at, expected_age):
    world(note=f"{WORLD}; a hand-written openrouter view, the real OpenRouter leg for the failing refresh")
    td = app.state.tier_derivation
    with given(f"store_state = {store_state}"):
        if store_state != "empty store":
            if "no `as_of`" in store_state:
                view = hand_view(at=T0 - 600, as_of=None)
            elif "T0 − 600 s" in store_state:
                view = hand_view(as_of=iso(T0 - 600))
            else:
                view = hand_view(as_of=iso(T0))
            td.or_view = lambda: view
            assert td.run()
            attach_json("the derivation's stamps", {k: v for k, v in (td.view()).items() if k != "rails"})
        clock.advance(at_offset(read_at))
        if "refreshes failing" in store_state:
            mcp.mcp = "503"
            with quiet():
                outcome = await app.state.orcatalog.refresh()
            assert outcome != "ok", "the refresh fails"
            attach_json("the failing refresh", {"outcome": outcome, "derived_at": td.view()["derived_at"]})
    with when(f"GET /metrics at {read_at}"):
        text = (await gw.get("/metrics")).text
    m = re.search(r"^gateway_tier_evidence_age_seconds (\S+)$", text, re.M)
    verdict(f"age = {expected_age}", expected_age={"expected": expected_age, "actual": num(float(m.group(1))) if m else "absent"},
            declared={"expected": True, "actual": "# TYPE gateway_tier_evidence_age_seconds gauge" in text}, store_state={"actual": store_state},
            read_at={"actual": read_at})
