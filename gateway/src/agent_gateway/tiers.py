"""Tier evidence (GW-MODEL-TIERS, specs/endpoints/catalog.md).

The DEPLOYED policy's per-(rail, tier) model lists are derived from benchmark evidence, never
hand-picked (operator rulings 2026-10-18, FU-270). The evidence is a committed snapshot
(`argocd/resources/agent-gateway/benchmarks.json`, written by `scripts/benchmarks-snapshot.sh`):
per rail, every CANDIDATE policy id with its Artificial Analysis row (joined by rule, below), its
output/input price and its Go monthly limit. The rules — the score axis, the tier bands as
fractions of the rail's top score, the cap — are the policy's `tiers` block (`config.TiersPolicy`).

- `join_aa_id`: a policy id → its AA id, by RULE: the part after the vendor `/` with `-N-N` ↔
  `-N.N` version normalisation, a `:variant` suffix dropped, the vendor kept when the id carries
  one; a `claude/<alias>` joins the NEWEST `anthropic/claude-<alias>-<version>` row. No match, or
  more than one, = unbenched.
- `derive`: per rail, a benched candidate is in a tier when its score ≥ band × the rail's top
  score; each list is ordered cheapest-first by COST PER CLEAN RIDE (`cost_per_clean_ride`:
  the row's price × a ride's output tokens ÷ its clean-ride rate, plus the strike overhead per
  failed ride — the `tiers.cost` terms; then input price, score descending, id) and capped.
  The subscription rail has no price: score ascending is its cost proxy. An unbenched
  candidate, or an unpriced one on a priced rail, never tiers. A row's price is the SELECTED
  endpoint's on the openrouter rail (null until a cell passed the entry canary) and the plan's
  discounted list price on the Go rail (`capacity.go_pricing`).
- `check`: the deployed lists EQUAL the derivation, order included — a hand edit fails; a tier
  whose derivation is EMPTY (no priced candidate yet) is `undecided` — reported apart, never a
  mismatch: the deployed list stands until evidence exists, and `apply` refuses to write it.
- `same_model`: the twin rule the admission's rail choice reads — two policy ids name one
  model when their tails match after the rail prefix, a `:variant` and the vendor are stripped
  (`opencode-go/<id>` ↔ `<vendor>/<id>`); an alias twins nothing.
- `apply_text`: rewrites only the rails' `models` blocks in the policy file's own layout.

Stdlib only; nothing here names a model id (GW-MODEL-RESOLVE: ids live in policy files).
"""

from __future__ import annotations

import json
import re
from collections.abc import Iterable
from datetime import UTC, datetime
from pathlib import Path

from .config import RAIL_PREFIX, TIERS, CostPolicy, TiersPolicy, tiers_policy

AA_SOURCE = "artificial-analysis"
ALIAS_PREFIX = RAIL_PREFIX["anthropic"]  # `claude/<alias>`: the subscription rail's family aliases
ALIAS_VENDOR = "anthropic"  # the AA vendor those aliases join under
# ⚖ ruling 3: a subscription rail has no per-token price — score ascending stands in for cost.
# codex joined 2026-10-22 (FU-270): the ChatGPT subscription, one flat fee like the anthropic one.
PRICELESS_RAILS = ("anthropic", "codex")
_VERSION_PAIR = re.compile(r"-(\d+)-(\d+)(?=-|$)")  # the Go spelling `-5-5` → the AA spelling `-5.5`
_VARIANT = re.compile(r":[a-z0-9-]+$")  # `:free` / `:exacto` — a variant of its family (model-classes.json)
_VERSION = re.compile(r"\d+(?:\.\d+)*")


def normalise(tail: str) -> str:
    """The id part after the vendor, in the AA spelling: every `-N-N` becomes `-N.N`."""
    return _VERSION_PAIR.sub(r"-\1.\2", tail)


def _wire(policy_id: str) -> str:
    for prefix in RAIL_PREFIX.values():
        if policy_id.startswith(prefix):
            return policy_id[len(prefix):]
    return policy_id


def join_aa_id(policy_id: str, aa_ids: Iterable[str]) -> str | None:
    """The AA row a policy id joins, or None (unbenched). One rule, no table."""
    ids = list(aa_ids)
    if policy_id.startswith(ALIAS_PREFIX):
        family = policy_id[len(ALIAS_PREFIX):]
        prefix = f"{ALIAS_VENDOR}/claude-{family}-"
        newest: tuple[tuple[int, ...], str] | None = None
        for aa in ids:
            if aa.startswith(prefix) and _VERSION.fullmatch(aa[len(prefix):]):
                version = tuple(int(x) for x in aa[len(prefix):].split("."))
                if newest is None or version > newest[0]:
                    newest = (version, aa)
        return newest[1] if newest else None
    wire = _VARIANT.sub("", _wire(policy_id))
    vendor, _, tail = wire.rpartition("/")
    want = normalise(tail)
    hits = [aa for aa in ids
            if normalise(aa.partition("/")[2]) == want and (not vendor or aa.partition("/")[0] == vendor)]
    return hits[0] if len(hits) == 1 else None


