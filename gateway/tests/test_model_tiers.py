"""GW-MODEL-TIERS — the deployed tier lists are derived from benchmark evidence (specs/endpoints/catalog.md).

World: policy-default for the loader rows (the `tiers` block every world carries); the band and
join rows run on hand-written snapshots named in each row (no gateway, no upstream); the deployed
rows read argocd/resources/agent-gateway/{benchmarks,policy}.json (skipped when absent).

Rail `fx` (priced, score intelligence, bands 0.9/0.75/0.5, cap 3): top = 50 → heavy ≥ 45,
standard ≥ 37.5, light ≥ 25. Candidates (score · out / in $ per 1M): fx/top 50 · 2.0/0.5,
fx/near 46 · 1.0/0.2, fx/mid 40 · 0.5/0.1, fx/low 26 · 0.1/0.05, fx/far 20 · 0.05/0.01,
fx/none unbenched · 0/0.

| description | candidates | light | standard | heavy |
|---|---|---|---|---|
| heavy = within 0.90 of the rail's top, cheapest first | fx | — | — | fx/near, fx/top |
| standard = within 0.75 | fx | — | fx/mid, fx/near, fx/top | — |
| light = within 0.50, the cap drops the 4th by price | fx | fx/low, fx/mid, fx/near | — | — |
| a model sits in several tiers | fx | fx/near in all three | | |
| an unbenched candidate never tiers, however cheap | fx | fx/none in none | | |
| an unpriced candidate on a priced rail never tiers | fx + fx/nopx 49 · no price | fx/nopx in none; top stays 50 | | |
| a price tie breaks by input price, then score, then id | fxt: a 40 · 0.5/0.2, b 44 · 0.5/0.1, c 44 · 0.5/0.2 | — | — | fxt/b, fxt/c, fxt/a |
| the axis is the policy's: the same rail under score: coding | fx coding top 10, near 60, mid 55, low 50, far 5 | — | — | fx/mid, fx/near |
| the subscription rail orders by score ascending | anthropic: fx-a 40, fx-b 55, fx-c 60, no prices | a, b, c | b, c | b, c |
| no benched candidate: empty lists, which apply refuses to write | fx-empty: fx/none only | [] — apply_text raises naming fx-empty.light | | |
| a measured clean rate reorders a list | fx + fx/mid rides 2 / 6 (rate 1/3: $0.5 / (1/3) = $1.5 per 1M past fx/near's $1.0) | — | fx/near, fx/mid, fx/top | — |
| a tier with no priced candidate is undecided: check passes it, apply refuses it | fx-unpriced: fx/a 50 · no price | derive [] ×3; undecided names fx-unpriced light/standard/heavy; check = {} against a policy listing fx/a; apply_text raises naming fx-unpriced.light | | |

| description | a | b | twins |
|---|---|---|---|
| a Go id and its openrouter spelling are twins | opencode-go/deepseek-v4.1-flash | deepseek/deepseek-v4.1-flash | yes |
| the dotted and the dashed version are twins | opencode-go/claude-haiku-5-5 | anthropic/claude-haiku-5.5 | yes |
| a variant twins its family | inclusionai/ling-3.0-flash:free | inclusionai/ling-3.0-flash | yes |
| two vendors' spellings are not twins | deepseek/deepseek-v4.1-flash | other/deepseek-v4.1-flash | no |
| a suffix is not a twin | opencode-go/glm-5.3 | z-ai/glm-5.3-flash | no |
| an alias twins nothing | claude/haiku | opencode-go/claude-haiku-5-5 | no |
| the same id is not a twin | deepseek/deepseek-v4.1-flash | deepseek/deepseek-v4.1-flash | no |

| description | policy id | AA ids present | joins |
|---|---|---|---|
| a Go id joins the dotted AA id | opencode-go/claude-haiku-5-5 | anthropic/claude-haiku-5.5, anthropic/claude-haiku-4.5 | anthropic/claude-haiku-5.5 |
| a dotted Go id joins as is | opencode-go/glm-5.3 | z-ai/glm-5.3, z-ai/glm-5.3-flash | z-ai/glm-5.3 |
| a Go id the table lacks is unbenched | opencode-go/beam-free | (the two above) | none |
| a suffix is not a match | opencode-go/hy3 | tencent/hy3-preview | none |
| two vendors' rows for one bare id: unbenched | opencode-go/gpt-6-luna | openai/gpt-6-luna, other/gpt-6-luna | none |
| an alias joins the newest row of its family by version | claude/opus | anthropic/claude-opus-5, -5.5, -4.1 | anthropic/claude-opus-5.5 |
| an alias with no row of its family is unbenched | claude/haiku | (the three opus rows) | none |
| an openrouter id keeps its vendor | deepseek/deepseek-v4-flash | deepseek/deepseek-v4-flash, other/deepseek-v4-flash | deepseek/deepseek-v4-flash |
| a :free variant joins its family | inclusionai/ling-3.0-flash:free | inclusionai/ling-3.0-flash | inclusionai/ling-3.0-flash |

| description | tiers in an otherwise policy-default document | the policy load |
|---|---|---|
| the block loads | the world's | loads; Policy.tiers = those values |
| an unknown key refuses the load | + foo: 1 | refused, naming tiers |
| an unknown score axis refuses the load | score: vibes | refused, naming tiers.score |
| a band above 1 refuses the load | bands.heavy: 1.5 | refused, naming tiers.bands.heavy |
| a zero band refuses the load | bands.light: 0 | refused, naming tiers.bands.light |
| bands out of order refuse the load | bands.standard: 0.95 | refused, naming heavy >= standard >= light |
| a missing tier band refuses the load | bands without light | refused, naming light |
| a non-positive cap refuses the load | cap: 0 | refused, naming tiers.cap |
| no block: the policy loads with no rules, and the check refuses to run | tiers absent | loads, Policy.tiers None; check() raises naming tiers |
| no cost terms refuse the load | cost dropped | refused, naming tiers.cost |
| a non-positive ride size refuses the load | cost.ride_tokens_out_m = 0 | refused, naming tiers.cost.ride_tokens_out_m |
| a non-positive min_rides refuses the load | cost.min_rides = 0 | refused, naming tiers.cost.min_rides |

| description | the ruling, checked on the deployed files |
|---|---|
| the score is the Artificial Analysis intelligence index | tiers.score intelligence; every benched row has it, some lack coding |
| a tier is a band of the rail's best | bands 0.9/0.75/0.5; every listed id scores ≥ band × its rail's top |
| each list is cheapest per clean ride first, capped at 3 | cap 3; priced-rail lists ≤ 3, cost per clean ride non-decreasing |
| the subscription rail has no price: score ascending is its cost proxy | anthropic and codex rows unpriced; lists strictly score-ascending |
| the candidates per rail | opencode keys opencode-go/<id>, none the twin of a subscription candidate's AA row, priced promise/measured/unlimited or unpriced; openrouter keys = the OpenRouter catalog's vendor/model ids, priced at the selected endpoint (basis endpoint with its provider) or unpriced; anthropic keys = the rail's claude/ aliases, unpriced; codex keys ⊇ the deployed codex rail's ids (a key on no list is unbenched or below every band), unpriced; source artificial-analysis |
| the join to the AA row is a rule, not a table | every row's aa_id == join_aa_id over the snapshot's AA ids |
| unbenched never tiers | no listed id has a null aa_id, nor a null out_price on a priced rail |

| description | input | verdict |
|---|---|---|
| the deployed tier lists equal the derivation | the committed snapshot + the deployed tiers block | check() = {} |
| a hand edit of a list fails the check | rails.opencode.models.heavy reversed | check() names opencode.heavy |
| the snapshot is the schema's shape | the committed snapshot | exactly the required keys of $defs.benchmarks_snapshot |
| the fixture worlds carry the block, not the derivation | policy-default + the committed snapshot | the world's tiers = the deployed block; check() on the world is NOT empty |
| an undecided tier keeps its deployed list | the committed snapshot's undecided tiers | check() = {}; undecided() names them; each named tier's deployed list is non-empty |
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from agent_gateway.config import CostPolicy, Policy, PolicyError, TiersPolicy, tiers_policy
from agent_gateway.tiers import (
    PRICELESS_RAILS,
    apply_text,
    check,
    derive,
    join_aa_id,
    row_cost,
    same_model,
    undecided,
)

from .conftest import ISLAND, POLICY_FIXTURE, attach_json, given, rule, then, then_eq, when, world

pytestmark = rule("GW-MODEL-TIERS")

DEPLOY = ISLAND.parent / "argocd" / "resources" / "agent-gateway"
DEPLOYED_POLICY = DEPLOY / "policy.json"
BENCHMARKS = DEPLOY / "benchmarks.json"
SCHEMA = json.loads((Path(__file__).resolve().parents[1] / "specs" / "endpoints" / "catalog.schema.json").read_text(encoding="utf-8"))

COST = CostPolicy(0.01, 0.0, 5)  # the worlds' tiers.cost: 10k output tokens a ride, no strike overhead, 5 judged rides
RULES = TiersPolicy("intelligence", {"heavy": 0.9, "standard": 0.75, "light": 0.5}, 3, COST)


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
# rail fxt: every out price 0.5 → b first (in 0.1), then c over a (44 > 40 at in 0.2); top 44 → heavy ≥ 39.6 = all three.
FXT = {"fxt/a": _row(40, 0.5, 0.2), "fxt/b": _row(44, 0.5, 0.1), "fxt/c": _row(44, 0.5, 0.2)}
# rail anthropic (no prices): top 60 → heavy ≥ 54 {b, c}; standard ≥ 45 {b, c}; light ≥ 30 {a, b, c}; score ascending.
SUB = {"claude/fx-a": _row(40), "claude/fx-b": _row(55), "claude/fx-c": _row(60)}


def _bench(**rails) -> dict:
    return {"snapshot_at": "2027-01-15T08:00:00Z", "sources": {}, "rails": rails}


RAILS = {"fx": FX, "fxt": FXT, "anthropic": SUB}
BAND_ROWS = [
    ("heavy = within 0.90 of the rail's top, cheapest first", "fx", "intelligence", "heavy", ["fx/near", "fx/top"]),
    ("standard = within 0.75", "fx", "intelligence", "standard", ["fx/mid", "fx/near", "fx/top"]),
    ("light = within 0.50, the cap drops the 4th by price", "fx", "intelligence", "light", ["fx/low", "fx/mid", "fx/near"]),
    ("a price tie breaks by input price, then score, then id", "fxt", "intelligence", "heavy", ["fxt/b", "fxt/c", "fxt/a"]),
    # coding axis: top 60 (near) → heavy ≥ 54 = {near 60, mid 55}; cheapest first = mid (0.5), near (1.0).
    ("the axis is the policy's: the same rail under score: coding", "fx", "coding", "heavy", ["fx/mid", "fx/near"]),
]


@pytest.mark.parametrize(("rail", "axis", "tier", "expected"), [r[1:] for r in BAND_ROWS], ids=[r[0] for r in BAND_ROWS])
def test_bands(rail, axis, tier, expected):
    world(note=f"a hand-written snapshot: rail {rail}")
    rows, rules = RAILS[rail], TiersPolicy(axis, RULES.bands, RULES.cap, COST)
    with given(f"rail {rail}: {len(rows)} candidates; score {axis}, bands {rules.bands}, cap {rules.cap}"):
        attach_json(f"rail {rail}", rows)
    with when(f"derive(snapshot, tiers) → {rail}.{tier}"):
        lists = derive(_bench(**{rail: rows}), rules)
    then_eq(f"{rail}.{tier}", lists[rail][tier], expected)


def test_several_tiers():
    """row: a model sits in several tiers"""
    world(note="a hand-written snapshot: rail fx")
    with given("rail fx (fx/near 46 · 1.0: within every band of top 50)"):
        attach_json("rail fx", FX)
    with when("derive(snapshot, tiers)"):
        lists = derive(_bench(fx=FX), RULES)
    then_eq("tiers holding fx/near", sorted(t for t, ids in lists["fx"].items() if "fx/near" in ids), ["heavy", "light", "standard"])


def test_unbenched_never_tiers():
    """row: an unbenched candidate never tiers, however cheap"""
    world(note="a hand-written snapshot: rail fx")
    with given("rail fx (fx/none at 0/0 has no AA row)"):
        attach_json("rail fx", FX)
    with when("derive(snapshot, tiers)"):
        lists = derive(_bench(fx=FX), RULES)
    then_eq("tiers holding fx/none", [t for t, ids in lists["fx"].items() if "fx/none" in ids], [])


def test_unpriced_never_tiers():
    """row: an unpriced candidate on a priced rail never tiers"""
    world(note="a hand-written snapshot: rail fx + fx/nopx")
    rows = {**FX, "fx/nopx": _row(49, None, None)}
    with given("rail fx + fx/nopx 49 with no price"):
        attach_json("rail fx", rows)
    with when("derive(snapshot, tiers)"):
        lists = derive(_bench(fx=rows), RULES)
    then_eq("tiers holding fx/nopx", [t for t, ids in lists["fx"].items() if "fx/nopx" in ids], [])
    # top stays 50 (fx/nopx is not in the pool): heavy is still {near, top}, as without it.
    then_eq("fx.heavy (top stays 50)", lists["fx"]["heavy"], ["fx/near", "fx/top"])


def test_subscription_score_ascending():
    """row: the subscription rail orders by score ascending"""
    world(note="a hand-written snapshot: rail anthropic")
    with given("rail anthropic: fx-a 40, fx-b 55, fx-c 60, no prices (top 60 → heavy ≥ 54, standard ≥ 45, light ≥ 30)"):
        attach_json("rail anthropic", SUB)
    with when("derive(snapshot, tiers)"):
        lists = derive(_bench(anthropic=SUB), RULES)
    with then("light a, b, c · standard b, c · heavy b, c — score ascending",
              lists={"expected": {"light": ["claude/fx-a", "claude/fx-b", "claude/fx-c"], "standard": ["claude/fx-b", "claude/fx-c"],
                                  "heavy": ["claude/fx-b", "claude/fx-c"]}, "actual": lists["anthropic"]}):
        assert lists["anthropic"] == {"light": ["claude/fx-a", "claude/fx-b", "claude/fx-c"],
                                      "standard": ["claude/fx-b", "claude/fx-c"], "heavy": ["claude/fx-b", "claude/fx-c"]}


def test_empty_rail_apply_refuses():
    """row: no benched candidate: empty lists, which apply refuses to write"""
    world(note="a hand-written snapshot: rail fx-empty")
    rows = {"fx/none": FX["fx/none"]}
    text = json.dumps({"rails": {"fx-empty": {"models": {"light": ["x"], "standard": ["x"], "heavy": ["x"]}}}}, indent=2)
    with given("rail fx-empty: fx/none only (unbenched); a policy text naming the rail"):
        attach_json("rail fx-empty", rows)
    with when("derive(snapshot, tiers), then apply_text(policy text, the derivation)"):
        lists = derive(_bench(**{"fx-empty": rows}), RULES)
        try:
            apply_text(text, lists)
            error = None
        except ValueError as e:
            error = str(e)
        attach_json("apply result", {"derived": lists, "error": error})
    then_eq("derived lists", lists["fx-empty"], {"light": [], "standard": [], "heavy": []})
    with then("apply_text raises naming fx-empty.light", error={"expected": "fx-empty.light", "actual": error}):
        assert error is not None and "fx-empty.light" in error


def test_clean_rate_reorders():
    """row: a measured clean rate reorders a list"""
    world(note="a hand-written snapshot: rail fx + fx/mid rides")
    rows = {**FX, "fx/mid": {**FX["fx/mid"], "rides": {"clean": 2, "judged": 6, "prior": 1.0}}}
    with given("rail fx with fx/mid at 2 clean of 6 judged rides (rate 1/3: $0.5 / (1/3) = $1.5 per 1M of output, past fx/near's $1.0)"):
        attach_json("rail fx", rows)
        attach_json("cost per clean ride", {pid: row_cost(r, RULES.cost) for pid, r in rows.items() if r["aa_id"]})
    with when("derive(snapshot, tiers) → fx.standard"):
        lists = derive(_bench(fx=rows), RULES)
    then_eq("fx.standard", lists["fx"]["standard"], ["fx/near", "fx/mid", "fx/top"])


def test_undecided_tier():
    """row: a tier with no priced candidate is undecided: check passes it, apply refuses it"""
    world(note="a hand-written snapshot: rail fx-unpriced")
    rows = {"fx/a": _row(50, None, None)}
    policy = {"rails": {"fx-unpriced": {"models": {"light": ["fx/a"], "standard": ["fx/a"], "heavy": ["fx/a"]}}}, "tiers": BLOCK}
    with given("rail fx-unpriced: fx/a 50, benched, no price; a policy whose lists name fx/a"):
        attach_json("rail fx-unpriced", rows)
    with when("derive, undecided, check(policy, snapshot), apply_text(policy text, the derivation)"):
        bench = _bench(**{"fx-unpriced": rows})
        lists = derive(bench, RULES)
        und = undecided(bench, RULES)
        mismatches = check(policy, bench)
        try:
            apply_text(json.dumps(policy, indent=2), lists)
            error = None
        except ValueError as e:
            error = str(e)
        attach_json("result", {"derived": lists, "undecided": und, "check": mismatches, "apply error": error})
    then_eq("derived lists", lists["fx-unpriced"], {"light": [], "standard": [], "heavy": []})
    then_eq("undecided", und, {"fx-unpriced": ["light", "standard", "heavy"]})
    then_eq("check() mismatches", mismatches, {})
    with then("apply_text raises naming fx-unpriced.light", error={"expected": "fx-unpriced.light", "actual": error}):
        assert error is not None and "fx-unpriced.light" in error


TWIN_ROWS = [
    ("a Go id and its openrouter spelling are twins", "opencode-go/deepseek-v4.1-flash", "deepseek/deepseek-v4.1-flash", True),
    ("the dotted and the dashed version are twins", "opencode-go/claude-haiku-5-5", "anthropic/claude-haiku-5.5", True),
    ("a variant twins its family", "inclusionai/ling-3.0-flash:free", "inclusionai/ling-3.0-flash", True),
    ("two vendors' spellings are not twins", "deepseek/deepseek-v4.1-flash", "other/deepseek-v4.1-flash", False),
    ("a suffix is not a twin", "opencode-go/glm-5.3", "z-ai/glm-5.3-flash", False),
    ("an alias twins nothing", "claude/haiku", "opencode-go/claude-haiku-5-5", False),
    ("the same id is not a twin", "deepseek/deepseek-v4.1-flash", "deepseek/deepseek-v4.1-flash", False),
]


@pytest.mark.parametrize(("a", "b", "expected"), [r[1:] for r in TWIN_ROWS], ids=[r[0] for r in TWIN_ROWS])
def test_twins(a, b, expected):
    world(note="two hand-written policy ids")
    with given(f"policy ids {a!r} and {b!r}; expected twins: {expected}"):
        attach_json("ids", [a, b])
    with when(f"same_model({a!r}, {b!r}) and the reverse"):
        got = (same_model(a, b), same_model(b, a))
    then_eq("twins (both directions)", got, (expected, expected), claim="twins" if expected else "not twins")


# ── The id join ─────────────────────────────────────────────────────────────────────────────
HAIKU = ["anthropic/claude-haiku-5.5", "anthropic/claude-haiku-4.5"]
GLM = ["z-ai/glm-5.3", "z-ai/glm-5.3-flash"]
OPUS = ["anthropic/claude-opus-5", "anthropic/claude-opus-5.5", "anthropic/claude-opus-4.1"]
JOIN_ROWS = [
    ("a Go id joins the dotted AA id", "opencode-go/claude-haiku-5-5", HAIKU, "anthropic/claude-haiku-5.5"),
    ("a dotted Go id joins as is", "opencode-go/glm-5.3", GLM, "z-ai/glm-5.3"),
    ("a Go id the table lacks is unbenched", "opencode-go/beam-free", HAIKU + GLM, "none"),
    ("a suffix is not a match", "opencode-go/hy3", ["tencent/hy3-preview"], "none"),
    ("two vendors' rows for one bare id: unbenched", "opencode-go/gpt-6-luna", ["openai/gpt-6-luna", "other/gpt-6-luna"], "none"),
    ("an alias joins the newest row of its family by version", "claude/opus", OPUS, "anthropic/claude-opus-5.5"),
    ("an alias with no row of its family is unbenched", "claude/haiku", OPUS, "none"),
    ("an openrouter id keeps its vendor", "deepseek/deepseek-v4-flash", ["deepseek/deepseek-v4-flash", "other/deepseek-v4-flash"], "deepseek/deepseek-v4-flash"),
    ("a :free variant joins its family", "inclusionai/ling-3.0-flash:free", ["inclusionai/ling-3.0-flash"], "inclusionai/ling-3.0-flash"),
]


@pytest.mark.parametrize(("policy_id", "aa_ids", "expected"), [r[1:] for r in JOIN_ROWS], ids=[r[0] for r in JOIN_ROWS])
def test_join(policy_id, aa_ids, expected):
    world(note="a hand-written AA id list")
    with given(f"AA ids {aa_ids}"):
        attach_json("aa ids", aa_ids)
    with when(f"join_aa_id({policy_id!r}, aa_ids)"):
        got = join_aa_id(policy_id, aa_ids) or "none"
    then_eq("joins", got, expected, claim=f"joins {expected}")


# ── The tiers block ─────────────────────────────────────────────────────────────────────────
BLOCK = {"score": "intelligence", "bands": {"heavy": 0.9, "standard": 0.75, "light": 0.5}, "cap": 3,
         "cost": {"ride_tokens_out_m": 0.01, "strike_overhead_usd": 0, "min_rides": 5}}


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


DROP = object()
BLOCK_ROWS = [
    ("the block loads", "the world's", "loads"),
    ("an unknown key refuses the load", "foo = 1", "tiers"),
    ("an unknown score axis refuses the load", 'score = "vibes"', "tiers.score"),
    ("a band above 1 refuses the load", "bands.heavy = 1.5", "tiers.bands.heavy"),
    ("a zero band refuses the load", "bands.light = 0", "tiers.bands.light"),
    ("bands out of order refuse the load", "bands.standard = 0.95", "heavy >= standard >= light"),
    ("a missing tier band refuses the load", "bands.light dropped", "light"),
    ("a non-positive cap refuses the load", "cap = 0", "tiers.cap"),
    ("no cost terms refuse the load", "cost dropped", "tiers.cost"),
    ("a non-positive ride size refuses the load", "cost.ride_tokens_out_m = 0", "tiers.cost.ride_tokens_out_m"),
    ("a non-positive min_rides refuses the load", "cost.min_rides = 0", "tiers.cost.min_rides"),
]


@pytest.mark.parametrize(("edit", "refused"), [r[1:] for r in BLOCK_ROWS], ids=[r[0] for r in BLOCK_ROWS])
def test_tiers_block(edit, refused):
    world()
    doc = json.loads(POLICY_FIXTURE.read_text(encoding="utf-8"))
    with given(f"policy-default with its tiers block: {edit}"):
        if edit != "the world's":
            _apply_edit(doc, edit)
        attach_json("tiers", doc["tiers"])
    with when("the policy loads"):
        try:
            loaded, error = Policy.from_dict(doc), None
        except PolicyError as e:
            loaded, error = None, str(e)
        attach_json("load result", {"loaded": loaded is not None, "error": error})
    if refused == "loads":
        then_eq("Policy.tiers", loaded.tiers, TiersPolicy(BLOCK["score"], BLOCK["bands"], BLOCK["cap"], COST),
                claim="loads; Policy.tiers = the world's block")
    else:
        with then(f"refused, naming {refused}", refused={"expected": refused, "actual": error}):
            assert error is not None and refused in error, error


def test_no_block():
    """row: no block: the policy loads with no rules, and the check refuses to run"""
    world()
    doc = json.loads(POLICY_FIXTURE.read_text(encoding="utf-8"))
    with given("policy-default without its tiers block"):
        del doc["tiers"]
    with when("the policy loads, then check(policy, a snapshot)"):
        loaded = Policy.from_dict(doc)
        try:
            check(doc, _bench(fx=FX))
            error = None
        except ValueError as e:
            error = str(e)
        attach_json("result", {"tiers": loaded.tiers, "check error": error})
    then_eq("Policy.tiers", loaded.tiers, None)
    with then("check() raises naming tiers", error={"expected": "tiers", "actual": error}):
        assert error is not None and "tiers" in error


# ── The deployed policy ─────────────────────────────────────────────────────────────────────
deployed = pytest.mark.skipif(not (DEPLOYED_POLICY.exists() and BENCHMARKS.exists()),
                              reason="deploy manifests absent (service-only checkout)")


def _deployed() -> tuple[dict, dict]:
    return (json.loads(DEPLOYED_POLICY.read_text(encoding="utf-8")), json.loads(BENCHMARKS.read_text(encoding="utf-8")))


@deployed
def test_deployed_equals_derivation():
    """row: the deployed tier lists equal the derivation"""
    world(note="against the deployed policy + the committed snapshot")
    policy, bench = _deployed()
    with given(f"{BENCHMARKS.relative_to(ISLAND.parent)} (snapshot_at {bench['snapshot_at']}) + the deployed tiers block {policy['tiers']['score']}/{policy['tiers']['bands']}/{policy['tiers']['cap']}"):
        attach_json("deployed lists", {r: v["models"] for r, v in policy["rails"].items()})
    with when("check(policy, benchmarks)"):
        mismatches = check(policy, bench)
    then_eq("mismatches", mismatches, {}, claim="check() = {} — every list is the derived list, in order")


@deployed
def test_hand_edit_fails():
    """row: a hand edit of a list fails the check"""
    world(note="against the deployed policy + the committed snapshot")
    policy, bench = _deployed()
    # the first deployed list with two or more ids, in a fixed order: reversing a one-id list is no edit
    rail, tier = next((r, t) for r in sorted(policy["rails"]) for t in ("light", "standard", "heavy")
                      if isinstance(policy["rails"][r].get("models", {}).get(t), list) and len(policy["rails"][r]["models"][t]) >= 2)
    with given(f"the deployed policy with rails.{rail}.models.{tier} reversed"):
        policy = copy.deepcopy(policy)
        policy["rails"][rail]["models"][tier] = list(reversed(policy["rails"][rail]["models"][tier]))
        attach_json("edited list", policy["rails"][rail]["models"][tier])
    with when("check(policy, benchmarks)"):
        mismatches = check(policy, bench)
    with then(f"check() names {rail}.{tier}, expecting the derived list", named={"expected": [f"{rail}.{tier}"], "actual": [f"{r}.{t}" for r, ts in mismatches.items() for t in ts]}):
        assert list(mismatches) == [rail] and list(mismatches[rail]) == [tier]
        assert mismatches[rail][tier]["expected"] == derive(bench, tiers_policy(policy["tiers"]))[rail][tier]


def _pool(rows: dict, rail: str, axis: str) -> dict:
    """The tierable candidates of a rail as derive sees them: benched, and priced on a priced rail."""
    return {pid: r for pid, r in rows.items() if r["aa_id"] and r[axis] is not None and (rail == "anthropic" or r["out_price"] is not None)}


def _listed(policy: dict, rail: str) -> dict[str, list[str]]:
    return {t: ([v] if isinstance(v, str) else list(v)) for t, v in policy["rails"][rail]["models"].items()}


@deployed
def test_ruling_score_axis():
    """row: the score is the Artificial Analysis intelligence index"""
    world(note="against the committed snapshot + the deployed policy")
    policy, bench = _deployed()
    with given("the deployed tiers block and every benched candidate row"):
        benched = [r for rows in bench["rails"].values() for r in rows.values() if r["aa_id"]]
        attach_json("coverage", {"benched": len(benched), "with intelligence": sum(r["intelligence"] is not None for r in benched),
                                 "with coding": sum(r["coding"] is not None for r in benched)})
    with when("the score axis and the rows' coverage are read"):
        axis = policy["tiers"]["score"]
    then_eq("tiers.score", axis, "intelligence")
    then_eq("benched rows lacking intelligence", sum(r["intelligence"] is None for r in benched), 0)
    with then("at least one benched row lacks coding (the axis without full coverage)", lacking={"expected": "> 0", "actual": sum(r["coding"] is None for r in benched)}):
        assert any(r["coding"] is None for r in benched)


@deployed
def test_ruling_bands():
    """row: a tier is a band of the rail's best"""
    world(note="against the committed snapshot + the deployed policy")
    policy, bench = _deployed()
    axis, bands = policy["tiers"]["score"], policy["tiers"]["bands"]
    und = undecided(bench, tiers_policy(policy["tiers"]))
    with given("the deployed tiers block; each decided rail's top score over its tierable candidates"):
        tops = {rail: max(r[axis] for r in _pool(rows, rail, axis).values()) for rail, rows in bench["rails"].items()
                if _pool(rows, rail, axis)}
        attach_json("tops", tops)
        attach_json("undecided (the deployed list stands, unchecked here)", und)
    with when("every id of every decided deployed list is scored against its band"):
        below = sorted(f"{rail}.{tier}:{pid}" for rail in tops for tier, ids in _listed(policy, rail).items() if tier not in und.get(rail, [])
                       for pid in ids if bench["rails"][rail][pid][axis] < bands[tier] * tops[rail])
    then_eq("tiers.bands", bands, {"heavy": 0.9, "standard": 0.75, "light": 0.5})
    then_eq("listed ids below their band", below, [])


