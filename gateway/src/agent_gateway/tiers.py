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
  score; each list is ordered cheapest-first by output price (then input price, then score
  descending, then id) and capped. The subscription rail has no price: score ascending is its
  cost proxy. An unbenched candidate, or an unpriced one on a priced rail, never tiers.
- `check`: the deployed lists EQUAL the derivation, order included — a hand edit fails.
- `apply_text`: rewrites only the rails' `models` blocks in the policy file's own layout.

Stdlib only; nothing here names a model id (GW-MODEL-RESOLVE: ids live in policy files).
"""

from __future__ import annotations

import json
import re
from collections.abc import Iterable
from datetime import UTC, datetime

from .config import RAIL_PREFIX, TIERS, TiersPolicy, tiers_policy

AA_SOURCE = "artificial-analysis"
ALIAS_PREFIX = RAIL_PREFIX["anthropic"]  # `claude/<alias>`: the subscription rail's family aliases
ALIAS_VENDOR = "anthropic"  # the AA vendor those aliases join under
# ⚖ ruling 3: the subscription rail has no per-token price — score ascending stands in for cost.
PRICELESS_RAILS = ("anthropic",)
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
                    return (_price(r["out_price"]), in_price if in_price is not None else float("inf"), -float(r[axis]), pid)
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
    `rails.<rail>.models` (order included); `{}` = the lists ARE the derivation."""
    tiers = tiers_policy(policy.get("tiers"))
    if tiers is None:
        raise ValueError("policy: no `tiers` block — the derivation has no rules to run under")
    mismatches: dict[str, dict[str, dict]] = {}
    rails = policy.get("rails") or {}
    for rail, lists in derive(benchmarks, tiers).items():
        actual = _lists((rails.get(rail) or {}).get("models")) if rail in rails else None
        for tier, expected in lists.items():
            got = None if actual is None else actual.get(tier)
            if got != expected:
                mismatches.setdefault(rail, {})[tier] = {"expected": expected, "actual": got}
    return mismatches


_MODELS_BLOCK = re.compile(r'("models"\s*:\s*\{)(?P<body>[^{}]*)(\})')


def apply_text(text: str, lists: dict[str, dict[str, list[str]]]) -> str:
    """The policy file with each named rail's `models` block rewritten to `lists[rail]`, every
    other byte untouched (the file's own indent and key alignment are kept). Refuses an empty
    list (the loader would refuse it) and a result that does not re-parse to the intended document."""
    want = json.loads(text)
    for rail, tiers in lists.items():
        for tier, ids in tiers.items():
            if not ids:
                raise ValueError(f"{rail}.{tier}: the derivation is empty — no benched candidate; the snapshot is the thing to fix")
        if rail not in (want.get("rails") or {}):
            raise ValueError(f"rails.{rail} is not in the policy")
        want["rails"][rail]["models"] = {tier: list(ids) for tier, ids in tiers.items()}
    out = text
    for rail, tiers in lists.items():
        start = re.search(r'^\s*"' + re.escape(rail) + r'"\s*:\s*\{', out, re.M)
        if not start:
            raise ValueError(f"rails.{rail}: block not found in the policy text")
        m = _MODELS_BLOCK.search(out, start.end())
        if not m:
            raise ValueError(f"rails.{rail}.models: block not found in the policy text")
        indent = re.search(r"\n([ \t]*)\S", m.group("body"))
        pad = indent.group(1) if indent else "        "
        close = re.search(r"\n([ \t]*)$", m.group("body"))
        width = max(len(f'"{t}":') for t in tiers)
        lines = [f'{pad}{(chr(34) + t + chr(34) + ":").ljust(width)} {json.dumps(list(ids))}' for t, ids in tiers.items()]
        body = "\n" + ",\n".join(lines) + "\n" + (close.group(1) if close else "")
        out = out[:m.start("body")] + body + out[m.end("body"):]
    if json.loads(out) != want:
        raise ValueError("apply: the rewritten text does not parse to the intended policy — nothing written")
    return out


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def build_snapshot(*, capability: list, go_catalog: dict, openrouter_models: dict, model_classes: dict,
                   anthropic_aliases: list[str], snapshot_at: str, openrouter_fetched_at: str) -> dict:
    """The benchmarks snapshot from its three inputs (the shape: catalog.schema.json
    `$defs.benchmarks_snapshot`). Candidates: the Go catalog's listed models with a monthly limit
    under the deployed plan (`opencode-go/<id>`); the ids model-classes.json names for the
    openrouter rail; the subscription rail's aliases as given. Prices are $ per 1M tokens on every
    rail (OpenRouter's per-token `pricing` scaled; a negative = dynamic = none)."""
    aa = {row[0]: row for row in capability if row[1] == AA_SOURCE}
    rails: dict[str, dict[str, dict]] = {"anthropic": {}, "opencode": {}, "openrouter": {}}

    def row(pid: str, *, out_price=None, in_price=None, limit=None) -> dict:
        aa_id = join_aa_id(pid, aa)
        bench = aa.get(aa_id) if aa_id else None
        return {"aa_id": aa_id, "intelligence": bench[2] if bench else None, "coding": bench[3] if bench else None,
                "agentic": bench[4] if bench else None, "out_price": out_price, "in_price": in_price,
                "monthly_limit_usd": limit}

    for alias in anthropic_aliases:
        rails["anthropic"][alias] = row(alias)
    for mid, m in sorted(go_catalog["models"].items()):
        if m.get("listed") and m.get("monthly_limit_usd") is not None:
            base = m["cost"][0] if m.get("cost") else {}
            rails["opencode"][RAIL_PREFIX["opencode"] + mid] = row(
                RAIL_PREFIX["opencode"] + mid, out_price=base.get("out"), in_price=base.get("in"), limit=m["monthly_limit_usd"])
    prices = {m["id"]: m.get("pricing") or {} for m in openrouter_models.get("data", []) if isinstance(m, dict) and m.get("id")}
    for entry in model_classes["models"].values():
        if not isinstance(entry, dict) or not isinstance(entry.get("ids"), dict):
            continue
        pid = entry["ids"].get("openrouter")
        if pid:
            p = prices.get(pid, {})
            rails["openrouter"][pid] = row(pid, out_price=_per_million(p.get("completion")), in_price=_per_million(p.get("prompt")))
    pulled = max((float(r[5]) for r in aa.values() if r[5] is not None), default=None)
    return {
        "snapshot_at": snapshot_at,
        "sources": {
            "capability": {"source": AA_SOURCE, "pulled_at": _iso(pulled) if pulled else None, "rows": len(aa)},
            "go_catalog": {"fetched_at": go_catalog["sources"]["config"]["fetched_at"]},
            "openrouter_models": {"fetched_at": openrouter_fetched_at},
        },
        "rails": {rail: dict(sorted(rows.items())) for rail, rows in rails.items()},
    }


def _per_million(v) -> float | None:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return round(f * 1_000_000, 9) if f >= 0 else None