def _price(v) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) and v >= 0 else None


def same_model(a: str, b: str) -> bool:
    """The twin rule (GW-MODEL-TIERS §The rail choice): two policy ids name ONE model when their
    tails agree after the rail prefix, a `:variant` and the vendor are stripped, in the AA
    spelling (`-N-N` ↔ `-N.N`); when both carry a vendor the vendors must agree too. A `claude/`
    alias names a family, never a model: it twins nothing. One rule, no table."""
    if a == b or a.startswith(ALIAS_PREFIX) or b.startswith(ALIAS_PREFIX):
        return False
    wa, wb = (_VARIANT.sub("", _wire(x)) for x in (a, b))
    va, _, ta = wa.rpartition("/")
    vb, _, tb = wb.rpartition("/")
    return normalise(ta) == normalise(tb) and (not va or not vb or va == vb)


def clean_rate(clean: int, judged: int, prior: float, min_rides: int) -> tuple[float, str]:
    """(rate, basis): the cell's measured clean-ride rate once it has `min_rides` judged rides, else
    its prior (the selected endpoint's uptime on openrouter; 1.0 on the Go rail ⚑)."""
    if judged >= min_rides:
        return (clean / judged if judged else 0.0), f"measured {clean}/{judged}"
    return prior, f"prior {prior:g} ({judged} judged rides)"


def cost_per_clean_ride(out_price: float, rate: float, cost: CostPolicy) -> float:
    """$ per CLEAN ride: a ride's output tokens at the cell's price, over the clean rate (1/rate rides
    per clean one), plus the strike overhead on each failed ride (1/rate − 1 of them). Rate 0 = ∞."""
    if rate <= 0:
        return float("inf")
    return out_price * cost.ride_tokens_out_m / rate + cost.strike_overhead_usd * (1.0 / rate - 1.0)


def row_cost(r: dict, cost: CostPolicy) -> float | None:
    """A snapshot row's cost per clean ride (None = unpriced); rows without `rides` carry no evidence —
    the prior stands (1.0 when the row names none)."""
    price = _price(r.get("out_price"))
    if price is None:
        return None
    rides = r.get("rides") or {}
    rate, _ = clean_rate(int(rides.get("clean") or 0), int(rides.get("judged") or 0),
                         float(rides.get("prior") if rides.get("prior") is not None else 1.0), cost.min_rides)
    return cost_per_clean_ride(price, rate, cost)


def derive(benchmarks: dict, tiers: TiersPolicy) -> dict[str, dict[str, list[str]]]:
    """`{rail: {tier: [policy ids]}}` from the snapshot's candidate rows under the policy's rules."""
    out: dict[str, dict[str, list[str]]] = {}
    for rail, rows in benchmarks["rails"].items():
        priced = rail not in PRICELESS_RAILS
        pool = {pid: r for pid, r in rows.items()
                if r.get("aa_id") and isinstance(r.get(tiers.score), (int, float))
                and (not priced or _price(r.get("out_price")) is not None)}
        top = max((float(r[tiers.score]) for r in pool.values()), default=None)
        lists: dict[str, list[str]] = {}
        for tier in TIERS:
            if top is None:
                lists[tier] = []
                continue
            floor = tiers.bands[tier] * top
            eligible = [pid for pid, r in pool.items() if float(r[tiers.score]) >= floor]
            if priced:
                def key(pid: str, pool=pool, axis=tiers.score):
                    r = pool[pid]
                    in_price = _price(r.get("in_price"))
                    return (row_cost(r, tiers.cost), in_price if in_price is not None else float("inf"), -float(r[axis]), pid)
            else:
                def key(pid: str, pool=pool, axis=tiers.score):
                    return (float(pool[pid][axis]), pid)
            lists[tier] = sorted(eligible, key=key)[:tiers.cap]
        out[rail] = lists
    return out


def _lists(models) -> dict[str, list[str]]:
    out = {}
    for tier, ids in (models or {}).items():
        if not tier.startswith("_"):
            out[tier] = [ids] if isinstance(ids, str) else list(ids or [])
    return out