@deployed
def test_ruling_cheapest_first():
    """row: each list is cheapest per clean ride first, capped at 3"""
    world(note="against the committed snapshot + the deployed policy")
    policy, bench = _deployed()
    cost = tiers_policy(policy["tiers"]).cost
    und = undecided(bench, tiers_policy(policy["tiers"]))
    with given("the deployed priced-rail lists (the decided tiers) with each id's cost per clean ride"):
        priced = {rail: {tier: [(pid, row_cost(bench["rails"][rail][pid], cost)) for pid in ids]
                         for tier, ids in _listed(policy, rail).items() if tier not in und.get(rail, [])}
                  for rail in bench["rails"] if rail not in PRICELESS_RAILS}
        attach_json("lists with costs", priced)
        attach_json("undecided (the deployed list stands, unchecked here)", und)
    with when("each decided list's length and cost order are read"):
        over = [f"{rail}.{tier}" for rail, ts in priced.items() for tier, ids in ts.items() if len(ids) > policy["tiers"]["cap"]]
        unsorted = [f"{rail}.{tier}" for rail, ts in priced.items() for tier, ids in ts.items()
                    if [c for _, c in ids] != sorted(c for _, c in ids)]
    then_eq("tiers.cap", policy["tiers"]["cap"], 3)
    then_eq("decided lists over the cap", over, [])
    then_eq("decided lists not cost-ascending", unsorted, [])


