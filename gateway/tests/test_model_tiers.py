"""GW-MODEL-TIERS — the deployed tier lists are derived from benchmark evidence: cost per clean ride,
the Go price, the bands, the id join, the manual benchmark rows, the tiers block, the rulings on the deployed files, the evidence
age (specs/endpoints/catalog.md §The tier evidence).

Worlds: hand-written cells, rails and AA id lists named in each row for the arithmetic (no gateway, no
upstream); `policy-default · openrouter-endpoints` with the Go catalog (catalog-ok + docs-ok, plan go:
fee $10/month; deepseek-v4.1-flash $80/month at list 0.15 in / 0.60 out) for the Go price; the
committed argocd/resources/agent-gateway/{benchmarks,policy}.json for the rulings and the deployed
policy (skipped when absent). The tables are the spec's, verbatim (the header is the parameter list).
"""

from __future__ import annotations

import copy
import dataclasses
import json
import math
import re
from pathlib import Path

import httpx
import pytest

from agent_gateway.app import create_app
from agent_gateway.config import CostPolicy, Policy, PolicyError, TiersPolicy, tiers_policy
from agent_gateway.tiers import (
    PRICELESS_RAILS,
    ManualError,
    apply_text,
    build_snapshot,
    check,
    clean_rate,
    cost_per_clean_ride,
    derive,
    join_aa_id,
    parse_manual,
    row_cost,
    same_model,
    undecided,
    unscored,
)

from ._catalog_rows import at_offset, joined, listed, num, verdict
from .conftest import (
    ISLAND,
    POLICY_FIXTURE,
    ObservedAsyncClient,
    attach_json,
    bearer,
    given,
    open_session,
    quiet,
    rule,
    when,
    world,
)

pytestmark = rule("GW-MODEL-TIERS")

DEPLOY = ISLAND.parent / "argocd" / "resources" / "agent-gateway"
DEPLOYED_POLICY = DEPLOY / "policy.json"
BENCHMARKS = DEPLOY / "benchmarks.json"
MANUAL_BENCHMARKS = DEPLOY / "benchmarks-manual.json"
SCHEMA = json.loads((Path(__file__).resolve().parents[1] / "specs" / "endpoints" / "catalog.schema.json").read_text(encoding="utf-8"))
GO_WORLD = "openrouter-endpoints + the Go catalog"
MESSAGES = "/anthropic/v1/messages"

COST = CostPolicy(0.01, 0.0, 5)  # the worlds' tiers.cost: 10k output tokens a ride, no strike overhead, 5 judged rides
RULES = TiersPolicy("intelligence", {"heavy": 0.9, "standard": 0.75, "light": 0.5}, 3, COST)
BLOCK = {"score": "intelligence", "bands": {"heavy": 0.9, "standard": 0.75, "light": 0.5}, "cap": 3,
         "cost": {"ride_tokens_out_m": 0.01, "strike_overhead_usd": 0, "min_rides": 5}}


def _row(score=None, out=None, inp=None, coding=None, aa=True) -> dict:
    return {"aa_id": "aa/row" if aa else None, "intelligence": score, "coding": coding, "agentic": None,
            "out_price": out, "in_price": inp, "monthly_limit_usd": None}


# rail fx: top 50 → heavy ≥ 45 {top, near}; standard ≥ 37.5 {+mid}; light ≥ 25 {+low}; far 20 out; none unbenched.
FX = {
    "fx/top": _row(50, 2.0, 0.5, coding=10),
    "fx/near": _row(46, 1.0, 0.2, coding=60),
    "fx/mid": _row(40, 0.5, 0.1, coding=55),
    "fx/low": _row(26, 0.1, 0.05, coding=50),
    "fx/far": _row(20, 0.05, 0.01, coding=5),
    "fx/none": _row(None, 0.0, 0.0, aa=False),
}
FXT = {"fxt/a": _row(40, 0.5, 0.2), "fxt/b": _row(44, 0.5, 0.1), "fxt/c": _row(44, 0.5, 0.2)}
SUB = {"claude/fx-a": _row(40), "claude/fx-b": _row(55), "claude/fx-c": _row(60)}
RAILS = {
    "fx": ("fx", FX),
    "fxt": ("fxt", FXT),
    "anthropic": ("anthropic", SUB),
    "fx + fx/mid rides 2 / 6": ("fx", {**FX, "fx/mid": {**FX["fx/mid"], "rides": {"clean": 2, "judged": 6, "prior": 1.0}}}),
    "fx + fx/nopx (49, no price)": ("fx", {**FX, "fx/nopx": _row(49, None, None)}),
    "fx + fx/noscore (no intelligence, coding 70)": ("fx", {**FX, "fx/noscore": _row(None, 0.01, 0.01, coding=70)}),
    "fx-empty": ("fx-empty", {"fx/none": FX["fx/none"]}),
    "fx-unpriced": ("fx-unpriced", {"fx/a": _row(50, None, None)}),
}


def _bench(**rails) -> dict:
    return {"snapshot_at": "2027-01-15T08:00:00Z", "sources": {}, "rails": rails}


# ── Cost per clean ride ──────────────────────────────────────────────────────────────────────
COST_ROWS = [
    pytest.param("0.42", "0 / 0", "1", "0.01 · 0 · 5", "1", "prior", "0.0042", id="a clean cell costs its price for one ride's tokens ⚖"),
    pytest.param("0.42", "2 / 4", "0.9", "0.01 · 0 · 5", "0.9", "prior", "0.004667", id="under min_rides the prior stands ⚖"),
    pytest.param("0.42", "3 / 6", "1", "0.01 · 0 · 5", "0.5", "measured", "0.0084", id="a measured clean rate of one half doubles the cost ⚖"),
    pytest.param("0.42", "3 / 6", "1", "0.01 · 0.1 · 5", "0.5", "measured", "0.1084", id="the strike overhead is paid once per failed ride ⚖"),
    pytest.param("0.42", "0 / 5", "1", "0.01 · 0 · 5", "0", "measured", "inf", id="a cell with no clean ride yet is unaffordable ⚖"),
]


@pytest.mark.parametrize(("out_price", "rides", "prior", "terms", "expected_rate", "expected_basis", "expected_cost"), COST_ROWS,
                         ids=[p.id for p in COST_ROWS])