def check(policy: dict, benchmarks: dict) -> dict[str, dict[str, dict]]:
    """Mismatches `{rail: {tier: {expected, actual}}}` between the derivation and the policy's
    `rails.<rail>.models` (order included); `{}` = the lists ARE the derivation. A tier whose
    derivation is empty is not a mismatch: it is `undecided` (below) — the deployed list stands."""
    tiers = tiers_policy(policy.get("tiers"))
    if tiers is None:
        raise ValueError("policy: no `tiers` block — the derivation has no rules to run under")
    mismatches: dict[str, dict[str, dict]] = {}
    rails = policy.get("rails") or {}
    for rail, lists in derive(benchmarks, tiers).items():
        actual = _lists((rails.get(rail) or {}).get("models")) if rail in rails else None
        for tier, expected in lists.items():
            if not expected:
                continue
            got = None if actual is None else actual.get(tier)
            if got != expected:
                mismatches.setdefault(rail, {})[tier] = {"expected": expected, "actual": got}
    return mismatches


def undecided(benchmarks: dict, tiers: TiersPolicy) -> dict[str, list[str]]:
    """`{rail: [tiers]}` whose derivation is empty — no benched, priced candidate reaches the band
    (the openrouter rail before its first eligible cell): the deployed list stands, apply refuses."""
    return {rail: [t for t, ids in lists.items() if not ids] for rail, lists in derive(benchmarks, tiers).items()
            if any(not ids for ids in lists.values())}


def tier_evidence_age(path: str | Path, now: float) -> float | None:
    """Seconds since the mounted snapshot's `snapshot_at` (the `gateway_tier_evidence_age_seconds`
    gauge); None when no readable snapshot is mounted — no series, and the alert's absent() half."""
    try:
        doc = json.loads(Path(path).read_text(encoding="utf-8"))
        at = datetime.fromisoformat(str(doc["snapshot_at"]).replace("Z", "+00:00")).timestamp()
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return max(0.0, now - at)


_MODELS_BLOCK = re.compile(r'("models"\s*:\s*\{)(?P<body>[^{}]*)(\})')