@deployed
def test_ruling_subscription_proxy():
    """row: the subscription rail has no price: score ascending is its cost proxy"""
    world(note="against the committed snapshot + the deployed policy")
    policy, bench = _deployed()
    axis = policy["tiers"]["score"]
    priced, not_ascending = {}, {}
    with given("the anthropic and codex snapshot rows and the deployed anthropic and codex lists (the two subscription rails)"):
        scored = {rail: {tier: [(pid, bench["rails"][rail][pid][axis]) for pid in ids] for tier, ids in _listed(policy, rail).items()}
                  for rail in ("anthropic", "codex")}
        attach_json("subscription lists with scores", scored)
    with when("the rows' prices and each list's score order are read"):
        for rail, lists in scored.items():
            priced[rail] = [pid for pid, r in bench["rails"][rail].items() if r["out_price"] is not None or r["in_price"] is not None]
            not_ascending[rail] = [tier for tier, ids in lists.items() if [s for _, s in ids] != sorted({s for _, s in ids})]
    then_eq("subscription rows carrying a price", priced, {"anthropic": [], "codex": []})
    then_eq("subscription lists not strictly score-ascending", not_ascending, {"anthropic": [], "codex": []})


@deployed
def test_ruling_join_is_a_rule():
    """row: the join to the AA row is a rule, not a table"""
    world(note="against the committed snapshot")
    _, bench = _deployed()
    with given("every snapshot row's policy id and aa_id; the snapshot's set of AA ids"):
        aa_ids = sorted({r["aa_id"] for rows in bench["rails"].values() for r in rows.values() if r["aa_id"]})
        attach_json("aa ids in the snapshot", aa_ids)
    with when("join_aa_id(policy id, those AA ids) is recomputed for every row"):
        differs = sorted(f"{rail}:{pid}" for rail, rows in bench["rails"].items() for pid, r in rows.items()
                         if join_aa_id(pid, aa_ids) != r["aa_id"])
    then_eq("rows whose aa_id is not the rule's answer", differs, [])