def test_cost_per_clean_ride(out_price, rides, prior, terms, expected_rate, expected_basis, expected_cost):
    world(note="a hand-written cell")
    clean, judged = (int(x) for x in rides.split(" / "))
    t, o, mr = terms.split(" · ")
    pol = CostPolicy(float(t), float(o), int(mr))
    with given(f"a cell: out_price = {out_price} $/M · rides = {rides} (clean / judged) · prior = {prior}; tiers.cost terms = {terms}"):
        attach_json("cell", {"out_price": float(out_price), "rides": {"clean": clean, "judged": judged, "prior": float(prior)}, "cost": dataclasses.asdict(pol)})
    with when("clean_rate(clean, judged, prior, min_rides), then cost_per_clean_ride(out_price, rate, cost)"):
        r, basis = clean_rate(clean, judged, float(prior), pol.min_rides)
        c = cost_per_clean_ride(float(out_price), r, pol)
    verdict(f"rate = {expected_rate} · basis = {expected_basis} · cost = {expected_cost}",
            expected_rate={"expected": expected_rate, "actual": num(round(r, 6))},
            expected_basis={"expected": expected_basis, "actual": basis.split(" ")[0]},
            expected_cost={"expected": expected_cost, "actual": num(round(c, 6)) if math.isfinite(c) else "inf"},
            out_price={"actual": out_price}, rides={"actual": rides}, prior={"actual": prior}, terms={"actual": terms})


# ── The Go price ─────────────────────────────────────────────────────────────────────────────
NOTHING = "nothing"
RIDE = "one ride at T0 + 2 h: in 1000M, out 100M"
NO_FEES = "the docs snapshot without plan_fees"
PRICE_ROWS = [
    pytest.param(NOTHING, "deepseek-v4.1-flash", "0.125", "promise", "0.075", "0.01875", id="the plan's promise prices an idle rail ⚖"),
    pytest.param(NOTHING, "claude-haiku-5-5", "0.666667", "promise", "0.333333", "0.066667", id="each model's own allowance is its promise ⚖"),
    pytest.param(RIDE, "deepseek-v4.1-flash", "0.047619", "measured", "0.028571", "0.007143", id="a rail drawing past the allowance is priced on the meter ⚖"),
    pytest.param(NOTHING, "longcat-2.5-preview-free", "0", "unlimited", "0", "0", id="an unlimited model prices at 0 ⚖"),
    pytest.param(NO_FEES, "deepseek-v4.1-flash", "none", "none", "none", "none", id="no fee read: no price ⚖"),
]