def apply_text(text: str, lists: dict[str, dict[str, list[str]]]) -> str:
    """The policy file with each named rail's `models` block rewritten to `lists[rail]`, every
    other byte untouched (the file's own indent and key alignment are kept). Refuses an empty
    list (the loader would refuse it) and a result that does not re-parse to the intended document."""
    want = json.loads(text)
    for rail, tiers in lists.items():
        for tier, ids in tiers.items():
            if not ids:
                raise ValueError(f"{rail}.{tier}: the derivation is empty — no priced, benched candidate reaches the band; "
                                 "the tier is undecided and the deployed list stands (apply never writes an empty list)")
        if rail not in (want.get("rails") or {}):
            raise ValueError(f"rails.{rail} is not in the policy")
        kept = _lists((want["rails"][rail]).get("models"))  # an undecided tier of this rail keeps its deployed list
        want["rails"][rail]["models"] = {**kept, **{tier: list(ids) for tier, ids in tiers.items()}}
    out = text
    for rail in lists:
        start = re.search(r'^\s*"' + re.escape(rail) + r'"\s*:\s*\{', out, re.M)
        if not start:
            raise ValueError(f"rails.{rail}: block not found in the policy text")
        m = _MODELS_BLOCK.search(out, start.end())
        if not m:
            raise ValueError(f"rails.{rail}.models: block not found in the policy text")
        indent = re.search(r"\n([ \t]*)\S", m.group("body"))
        pad = indent.group(1) if indent else "        "
        close = re.search(r"\n([ \t]*)$", m.group("body"))
        merged = want["rails"][rail]["models"]
        width = max(len(f'"{t}":') for t in merged)
        lines = [f'{pad}{(chr(34) + t + chr(34) + ":").ljust(width)} {json.dumps(list(ids))}' for t, ids in merged.items()]
        body = "\n" + ",\n".join(lines) + "\n" + (close.group(1) if close else "")
        out = out[:m.start("body")] + body + out[m.end("body"):]
    if json.loads(out) != want:
        raise ValueError("apply: the rewritten text does not parse to the intended policy — nothing written")
    return out


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def build_snapshot(*, capability: list, go_catalog: dict, openrouter_catalog: dict, anthropic_aliases: list[str],
                   snapshot_at: str, codex_candidates: list[str] = ()) -> dict:
    """The benchmarks snapshot from its three inputs (the shape: catalog.schema.json
    `$defs.benchmarks_snapshot`). Candidates: the Go catalog's listed models with a monthly limit
    under the deployed plan (`opencode-go/<id>`) minus any model a subscription rail already serves
    (its twin is a subscription candidate's AA row — Go is the cheaper door to the priced catalog,
    never a second door to a model the subscription pays for; operator ruling 2026-11-01), priced
    at the plan's discounted list price
    (`GET /catalog/opencode` `pricing`); the OpenRouter catalog's models (`GET /catalog/openrouter`),
    priced at the SELECTED endpoint — null until a cell passed the entry canary (never the
    headline); the subscription rails' candidates as given, unpriced — the anthropic aliases, and the
    codex ids (`codex/<id>`: the ENROLLED account's model evidence, never a catalog — the spike
    §Live usage payload shape; they join the AA row by tail, `codex/gpt-6-astra` ↔ `openai/gpt-6-astra`).
    Prices are $ per 1M tokens."""
    aa = {row[0]: row for row in capability if row[1] == AA_SOURCE}
    rails: dict[str, dict[str, dict]] = {"anthropic": {}, "opencode": {}, "openrouter": {}, "codex": {}}

    def row(pid: str, *, out_price=None, in_price=None, limit=None, provider=None, basis=None, rides=None) -> dict:
        aa_id = join_aa_id(pid, aa)
        bench = aa.get(aa_id) if aa_id else None
        return {"aa_id": aa_id, "intelligence": bench[2] if bench else None, "coding": bench[3] if bench else None,
                "agentic": bench[4] if bench else None, "out_price": out_price, "in_price": in_price,
                "monthly_limit_usd": limit, "provider": provider, "price_basis": basis,
                "rides": rides or {"clean": 0, "judged": 0, "prior": 1.0}}

    for alias in anthropic_aliases:
        rails["anthropic"][alias] = row(alias)
    for pid in codex_candidates:
        if not pid.startswith(RAIL_PREFIX["codex"]):
            raise ValueError(f"codex candidate {pid!r} is not spelled codex/<id>")
        rails["codex"][pid] = row(pid)
    pricing = (go_catalog.get("pricing") or {}).get("models") or {}
    subscription_aa = [r["aa_id"] for rail in PRICELESS_RAILS for r in rails[rail].values() if r["aa_id"]]
    for mid, m in sorted(go_catalog["models"].items()):
        if m.get("listed") and m.get("monthly_limit_usd") is not None:
            if any(same_model(RAIL_PREFIX["opencode"] + mid, aa) for aa in subscription_aa):
                continue  # a subscription rail serves this model: not a Go candidate (ruling 2026-11-01)
            p = pricing.get(mid) or {}
            rides = p.get("rides") or {}
            rails["opencode"][RAIL_PREFIX["opencode"] + mid] = row(
                RAIL_PREFIX["opencode"] + mid, out_price=p.get("out"), in_price=p.get("in"), limit=m["monthly_limit_usd"],
                basis=p.get("basis"), rides={"clean": rides.get("clean", 0), "judged": rides.get("judged", 0), "prior": 1.0})
    for mid, m in sorted((openrouter_catalog.get("models") or {}).items()):
        sel = m.get("selected")
        ep = next((e for e in m.get("endpoints") or [] if e["slug"] == sel and e.get("service_tier") is None), None) if sel else None
        if ep is None and sel:
            ep = next((e for e in m["endpoints"] if e["slug"] == sel), None)
        rides = (ep or {}).get("rides") or {}
        prior = (ep["uptime_1d"] / 100.0) if ep and ep.get("uptime_1d") is not None else 1.0
        rails["openrouter"][mid] = row(mid, out_price=ep["out_price"] if ep else None, in_price=ep["in_price"] if ep else None,
                                       provider=sel, basis="endpoint" if ep else None,
                                       rides={"clean": rides.get("clean", 0), "judged": rides.get("judged", 0), "prior": round(prior, 6)})
    pulled = max((float(r[5]) for r in aa.values() if r[5] is not None), default=None)
    return {
        "snapshot_at": snapshot_at,
        "sources": {
            "capability": {"source": AA_SOURCE, "pulled_at": _iso(pulled) if pulled else None, "rows": len(aa)},
            "go_catalog": {"fetched_at": go_catalog["sources"]["config"]["fetched_at"],
                           "fee_usd_month": (go_catalog.get("pricing") or {}).get("fee_usd_month"),
                           "draw_30d_usd": (go_catalog.get("pricing") or {}).get("draw_30d_usd")},
            "openrouter_catalog": {"fetched_at": openrouter_catalog.get("fetched_at"),
                                   "cells": openrouter_catalog.get("cells") or {}},
        },
        "rails": {rail: dict(sorted(rows.items())) for rail, rows in rails.items()},
    }


def _per_million(v) -> float | None:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return round(f * 1_000_000, 9) if f >= 0 else None