@deployed
def test_ruling_unbenched_never_tiers():
    """row: unbenched never tiers"""
    world(note="against the committed snapshot + the deployed policy")
    policy, bench = _deployed()
    und = undecided(bench, tiers_policy(policy["tiers"]))
    with given("every id of every DECIDED deployed list with its row's aa_id and out_price (an undecided tier's list stands as last derived)"):
        listed = {f"{rail}.{tier}:{pid}": {"aa_id": bench["rails"][rail][pid]["aa_id"], "out_price": bench["rails"][rail][pid]["out_price"]}
                  for rail in bench["rails"] for tier, ids in _listed(policy, rail).items() if tier not in und.get(rail, []) for pid in ids}
        attach_json("listed ids", listed)
        attach_json("undecided (unchecked here)", und)
    with when("the unbenched and the unpriced-on-a-priced-rail are counted"):
        unbenched = sorted(k for k, v in listed.items() if v["aa_id"] is None)
        unpriced = sorted(k for k, v in listed.items() if not k.startswith(("anthropic.", "codex.")) and v["out_price"] is None)
    then_eq("listed ids with no AA row", unbenched, [])
    then_eq("listed ids with no price on a priced rail", unpriced, [])


@deployed
def test_snapshot_candidates():
    """row: the candidates per rail"""
    world(note="against the committed snapshot")
    policy, bench = _deployed()
    with given("the deployed anthropic rail's model + side-model ids, the deployed codex ids, the tiers block"):
        rail = policy["rails"]["anthropic"]
        aliases = sorted({x for lst in rail["models"].values() for x in ([lst] if isinstance(lst, str) else lst)} | set(rail.get("side_models", [])))
        codex_ids = sorted({x for lst in policy["rails"]["codex"]["models"].values() for x in ([lst] if isinstance(lst, str) else lst)})
        tp = tiers_policy(policy["tiers"])
        attach_json("deployed ids", {"anthropic aliases": aliases, "codex ids": codex_ids})
    with when("the snapshot's rails are read"):
        rails = bench["rails"]
        sub_aa = [r["aa_id"] for rail_ in PRICELESS_RAILS for r in rails[rail_].values() if r.get("aa_id")]
        benched = {k: float(r[tp.score]) for k, r in rails["codex"].items() if r.get("aa_id") and isinstance(r.get(tp.score), (int, float))}
        top = max(benched.values(), default=0.0)

    def verdict(claim: str, **pairs) -> None:
        # one Then per rail: every (key: expected, actual) of that rail compared under ONE step, attached once
        with then(claim, **{k: {"expected": e, "actual": a} for k, (e, a) in pairs.items()}):
            for k, (e, a) in pairs.items():
                assert a == e, f"{k}: expected {e!r}, got {a!r}"

    verdict("opencode: every key is opencode-go/<id>, none the twin of a subscription candidate's AA row, priced promise / measured / unlimited or unpriced",
            **{"keys not opencode-go/<id>": ([], sorted(k for k in rails["opencode"] if not k.startswith("opencode-go/"))),
               "keys a subscription rail already serves": ([], sorted(k for k in rails["opencode"] if any(same_model(k, aa) for aa in sub_aa))),
               "price bases outside promise / measured / unlimited / null": ([], sorted({r["price_basis"] for r in rails["opencode"].values()} - {"promise", "measured", "unlimited", None}))})
    verdict("openrouter: every key is a vendor/model id, priced at its selected endpoint (basis endpoint, with the provider) or unpriced",
            **{"keys not vendor/model": ([], sorted(k for k in rails["openrouter"] if k.count("/") != 1 or k.startswith(("opencode-go/", "claude/")))),
               "rows priced off their selected endpoint": ([], sorted(f"{k}: {r['price_basis']}/{r['provider']}" for k, r in rails["openrouter"].items()
                                                              if r["price_basis"] not in ("endpoint", None) or (r["price_basis"] == "endpoint") != (r["provider"] is not None)))})
    verdict("anthropic: the keys are the deployed rail's claude/ aliases, unpriced",
            **{"keys": (aliases, sorted(rails["anthropic"])),
               "rows priced": ([], [k for k, r in rails["anthropic"].items() if r["out_price"] is not None])})
    verdict("codex: every deployed codex id is a snapshot key (the enrolled account's model evidence); a key on no list is unbenched or below every band; unpriced",
            **{"deployed codex ids missing from the snapshot": ([], [i for i in codex_ids if i not in rails["codex"]]),
               "keys on no list that are benched within a band": ([], sorted(k for k in rails["codex"] if k not in codex_ids and k in benched and benched[k] >= min(tp.bands.values()) * top)),
               "rows priced": ([], [k for k, r in rails["codex"].items() if r["out_price"] is not None])})
    verdict("sources: capability is artificial-analysis, the openrouter catalog's fetched_at is present",
            **{"capability source": ("artificial-analysis", bench["sources"]["capability"]["source"]),
               "openrouter catalog fetched_at present": (True, bench["sources"]["openrouter_catalog"]["fetched_at"] is not None)})