async def _go_ride(gw, upstreams, usage: dict, tier: str = "light", task: str = "homelab-2743-draw") -> dict:
    with quiet():
        doc = await open_session(gw, role="worker", rail="opencode", tier=tier, task=task)
        up = upstreams["opencode"]
        up.usage = usage
        r = await gw.post(MESSAGES, headers=bearer(doc), json={"max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]})
        up.usage = None
    attach_json(f"arranged Go ride: {doc['model']} usage {usage} → {r.status_code}", {"session": doc["session"]["id"], "usage": usage, "status": r.status_code})
    return doc


def _pricing(app) -> dict:
    return app.state.capacity.go_pricing("opencode", app.state.sessions.clock())


def _r6(v) -> str:
    return "none" if v is None else num(round(v, 6))


@pytest.mark.parametrize(("ledger", "model", "expected_discount", "expected_basis", "expected_out", "expected_in"), PRICE_ROWS, ids=[p.id for p in PRICE_ROWS])
async def test_go_price(gw, app, upstreams, clock, ledger, model, expected_discount, expected_basis, expected_out, expected_in):
    world(upstream="upstream-ok" if ledger == RIDE else None, note=f"{GO_WORLD}; ledger {ledger}")
    with given(f"ledger = {ledger}"):
        if ledger == RIDE:
            clock.advance(7200)
            await _go_ride(gw, upstreams, {"input_tokens": 1_000_000_000, "output_tokens": 100_000_000})
        elif ledger == NO_FEES:
            del app.state.catalog.snapshots["docs"].body["plan_fees"]
    with when(f"capacity.go_pricing(opencode) → models.{model}"):
        p = _pricing(app)
        attach_json("pricing", p)
        row = p["models"][model]
    verdict(f"discount = {expected_discount} · basis = {expected_basis} · out = {expected_out} · in = {expected_in}",
            expected_discount={"expected": expected_discount, "actual": _r6(row["discount"])},
            expected_basis={"expected": expected_basis, "actual": row["basis"] or "none"},
            expected_out={"expected": expected_out, "actual": _r6(row["out"])},
            expected_in={"expected": expected_in, "actual": _r6(row["in"])},
            draw_30d_usd={"actual": p["draw_30d_usd"]}, ledger={"actual": ledger}, model={"actual": model})


VIEW_ROWS = [pytest.param(NOTHING, "10", "0", "out 0.075, in 0.01875, discount 0.125, basis promise, rides 0 / 0", id="the price shows on GET /catalog/opencode ⚖")]


@pytest.mark.parametrize(("ledger", "expected_fee", "expected_draw_30d", "expected_deepseek_v4_1_flash"), VIEW_ROWS, ids=[p.id for p in VIEW_ROWS])
async def test_go_price_view(gw, ledger, expected_fee, expected_draw_30d, expected_deepseek_v4_1_flash):
    world(note=f"{GO_WORLD}; ledger {ledger}")
    with given(f"ledger = {ledger}"):
        pass
    with when("GET /catalog/opencode → pricing"):
        p = (await gw.get("/catalog/opencode")).json()["pricing"]
    m = p["models"]["deepseek-v4.1-flash"]
    cell = f"out {num(m['out'])}, in {num(m['in'])}, discount {num(m['discount'])}, basis {m['basis']}, rides {m['rides']['clean']} / {m['rides']['judged']}"
    verdict(f"fee = {expected_fee} · draw_30d = {expected_draw_30d} · deepseek_v4_1_flash = {expected_deepseek_v4_1_flash}",
            expected_fee={"expected": expected_fee, "actual": num(p["fee_usd_month"])},
            expected_draw_30d={"expected": expected_draw_30d, "actual": num(p["draw_30d_usd"])},
            expected_deepseek_v4_1_flash={"expected": expected_deepseek_v4_1_flash, "actual": cell},
            ledger={"actual": ledger})


# ── The bands, on a hand-written rail ────────────────────────────────────────────────────────
BAND_ROWS = [
    pytest.param("fx", "intelligence", "heavy", "fx/near, fx/top", id="heavy = within 0.90 of the rail's top, cheapest first ⚖"),
    pytest.param("fx", "intelligence", "standard", "fx/mid, fx/near, fx/top", id="standard = within 0.75 ⚖"),
    pytest.param("fx", "intelligence", "light", "fx/low, fx/mid, fx/near", id="light = within 0.50, the cap drops the 4th by price ⚖"),
    pytest.param("fxt", "intelligence", "heavy", "fxt/b, fxt/c, fxt/a", id="a price tie breaks by input price, then score, then id ⚖"),
    pytest.param("fx", "coding", "heavy", "fx/mid, fx/near", id="the axis is the policy's: the same rail under `score: coding`"),
    pytest.param("anthropic", "intelligence", "light · standard · heavy",
                 "claude/fx-a, claude/fx-b, claude/fx-c · claude/fx-b, claude/fx-c · claude/fx-b, claude/fx-c",
                 id="the subscription rail orders by score ascending ⚖"),
    pytest.param("fx + fx/mid rides 2 / 6", "intelligence", "standard", "fx/near, fx/mid, fx/top", id="a measured clean rate reorders a list ⚖"),
]


@pytest.mark.parametrize(("rail", "score", "tier", "expected_list"), BAND_ROWS, ids=[p.id for p in BAND_ROWS])
def test_bands(rail, score, tier, expected_list):
    world(note=f"a hand-written snapshot: rail {rail}")
    name, rows = RAILS[rail]
    rules = TiersPolicy(score, RULES.bands, RULES.cap, COST)
    with given(f"rail = {rail} ({len(rows)} candidates) · score = {score}; bands {rules.bands}, cap {rules.cap}, tiers.cost 0.01 · 0 · 5"):
        attach_json(f"rail {name}", rows)
        if "rides" in rail:
            attach_json("cost per clean ride", {pid: row_cost(r, COST) for pid, r in rows.items() if r["aa_id"]})
    with when(f"derive(snapshot, tiers) → {name}.{tier}"):
        lists = derive(_bench(**{name: rows}), rules)
    got = " · ".join(joined(lists[name][t]) for t in tier.split(" · "))
    verdict(f"list = {expected_list}", expected_list={"expected": expected_list, "actual": got},
            rail={"actual": rail}, score={"actual": score}, tier={"actual": tier})


HOLD_ROWS = [
    pytest.param("fx", "fx/near", "heavy, light, standard", "fx/near, fx/top", id="a model sits in several tiers"),
    pytest.param("fx", "fx/none", "none", "fx/near, fx/top", id="an unbenched candidate never tiers, however cheap ⚖"),
    pytest.param("fx + fx/nopx (49, no price)", "fx/nopx", "none", "fx/near, fx/top", id="an unpriced candidate on a priced rail never tiers ⚖"),
    pytest.param("fx + fx/noscore (no intelligence, coding 70)", "fx/noscore", "none", "fx/near, fx/top",
                 id="a benched candidate with no value on the score axis never tiers, however cheap ⚖"),
]


@pytest.mark.parametrize(("rail", "candidate", "expected_tiers", "expected_heavy"), HOLD_ROWS, ids=[p.id for p in HOLD_ROWS])
def test_which_tiers_hold(rail, candidate, expected_tiers, expected_heavy):
    world(note=f"a hand-written snapshot: rail {rail}")
    name, rows = RAILS[rail]
    with given(f"rail = {rail} · candidate = {candidate}: {rows[candidate]}"):
        attach_json(f"rail {name}", rows)
    with when("derive(snapshot, tiers)"):
        lists = derive(_bench(**{name: rows}), RULES)
    verdict(f"tiers = {expected_tiers} · heavy = {expected_heavy}",
            expected_tiers={"expected": expected_tiers, "actual": joined(sorted(t for t, ids in lists[name].items() if candidate in ids))},
            expected_heavy={"expected": expected_heavy, "actual": joined(lists[name]["heavy"])},
            rail={"actual": rail}, candidate={"actual": candidate})


EMPTY_ROWS = [
    pytest.param("fx-empty", "[] · [] · []", "light, standard, heavy", "{}", "refuses, naming fx-empty.light",
                 id="no benched candidate: empty lists, which apply refuses to write"),
    pytest.param("fx-unpriced", "[] · [] · []", "light, standard, heavy", "{}", "refuses, naming fx-unpriced.light",
                 id="a tier with no priced candidate is undecided: check passes it, apply refuses it ⚖"),
]


@pytest.mark.parametrize(("rail", "expected_derived", "expected_undecided", "expected_check", "expected_apply"), EMPTY_ROWS, ids=[p.id for p in EMPTY_ROWS])
def test_empty_and_undecided(rail, expected_derived, expected_undecided, expected_check, expected_apply):
    world(note=f"a hand-written snapshot: rail {rail}")
    name, rows = RAILS[rail]
    (only,) = rows
    policy = {"rails": {name: {"models": {"light": [only], "standard": [only], "heavy": [only]}}}, "tiers": BLOCK}
    with given(f"rail = {rail}: {rows}; a policy whose three lists name {only}"):
        attach_json(f"rail {name}", rows)
    with when("derive, undecided, check(policy, snapshot), apply_text(policy text, the derivation)"):
        bench = _bench(**{name: rows})
        lists = derive(bench, RULES)
        und = undecided(bench, RULES)
        mismatches = check(policy, bench)
        try:
            apply_text(json.dumps(policy, indent=2), lists)
            error = None
        except ValueError as e:
            error = str(e)
        attach_json("result", {"derived": lists, "undecided": und, "check": mismatches, "apply error": error})
    verdict(f"derived = {expected_derived} · undecided = {expected_undecided} · check = {expected_check} · apply = {expected_apply}",
            expected_derived={"expected": expected_derived, "actual": " · ".join(f"[{', '.join(lists[name][t])}]" for t in ("light", "standard", "heavy"))},
            expected_undecided={"expected": expected_undecided, "actual": joined(und.get(name, []))},
            expected_check={"expected": expected_check, "actual": json.dumps(mismatches)},
            expected_apply={"expected": expected_apply, "actual": "writes" if error is None else (expected_apply if expected_apply.endswith(f"naming {name}.light") and f"{name}.light" in error else f"refuses: {error}")},
            rail={"actual": rail})


# ── The id join ──────────────────────────────────────────────────────────────────────────────
HAIKU = "anthropic/claude-haiku-5.5, anthropic/claude-haiku-4.5"
GLM = "z-ai/glm-5.3, z-ai/glm-5.3-flash"
OPUS = "anthropic/claude-opus-5, anthropic/claude-opus-5.5, anthropic/claude-opus-4.1"
JOIN_ROWS = [
    pytest.param("opencode-go/claude-haiku-5-5", HAIKU, "anthropic/claude-haiku-5.5", id="a Go id joins the dotted AA id ⚖"),
    pytest.param("opencode-go/glm-5.3", GLM, "z-ai/glm-5.3", id="a dotted Go id joins as is"),
    pytest.param("opencode-go/beam-free", f"{HAIKU}, {GLM}", "none", id="a Go id the table lacks is unbenched"),
    pytest.param("opencode-go/hy3", "tencent/hy3-preview", "none", id="a suffix is not a match"),
    pytest.param("opencode-go/gpt-6-luna", "openai/gpt-6-luna, other/gpt-6-luna", "none", id="two vendors' rows for one bare id: unbenched ⚖"),
    pytest.param("claude/opus", OPUS, "anthropic/claude-opus-5.5", id="an alias joins the newest row of its family by version ⚖"),
    pytest.param("claude/haiku", OPUS, "none", id="an alias with no row of its family is unbenched"),
    pytest.param("deepseek/deepseek-v4-flash", "deepseek/deepseek-v4-flash, other/deepseek-v4-flash", "deepseek/deepseek-v4-flash", id="an openrouter id keeps its vendor"),
    pytest.param("inclusionai/ling-3.0-flash:free", "inclusionai/ling-3.0-flash", "inclusionai/ling-3.0-flash", id="a `:free` variant joins its family ⚖"),
]


@pytest.mark.parametrize(("policy_id", "aa_ids", "expected_joins"), JOIN_ROWS, ids=[p.id for p in JOIN_ROWS])
def test_join(policy_id, aa_ids, expected_joins):
    world(note="a hand-written AA id list")
    with given(f"policy_id = {policy_id} · aa_ids = {aa_ids}"):
        attach_json("aa ids", listed(aa_ids))
    with when(f"join_aa_id({policy_id!r}, aa_ids)"):
        got = join_aa_id(policy_id, listed(aa_ids)) or "none"
    verdict(f"joins = {expected_joins}", expected_joins={"expected": expected_joins, "actual": got}, policy_id={"actual": policy_id}, aa_ids={"actual": aa_ids})


# ── The manual benchmark rows ────────────────────────────────────────────────────────────────
MANUAL_URL, MANUAL_READ = "https://bench.example/fx", "2027-01-10"
FEED_51 = "anthropic/claude-fx-5.1 = 50"
MANUAL_ROWS = [
    # the feed lacks 5.2 → the alias joins the newest id, the manual one, and takes ITS score (65), marked
    pytest.param(FEED_51, "anthropic/claude-fx-5.2 = 65", "claude/fx", "anthropic/claude-fx-5.2", "65",
                 f"manual · {MANUAL_URL} · {MANUAL_READ}", "none", id="a manual row scores an id the feed lacks ⚖"),
    # the feed carries 5.2 at 63 → the feed's 63 stands (not the manual 65), unmarked; the manual id is retired
    pytest.param(f"{FEED_51}, anthropic/claude-fx-5.2 = 63", "anthropic/claude-fx-5.2 = 65", "claude/fx", "anthropic/claude-fx-5.2", "63",
                 "feed", "anthropic/claude-fx-5.2", id="the feed wins the moment it carries the id: the manual row is retired ⚖"),
    pytest.param(FEED_51, "none", "claude/fx", "anthropic/claude-fx-5.1", "50", "feed", "none", id="no manual file: the feed alone scores"),
    pytest.param(FEED_51, "anthropic/claude-fy-2.0 = 65", "claude/fx", "anthropic/claude-fx-5.1", "50", "feed", "none",
                 id="a manual row for another family marks no row"),
    # the join rule is untouched: newest by version is the FEED's 5.2, so the manual 5.1 scores nothing
    pytest.param("anthropic/claude-fx-5.2 = 63", "anthropic/claude-fx-5.1 = 65", "claude/fx", "anthropic/claude-fx-5.2", "63", "feed", "none",
                 id="a manual row older than the feed's newest does not score: the join is still newest-by-version"),
]


def _scored(cell: str) -> dict[str, float]:
    """`id = score, id = score` → {id: score}; `none` → {}."""
    return {} if cell == "none" else {k.strip(): float(v) for k, v in (pair.split(" = ") for pair in cell.split(", "))}


def _manual_doc(cell: str) -> dict | None:
    if cell == "none":
        return None
    return {"rows": [{"id": i, "intelligence": s, "coding": None, "agentic": None, "source_url": MANUAL_URL, "read_at": MANUAL_READ, "note": "fx"}
                     for i, s in _scored(cell).items()]}


@pytest.mark.parametrize(("feed", "manual", "policy_id", "expected_aa_id", "expected_intelligence", "expected_score_source", "expected_retired"),
                         MANUAL_ROWS, ids=[p.id for p in MANUAL_ROWS])
def test_manual_rows(feed, manual, policy_id, expected_aa_id, expected_intelligence, expected_score_source, expected_retired):
    world(note="a hand-written feed and manual file; empty Go and OpenRouter catalogs")
    capability = [[i, "artificial-analysis", s, None, None, 1_800_000_000.0] for i, s in _scored(feed).items()]
    doc = _manual_doc(manual)
    with given(f"feed = {feed} · manual = {manual} · policy_id = {policy_id}"):
        attach_json("capability rows", capability)
        attach_json("manual file", doc)
    with when(f"build_snapshot(capability, …, anthropic_aliases=[{policy_id!r}], manual) → rails.anthropic.{policy_id}"):
        snap = build_snapshot(capability=capability, go_catalog={"models": {}, "sources": {"config": {"fetched_at": None}}}, openrouter_catalog={},
                              anthropic_aliases=[policy_id], snapshot_at="2027-01-15T08:00:00Z", manual=doc)
        row = snap["rails"]["anthropic"][policy_id]
        attach_json("snapshot row", row)
        attach_json("sources.capability", snap["sources"]["capability"])
    marks = [row.get(k) for k in ("score_source", "score_source_url", "score_read_at")]
    source = "feed" if not any(k.startswith("score_") for k in row) else " · ".join(str(m) for m in marks)
    hand = snap["sources"]["capability"].get("manual")
    assert (hand is None) == (doc is None), "sources.capability.manual is present exactly when a manual file was read"
    verdict(f"aa_id = {expected_aa_id} · intelligence = {expected_intelligence} · score_source = {expected_score_source} · retired = {expected_retired}",
            expected_aa_id={"expected": expected_aa_id, "actual": row["aa_id"]},
            expected_intelligence={"expected": expected_intelligence, "actual": num(row["intelligence"])},
            expected_score_source={"expected": expected_score_source, "actual": source},
            expected_retired={"expected": expected_retired, "actual": joined((hand or {}).get("retired", []))},
            feed={"actual": feed}, manual={"actual": manual}, policy_id={"actual": policy_id})


COMMITTED = "the committed file"
MANUAL_SHAPE_ROWS = [
    pytest.param(COMMITTED, "loads", id="the committed file loads"),
    pytest.param("as is", "loads", id="a complete row loads"),
    pytest.param("rows.0.source_url dropped", "refused, naming source_url", id="a score with no source is refused ⚖"),
    pytest.param('rows.0.read_at = "last week"', "refused, naming rows[0].read_at", id="a score with no date read is refused ⚖"),
    pytest.param("rows.0.intelligence = null", "refused, naming no score", id="a row with no score is refused"),
    pytest.param('rows.0.intelligence = "65"', "refused, naming rows[0].intelligence", id="a score that is not a number is refused"),
    pytest.param('rows.0.id = "fx"', "refused, naming rows[0].id", id="an id that is not vendor/model is refused"),
    pytest.param("rows.0 twice", "refused, naming duplicate", id="one id twice is refused"),
    pytest.param("rows.0.weight = 2", "refused, naming weight", id="an unknown key is refused"),
    pytest.param("scores = []", "refused, naming scores", id="an unknown top-level key is refused"),
]


@pytest.mark.parametrize(("manual", "expected_load"), MANUAL_SHAPE_ROWS, ids=[p.id for p in MANUAL_SHAPE_ROWS])
def test_manual_shape(manual, expected_load):
    world(note="a hand-written manual file" if manual != COMMITTED else "against the committed manual file")
    if manual == COMMITTED:
        if not MANUAL_BENCHMARKS.exists():
            pytest.skip("deploy manifests absent (service-only checkout)")
        doc = json.loads(MANUAL_BENCHMARKS.read_text(encoding="utf-8"))
    else:
        doc = _manual_doc("anthropic/claude-fx-5.2 = 65")
    with given(f"manual = {manual}"):
        if manual == "rows.0 twice":
            doc["rows"].append(dict(doc["rows"][0]))
        elif manual not in (COMMITTED, "as is"):
            dropped = manual.endswith(" dropped")
            path, raw = (manual[: -len(" dropped")], None) if dropped else manual.split(" = ", 1)
            node = doc
            *parents, leaf = path.split(".")
            for k in parents:
                node = node[int(k)] if k.isdigit() else node[k]
            if dropped:
                del node[leaf]
            else:
                node[leaf] = json.loads(raw)
        attach_json("manual file", doc)
    with when("parse_manual(the document)"):
        try:
            rows, error = parse_manual(doc), None
        except ManualError as e:
            rows, error = None, str(e)
        attach_json("result", {"rows": rows, "error": error})
    if error is None:
        assert rows and set(rows) == {r["id"] for r in doc["rows"]}, "a loaded file yields every row, keyed by id"
    verdict(f"load = {expected_load}", expected_load={"expected": expected_load, "actual": _load_cell(error, expected_load, "loads")}, manual={"actual": manual})


# ── The tiers block ──────────────────────────────────────────────────────────────────────────
BLOCK_ROWS = [
    pytest.param("the world's", "loads; Policy.tiers = the world's block", id="the block loads"),
    pytest.param("foo = 1", "refused, naming tiers", id="an unknown key refuses the load"),
    pytest.param('score = "vibes"', "refused, naming tiers.score", id="an unknown score axis refuses the load"),
    pytest.param("bands.light dropped", "refused, naming light", id="a missing tier band refuses the load"),
    pytest.param("cap = 0", "refused, naming tiers.cap", id="a non-positive cap refuses the load"),
    pytest.param("bands.heavy = 1.5", "refused, naming tiers.bands.heavy", id="a band above 1 refuses the load"),
    pytest.param("bands.light = 0", "refused, naming tiers.bands.light", id="a zero band refuses the load"),
    pytest.param("bands.standard = 0.95", "refused, naming heavy >= standard >= light", id="bands out of order refuse the load"),
    pytest.param("cost dropped", "refused, naming tiers.cost", id="no cost terms refuse the load ⚖"),
    pytest.param("cost.ride_tokens_out_m = 0", "refused, naming tiers.cost.ride_tokens_out_m", id="a non-positive ride size refuses the load"),
    pytest.param("cost.min_rides = 0", "refused, naming tiers.cost.min_rides", id="a non-positive min_rides refuses the load"),
]
DROP = object()


def _apply_edit(doc: dict, edit: str) -> None:
    """`<path> = <json value>` sets, `<path> dropped` deletes, under `tiers`."""
    if edit.endswith(" dropped"):
        path, value = edit[: -len(" dropped")], DROP
    else:
        path, raw = edit.split(" = ", 1)
        value = json.loads(raw)
    node = doc["tiers"]
    *parents, leaf = path.split(".")
    for k in parents:
        node = node[k]
    if value is DROP:
        del node[leaf]
    else:
        node[leaf] = value


def _load(doc: dict) -> tuple[Policy | None, str | None]:
    try:
        return Policy.from_dict(doc), None
    except PolicyError as e:
        return None, str(e)


def _load_cell(error: str | None, expected: str, loads_text: str) -> str:
    if error is None:
        return loads_text
    if expected.startswith("refused, naming ") and expected[len("refused, naming "):] in error:
        return expected
    return f"refused: {error}"


@pytest.mark.parametrize(("tiers", "expected_load"), BLOCK_ROWS, ids=[p.id for p in BLOCK_ROWS])
def test_tiers_block(tiers, expected_load):
    world()
    doc = json.loads(POLICY_FIXTURE.read_text(encoding="utf-8"))
    with given(f"policy-default with tiers = {tiers}"):
        if tiers != "the world's":
            _apply_edit(doc, tiers)
        attach_json("tiers", doc["tiers"])
    with when("the policy loads"):
        loaded, error = _load(doc)
        attach_json("load result", {"loaded": loaded is not None, "error": error})
    loads_text = "loads; Policy.tiers = the world's block" if loaded is not None and loaded.tiers == TiersPolicy(BLOCK["score"], BLOCK["bands"], BLOCK["cap"], COST) \
        else f"loads; Policy.tiers = {loaded.tiers!r}" if loaded is not None else ""
    verdict(f"load = {expected_load}", expected_load={"expected": expected_load, "actual": _load_cell(error, expected_load, loads_text)}, tiers={"actual": tiers})


NO_BLOCK_ROWS = [pytest.param("absent", "loads; Policy.tiers None", "raises naming tiers", id="no block: the policy loads with no rules, and the check refuses to run ⚖")]


@pytest.mark.parametrize(("tiers", "expected_load", "expected_check"), NO_BLOCK_ROWS, ids=[p.id for p in NO_BLOCK_ROWS])
def test_no_block(tiers, expected_load, expected_check):
    world()
    doc = json.loads(POLICY_FIXTURE.read_text(encoding="utf-8"))
    with given(f"policy-default with tiers = {tiers}"):
        del doc["tiers"]
    with when("the policy loads, then check(policy, a snapshot)"):
        loaded, error = _load(doc)
        try:
            check(doc, _bench(fx=FX))
            check_error = None
        except ValueError as e:
            check_error = str(e)
        attach_json("result", {"tiers": loaded.tiers if loaded else None, "load error": error, "check error": check_error})
    verdict(f"load = {expected_load} · check = {expected_check}",
            expected_load={"expected": expected_load, "actual": f"loads; Policy.tiers {loaded.tiers!r}" if loaded is not None else f"refused: {error}"},
            expected_check={"expected": expected_check, "actual": "raises naming tiers" if check_error and "tiers" in check_error else f"check: {check_error!r}"},
            tiers={"actual": tiers})


# ── The rulings, on the deployed files ────────────────────────────────────────────────────────
deployed = pytest.mark.skipif(not (DEPLOYED_POLICY.exists() and BENCHMARKS.exists()), reason="deploy manifests absent (service-only checkout)")


def _deployed() -> tuple[dict, dict]:
    return (json.loads(DEPLOYED_POLICY.read_text(encoding="utf-8")), json.loads(BENCHMARKS.read_text(encoding="utf-8")))


def _pool(rows: dict, rail: str, axis: str) -> dict:
    """The tierable candidates of a rail as derive sees them: benched, and priced on a priced rail."""
    return {pid: r for pid, r in rows.items() if r["aa_id"] and r[axis] is not None and (rail in PRICELESS_RAILS or r["out_price"] is not None)}


def _listed(policy: dict, rail: str) -> dict[str, list[str]]:
    return {t: ([v] if isinstance(v, str) else list(v)) for t, v in policy["rails"][rail]["models"].items()}


def _ruling_score(policy, bench):
    """The axis is the knob; a benched row with no value on it is in no pool — and is named, by `unscored`, not dropped."""
    tp = tiers_policy(policy["tiers"])
    axis = tp.score
    benched = {f"{rail}:{pid}": r for rail, rows in bench["rails"].items() for pid, r in rows.items() if r["aa_id"]}
    without = sorted(k for k, r in benched.items() if r[axis] is None)  # the snapshot's own nulls, read here — not through tiers
    named = sorted(f"{rail}:{pid}" for rail, ids in unscored(bench, tp).items() for pid in ids)
    und = undecided(bench, tp)
    violations = [f"{k} is benched with no {axis}, and `unscored` does not name it" for k in without if k not in named]
    violations += [f"`unscored` names {k}, which carries {axis} or is unbenched" for k in named if k not in without]
    violations += sorted(f"{rail}.{tier}:{pid} derived with no {axis}" for rail, lists in derive(bench, tp).items() for tier, ids in lists.items()
                         for pid in ids if f"{rail}:{pid}" in without)
    violations += sorted(f"{rail}.{tier}:{pid} deployed with no {axis}" for rail in bench["rails"] for tier, ids in _listed(policy, rail).items()
                         if tier not in und.get(rail, []) for pid in ids if bench["rails"][rail][pid][axis] is None)
    if not any(r["coding"] is None for r in benched.values()):
        violations.append("every benched row carries coding")
    return f"tiers.score: {axis}", violations, {"benched": len(benched), f"with {axis}": len(benched) - len(without), f"without {axis} (in no pool)": without,
                                               "with coding": sum(r["coding"] is not None for r in benched.values())}


def _ruling_bands(policy, bench):
    axis, bands = policy["tiers"]["score"], policy["tiers"]["bands"]
    und = undecided(bench, tiers_policy(policy["tiers"]))
    tops = {rail: max(r[axis] for r in _pool(rows, rail, axis).values()) for rail, rows in bench["rails"].items() if _pool(rows, rail, axis)}
    below = sorted(f"{rail}.{tier}:{pid}" for rail in tops for tier, ids in _listed(policy, rail).items() if tier not in und.get(rail, [])
                   for pid in ids if bench["rails"][rail][pid][axis] < bands[tier] * tops[rail])
    return "tiers.bands: " + ", ".join(f"{t} {num(bands[t])}" for t in ("heavy", "standard", "light")), below, {"tops": tops, "undecided": und}


def _ruling_cheapest(policy, bench):
    tp = tiers_policy(policy["tiers"])
    und = undecided(bench, tp)
    priced = {rail: {tier: [(pid, row_cost(bench["rails"][rail][pid], tp.cost)) for pid in ids]
                     for tier, ids in _listed(policy, rail).items() if tier not in und.get(rail, [])}
              for rail in bench["rails"] if rail not in PRICELESS_RAILS}
    over = [f"{rail}.{tier} over the cap" for rail, ts in priced.items() for tier, ids in ts.items() if len(ids) > tp.cap]
    unsorted = [f"{rail}.{tier} not cost-ascending" for rail, ts in priced.items() for tier, ids in ts.items() if [c for _, c in ids] != sorted(c for _, c in ids)]
    return f"tiers.cap: {tp.cap}", over + unsorted, {"lists with costs": priced}


def _ruling_subscription(policy, bench):
    axis = policy["tiers"]["score"]
    violations = []
    for rail in PRICELESS_RAILS:
        violations += [f"{rail}:{pid} priced" for pid, r in bench["rails"][rail].items() if r["out_price"] is not None or r["in_price"] is not None]
        for tier, ids in _listed(policy, rail).items():
            scores = [bench["rails"][rail][pid][axis] for pid in ids]
            if scores != sorted(set(scores)):
                violations.append(f"{rail}.{tier} not strictly score-ascending")
    return "PRICELESS_RAILS: " + ", ".join(PRICELESS_RAILS), violations, {"scored lists": {rail: {t: [(pid, bench["rails"][rail][pid][axis]) for pid in ids] for t, ids in _listed(policy, rail).items()} for rail in PRICELESS_RAILS}}


def _ruling_candidates(policy, bench):
    rails = bench["rails"]
    anth = policy["rails"]["anthropic"]
    aliases = sorted({x for lst in anth["models"].values() for x in ([lst] if isinstance(lst, str) else lst)} | set(anth.get("side_models", [])))
    codex_ids = sorted({x for lst in policy["rails"]["codex"]["models"].values() for x in ([lst] if isinstance(lst, str) else lst)})
    tp = tiers_policy(policy["tiers"])
    sub_aa = [r["aa_id"] for rail_ in PRICELESS_RAILS for r in rails[rail_].values() if r.get("aa_id")]
    benched = {k: float(r[tp.score]) for k, r in rails["codex"].items() if r.get("aa_id") and isinstance(r.get(tp.score), int | float)}
    top = max(benched.values(), default=0.0)
    v = []
    v += [f"opencode key not opencode-go/<id>: {k}" for k in rails["opencode"] if not k.startswith("opencode-go/")]
    v += [f"opencode key a subscription rail serves: {k}" for k in rails["opencode"] if any(same_model(k, aa) for aa in sub_aa)]
    v += [f"opencode price_basis {b}" for b in sorted({r["price_basis"] for r in rails["opencode"].values()} - {"promise", "measured", "unlimited", None}, key=str)]
    v += [f"openrouter key not vendor/model: {k}" for k in rails["openrouter"] if k.count("/") != 1 or k.startswith(("opencode-go/", "claude/"))]
    v += [f"openrouter {k} priced off its selected endpoint: {r['price_basis']}/{r['provider']}" for k, r in rails["openrouter"].items()
          if r["price_basis"] not in ("endpoint", None) or (r["price_basis"] == "endpoint") != (r["provider"] is not None)]
    if sorted(rails["anthropic"]) != aliases:
        v.append(f"anthropic keys {sorted(rails['anthropic'])} ≠ the deployed aliases {aliases}")
    v += [f"anthropic {k} priced" for k, r in rails["anthropic"].items() if r["out_price"] is not None]
    v += [f"deployed codex id missing from the snapshot: {i}" for i in codex_ids if i not in rails["codex"]]
    v += [f"codex key on no list yet benched within a band: {k}" for k in rails["codex"] if k not in codex_ids and k in benched and benched[k] >= min(tp.bands.values()) * top]
    v += [f"codex {k} priced" for k, r in rails["codex"].items() if r["out_price"] is not None]
    if bench["sources"]["openrouter_catalog"].get("fetched_at") is None:
        v.append("sources.openrouter_catalog.fetched_at absent")
    return f"sources.capability.source: {bench['sources']['capability']['source']}", v, {"anthropic aliases": aliases, "codex ids": codex_ids}


def _ruling_join(policy, bench):
    aa_ids = sorted({r["aa_id"] for rows in bench["rails"].values() for r in rows.values() if r["aa_id"]})
    differs = sorted(f"{rail}:{pid} aa_id {r['aa_id']} ≠ {join_aa_id(pid, aa_ids)}" for rail, rows in bench["rails"].items() for pid, r in rows.items()
                     if join_aa_id(pid, aa_ids) != r["aa_id"])
    return "the rule", differs, {"aa ids in the snapshot": aa_ids}


def _ruling_unbenched(policy, bench):
    und = undecided(bench, tiers_policy(policy["tiers"]))
    listed_ = {f"{rail}.{tier}:{pid}": bench["rails"][rail][pid] for rail in bench["rails"] for tier, ids in _listed(policy, rail).items()
               if tier not in und.get(rail, []) for pid in ids}
    v = [f"{k} has no AA row" for k, r in listed_.items() if r["aa_id"] is None]
    v += [f"{k} unpriced on a priced rail" for k, r in listed_.items() if not k.startswith(tuple(f"{p}." for p in PRICELESS_RAILS)) and r["out_price"] is None]
    return "derive", v, {"listed": {k: {"aa_id": r["aa_id"], "out_price": r["out_price"]} for k, r in listed_.items()}}


RULINGS = {
    "every id of a derived or decided deployed list carries `intelligence`; a benched row without it is in no pool and is named by `unscored` (exactly those rows, never dropped unseen); at least one benched row lacks `coding` (the other axes are loadable, unused — the gap row)": _ruling_score,
    "within a rail, every id of a decided deployed list scores ≥ its band × the rail's top score (a model can sit in several tiers)": _ruling_bands,
    "every decided priced-rail list has ≤ cap ids with non-decreasing cost per clean ride (`row_cost` under the deployed `tiers.cost`; ties by input price, score descending, id)": _ruling_cheapest,
    "every anthropic and codex row is unpriced (one flat subscription — the ChatGPT one since 2026-10-22, FU-270) and each of their deployed lists is strictly score-ascending": _ruling_subscription,
    "per rail the snapshot's candidate keys and prices are the sources' (opencode = the Go catalog's listed models at the Go price, minus a subscription rail's twins; openrouter = the OpenRouter catalog's ids at the SELECTED endpoint's price or unpriced; anthropic = the deployed `claude/` aliases, unpriced; codex = the enrolled account's ids, unpriced, every deployed codex id among them)": _ruling_candidates,
    "every snapshot row's `aa_id` is what `join_aa_id` returns over the snapshot's AA ids (no row is a hand-written pair)": _ruling_join,
    "no id in a decided deployed list has a null `aa_id`, nor a null `out_price` on a priced rail (the free `beam-free` and `longcat-2.5-preview-free` stay out; every openrouter model until a cell passed the entry canary)": _ruling_unbenched,
}
RULING_ROWS = [
    pytest.param(list(RULINGS)[0], "tiers.score: intelligence", "none", id="the score is the Artificial Analysis intelligence index ⚖"),
    pytest.param(list(RULINGS)[1], "tiers.bands: heavy 0.9, standard 0.75, light 0.5", "none", id="a tier is a band of the rail's best ⚖"),
    pytest.param(list(RULINGS)[2], "tiers.cap: 3", "none", id="each list is cheapest per clean ride first, capped at 3 ⚖"),
    pytest.param(list(RULINGS)[3], "PRICELESS_RAILS: anthropic, codex", "none", id="the subscription rail has no price: score ascending is its cost proxy ⚖"),
    pytest.param(list(RULINGS)[4], "sources.capability.source: artificial-analysis", "none", id="the candidates per rail ⚖"),
    pytest.param(list(RULINGS)[5], "the rule", "none", id="the join to the AA row is a rule, not a table ⚖"),
    pytest.param(list(RULINGS)[6], "derive", "none", id="unbenched never tiers ⚖"),
]


@deployed
@pytest.mark.parametrize(("invariant", "expected_knob", "expected_violations"), RULING_ROWS, ids=[p.id for p in RULING_ROWS])
def test_rulings(invariant, expected_knob, expected_violations):
    world(note="against the committed snapshot + the deployed policy")
    policy, bench = _deployed()
    with given(f"{BENCHMARKS.relative_to(ISLAND.parent)} (snapshot_at {bench['snapshot_at']}) + the deployed policy; invariant = {invariant}"):
        attach_json("the deployed tiers block", {k: v for k, v in policy["tiers"].items() if not k.startswith("_")})
    with when("the invariant is evaluated over the deployed files"):
        knob, violations, evidence = RULINGS[invariant](policy, bench)
        attach_json("what was read", evidence)
    verdict(f"knob = {expected_knob} · violations = {expected_violations}",
            expected_knob={"expected": expected_knob, "actual": knob},
            expected_violations={"expected": expected_violations, "actual": joined(violations)},
            invariant={"actual": invariant})


# ── The deployed policy ──────────────────────────────────────────────────────────────────────
NULLED = "with every openrouter price nulled"
DEPLOYED_ROWS = [
    pytest.param("deployed", "committed", "none", "{}", "none", "none", id="the deployed tier lists equal the derivation ⚖"),
    pytest.param("deployed", "committed", "rails.anthropic.models.heavy reversed", "anthropic.heavy", "none", "none", id="a hand edit of a list fails the check"),
    pytest.param("policy-default", "committed", "none", "non-empty (its lists are fixture ids)", "none", "none",
                 id="the fixture worlds carry the block, not the derivation ⚖"),
    pytest.param("deployed", NULLED, "none", "{}", "openrouter: light, standard, heavy", "none", id="an undecided tier keeps its deployed list ⚖"),
]


def _bare(block: dict) -> dict:
    return {k: (_bare(v) if isinstance(v, dict) else v) for k, v in block.items() if not k.startswith("_")}


@deployed
@pytest.mark.parametrize(("policy", "snapshot", "edit", "expected_mismatches", "expected_undecided", "expected_undecided_empty"), DEPLOYED_ROWS,
                         ids=[p.id for p in DEPLOYED_ROWS])
def test_deployed_policy(policy, snapshot, edit, expected_mismatches, expected_undecided, expected_undecided_empty):
    world(note=f"{policy} against the committed snapshot {snapshot}")
    deployed_policy, bench = _deployed()
    doc = copy.deepcopy(deployed_policy) if policy == "deployed" else json.loads(POLICY_FIXTURE.read_text(encoding="utf-8"))
    with given(f"policy = {policy} · snapshot = {snapshot} · edit = {edit}"):
        if snapshot == NULLED:
            for r in bench["rails"]["openrouter"].values():
                r["out_price"] = r["in_price"] = None
                r["price_basis"], r["provider"] = None, None
        if edit != "none":
            m = re.match(r"rails\.(\S+)\.models\.(\S+) reversed", edit)
            rail, tier = m.group(1), m.group(2)
            assert len(doc["rails"][rail]["models"][tier]) >= 2, "reversing a one-id list is no edit"
            doc["rails"][rail]["models"][tier] = list(reversed(doc["rails"][rail]["models"][tier]))
        attach_json("the policy's lists", {r: v["models"] for r, v in doc["rails"].items()})
        if policy == "policy-default":
            assert _bare(doc["tiers"]) == _bare(deployed_policy["tiers"]), "the world's tiers block is the deployed block"
    with when("check(policy, benchmarks), undecided(benchmarks, tiers)"):
        mismatches = check(doc, bench)
        und = undecided(bench, tiers_policy(doc["tiers"]))
        attach_json("result", {"mismatches": mismatches, "undecided": und})
    if edit != "none":
        assert mismatches[rail][tier]["expected"] == derive(bench, tiers_policy(doc["tiers"]))[rail][tier]
    got = "{}" if not mismatches else ("non-empty (its lists are fixture ids)" if policy == "policy-default" else ", ".join(f"{r}.{t}" for r, ts in mismatches.items() for t in ts))
    verdict(f"mismatches = {expected_mismatches} · undecided = {expected_undecided} · undecided_empty = {expected_undecided_empty}",
            expected_mismatches={"expected": expected_mismatches, "actual": got},
            expected_undecided={"expected": expected_undecided, "actual": "; ".join(f"{r}: {', '.join(ts)}" for r, ts in und.items()) or "none"},
            expected_undecided_empty={"expected": expected_undecided_empty, "actual": joined(sorted(f"{r}.{t}" for r, ts in und.items() for t in ts if not _listed(doc, r).get(t)))},
            policy={"actual": policy}, snapshot={"actual": snapshot}, edit={"actual": edit})


SHAPE_ROWS = [pytest.param("committed", "the schema's required keys, plus only its optional ones", id="the snapshot is the schema's shape")]


@deployed
@pytest.mark.parametrize(("snapshot", "expected_shape"), SHAPE_ROWS, ids=[p.id for p in SHAPE_ROWS])
def test_snapshot_shape(snapshot, expected_shape):
    world(note="against the committed snapshot")
    _, bench = _deployed()
    defs = SCHEMA["$defs"]
    with given(f"snapshot = {snapshot}; catalog.schema.json $defs.benchmarks_snapshot / its sources / $defs.candidate_row"):
        want = {"top": sorted(defs["benchmarks_snapshot"]["required"]), "sources": sorted(defs["benchmarks_snapshot"]["properties"]["sources"]["required"]),
                "rails": sorted(defs["benchmarks_snapshot"]["properties"]["rails"]["required"]), "row": sorted(defs["candidate_row"]["required"])}
        attach_json("required keys", want)
    with when("the committed snapshot's keys are read"):
        optional = set(defs["candidate_row"]["properties"]) - set(want["row"])  # the manual-score marks: on a hand-scored row only
        row_shapes = {tuple(sorted(set(r) - optional)) for rows in bench["rails"].values() for r in rows.values()}
        got = {"top": sorted(bench), "sources": sorted(bench["sources"]), "rails": sorted(bench["rails"]), "row": sorted(next(iter(row_shapes)))}
    diff = {k: {"schema": want[k], "snapshot": got[k]} for k in want if want[k] != got[k]}
    if len(row_shapes) != 1:
        diff["row shapes"] = len(row_shapes)
    if undeclared := sorted({k for rows in bench["rails"].values() for r in rows.values() for k in r} - set(defs["candidate_row"]["properties"])):
        diff["undeclared row keys"] = undeclared
    verdict(f"shape = {expected_shape}", expected_shape={"expected": expected_shape, "actual": expected_shape if not diff else f"differs: {diff}"},
            snapshot={"actual": snapshot}, keys={"actual": got})


# ── The evidence age ─────────────────────────────────────────────────────────────────────────
AGE_ROWS = [
    pytest.param("a file with snapshot_at T0 − 600 s", "600", id="age is seconds since snapshot_at ⚖"),
    pytest.param("a missing file", "absent", id="no snapshot mounted, no series"),
]


@pytest.mark.parametrize(("mounted", "expected_age"), AGE_ROWS, ids=[p.id for p in AGE_ROWS])
async def test_evidence_age(settings, policy, secrets, store, mcp_transport, clock, reviews, pods, tmp_path, mounted, expected_age):
    world(note="policy-default; GATEWAY_BENCHMARKS = a scratch file")
    path = tmp_path / "benchmarks.json"
    with given(f"mounted = {mounted}: GATEWAY_BENCHMARKS names {path.name}"):
        if mounted.startswith("a file with snapshot_at "):
            from agent_gateway.tiers import _iso

            path.write_text(json.dumps({"snapshot_at": _iso(clock() + at_offset(mounted[len("a file with snapshot_at "):])), "sources": {}, "rails": {}}), encoding="utf-8")
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
    verdict(f"age = {expected_age}", expected_age={"expected": expected_age, "actual": num(float(m.group(1))) if m else "absent"},
            declared={"expected": True, "actual": "# TYPE gateway_tier_evidence_age_seconds gauge" in text}, mounted={"actual": mounted})