@deployed
def test_snapshot_shape():
    """row: the snapshot is the schema's shape"""
    world(note="against the committed snapshot")
    _, bench = _deployed()
    defs = SCHEMA["$defs"]
    with given("catalog.schema.json $defs.benchmarks_snapshot / its sources / $defs.candidate_row"):
        want = {"top": sorted(defs["benchmarks_snapshot"]["required"]), "sources": sorted(defs["benchmarks_snapshot"]["properties"]["sources"]["required"]),
                "rails": sorted(defs["benchmarks_snapshot"]["properties"]["rails"]["required"]), "row": sorted(defs["candidate_row"]["required"])}
        attach_json("required keys", want)
    with when("the committed snapshot's keys are read"):
        got = {"top": sorted(bench), "sources": sorted(bench["sources"]), "rails": sorted(bench["rails"]),
               "row": sorted({tuple(sorted(r)) for rows in bench["rails"].values() for r in rows.values()}.pop())}
        row_shapes = {tuple(sorted(r)) for rows in bench["rails"].values() for r in rows.values()}
    then_eq("keys", got, want, claim="exactly the schema's required keys at every level")
    then_eq("row shapes", len(row_shapes), 1, claim="every candidate row has the same keys")


@deployed
@deployed
def test_undecided_keeps_deployed():
    """row: an undecided tier keeps its deployed list"""
    world(note="against the committed snapshot + the deployed policy")
    policy, bench = _deployed()
    tiers = tiers_policy(policy["tiers"])
    with given("the committed snapshot's undecided tiers (no priced, benched candidate reaches the band)"):
        und = undecided(bench, tiers)
        attach_json("undecided", und)
    with when("check(policy, benchmarks); each undecided tier's deployed list is read"):
        mismatches = check(policy, bench)
        deployed_lists = {f"{rail}.{tier}": _listed(policy, rail).get(tier) for rail, ts in und.items() for tier in ts}
        attach_json("deployed lists of the undecided tiers", deployed_lists)
    then_eq("check() mismatches", mismatches, {})
    then_eq("undecided tiers with an empty deployed list", sorted(k for k, v in deployed_lists.items() if not v), [])


def _bare(block: dict) -> dict:
    """The block without its `_comment` keys, at every level."""
    return {k: (_bare(v) if isinstance(v, dict) else v) for k, v in block.items() if not k.startswith("_")}


def test_fixture_worlds_exempt():
    """row: the fixture worlds carry the block, not the derivation"""
    world(note="policy-default against the committed snapshot")
    policy, bench = _deployed()
    doc = json.loads(POLICY_FIXTURE.read_text(encoding="utf-8"))
    with given("policy-default's tiers block and lists"):
        attach_json("world lists", {r: v["models"] for r, v in doc["rails"].items()})
    with when("check(policy-default, benchmarks)"):
        mismatches = check(doc, bench)
    then_eq("world tiers block", _bare(doc["tiers"]), _bare(policy["tiers"]), claim="the world's tiers = the deployed block")
    with then("check() on the world is NOT empty — its lists are fixture ids, exempt from the derivation",
              drifted={"expected": "non-empty", "actual": sorted(f"{r}.{t}" for r, ts in mismatches.items() for t in ts)}):
        assert mismatches
