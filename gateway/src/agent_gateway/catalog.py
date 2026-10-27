"""The Go catalog leg (GW-CATALOG-GO, specs/endpoints/catalog.md).

The opencode rail's vendor facts, read from the vendor on a schedule instead of copied by hand
(docs/spikes/opencode-go-catalog.md, operator rulings 2026-10-17). Two sources, each its own
snapshot:

- **config** — two reads, merged the way the vendor's own client merges them
  (`packages/core/src/plugin/provider/opencode.ts`): the **catalog** read, models.dev's `api.json`
  (public, the vendor's own registry — its `opencode-go` provider's models, their `cost` and
  `cost.tiers`, context/output limits, tool support and the per-model `provider` override the
  `dialect` comes from — `npm: "@ai-sdk/anthropic"` → anthropic, no override → openai; a
  `status: deprecated` row is dropped before the overlay, as the vendor's loader drops it), then the **config** read,
  `GET https://opencode.ai/console/api/v2/config` (the Go key as a bearer, a User-Agent and a fresh
  `x-opencode-session`): the workspace's OVERRIDES on that catalog — `disabled: true` unlists a
  model, a `cost`, `limit`, `name`, `family` or `capabilities.tools` present on a row wins. Until
  2026-10-20 the console answer carried the whole catalog; since then it carries the overrides
  only, which is what it always was to the vendor's client.
- **docs** — the vendor's Go page source (`go.mdx`, fetched unauthenticated from the vendor repo):
  each plan's monthly fee (the page's Plan table — the Go rail's price, GW-MODEL-TIERS, divides
  it by what the plan buys), each model's monthly limit per plan, the promotion multiplier, the
  peak price rows, the peak hours and the 5h/weekly/monthly share of the monthly limit. Parsed
  strictly: any drift from the shape this file knows is a parse failure, never a guess.

A refresh that fails — the fetch, the parse, or an implausible drop in the model count — keeps
the source's last good snapshot (persisted in the gateway's store, so a restart starts from it)
and says so on `/metrics`. Nothing here decides admission; the snapshot is read by it.
"""

from __future__ import annotations

import asyncio
import logging
import re
import uuid
from collections.abc import Callable
from dataclasses import dataclass

import httpx

from . import __version__
from .config import WEEKDAYS, Policy, PriceRow, wire_model
from .store import Store, iso

log = logging.getLogger("gateway.catalog")

SOURCES = ("config", "docs")
READS = {"config": ("catalog", "config"), "docs": ("docs",)}  # a source's reads, in order; each read has a URL
OUTCOMES = ("ok", "fetch-failed", "parse-failed", "implausible")
# ⚖ #2933 (operator ruling 2026-10-26): a LISTED model whose dialect the parser does not know is
# dropped from that refresh — counted and logged by the reason, and the rest of the source lands
# (a model the gateway cannot speak cannot be admitted, so dropping loses nothing that worked).
# Whole-source shape failures stay parse failures. The dialect is still never guessed.
DROPPED_REASONS = ("unknown-dialect",)
PLANS = ("go", "go-plus")
PROVIDER = "opencode-go"
# ⚖ a fresh snapshot with fewer than this share of the last good one's models is implausible (a
# vendor outage answering a stub, a truncated page) and is not taken; zero models never is.
MIN_KEPT_SHARE = 0.5
USER_AGENT = f"agent-gateway/{__version__} (go-catalog)"
FETCH_TIMEOUT_S = 30.0


class ParseError(ValueError):
    """The source answered, but not in the shape this parser knows — the snapshot is not taken."""


@dataclass(frozen=True)
class Snapshot:
    source: str
    fetched_at: float
    body: dict

    @property
    def models(self) -> int:
        if self.source == "config":
            return len(self.body["models"])
        return len({m for plan in self.body["plans"].values() for m in plan})


# -- config: models.dev's catalog, then the console's V2 config as the overlay ------------------
def _rate(where: str, v, *, optional: bool = False) -> float | None:
    if v is None and optional:
        return None
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v < 0:
        raise ParseError(f"{where} is not a non-negative number: {v!r}")
    return float(v)


def _tier_size(where: str, tier) -> int:
    if not isinstance(tier, dict) or tier.get("type") != "context" or isinstance(tier.get("size"), bool) \
            or not isinstance(tier.get("size"), int):
        raise ParseError(f"{where}.tier is not {{type: context, size: <int>}}")
    return tier["size"]


def _ascending(where: str, tiers: list[dict]) -> None:
    if [t["above_tokens"] for t in tiers] != sorted({t["above_tokens"] for t in tiers}):
        raise ParseError(f"{where} tiers are not strictly ascending by context size")


def _limit(where: str, limit, *, required: bool) -> dict:
    """`limit: {context, output}` → `{context, output}` (ints). An overlay row may carry one of the
    two; a catalog row carries both."""
    if not isinstance(limit, dict):
        raise ParseError(f"{where}.limit is not an object")
    out: dict[str, int] = {}
    for k in ("context", "output"):
        v = limit.get(k)
        if v is None and not required:
            continue
        if isinstance(v, bool) or not isinstance(v, int):
            raise ParseError(f"{where}.limit.{k} is not an integer")
        out[k] = v
    return out


def _flat_cost(where: str, c: dict) -> dict:
    """models.dev's cost row (`input`, `output`, `cache_read`?, `cache_write`?) → the leg's rate row."""
    return {"in": _rate(f"{where}.input", c.get("input")), "out": _rate(f"{where}.output", c.get("output")),
            "cache_read": _rate(f"{where}.cache_read", c.get("cache_read"), optional=True),
            "cache_write": _rate(f"{where}.cache_write", c.get("cache_write"), optional=True)}


def _name_family(where: str, row: dict) -> dict:
    out = {}
    for k in ("name", "family"):
        if k in row:
            if row[k] is not None and not isinstance(row[k], str):
                raise ParseError(f"{where}.{k} is not a string")
            out[k] = row[k]
    return out


# ⚖ the npm packages the gateway can speak, one wire dialect each (GW-CATALOG-GO §The model's
# dialect): no `npm` is the openai one. Any other value is not a dialect — its row is dropped
# (#2933), not guessed and not a whole-source failure.
KNOWN_NPM: dict[str, str] = {"@ai-sdk/anthropic": "anthropic"}


def _dialect(where: str, provider, dropped: list[dict], model: str) -> str | None:
    """The model's wire dialect (GW-CATALOG-GO): the per-model `provider` override's `npm` —
    `@ai-sdk/anthropic` serves the model on the anthropic endpoint only, no override on the openai
    one (the vendor's two Go endpoints). Returns None when the row is DROPPED: any other `npm`
    value is a dialect this parser does not know — recorded `{model, reason: unknown-dialect}` in
    `dropped` (counted and logged by the refresh, #2933), never a guess and never a whole-source
    failure (only the row is lost). A `provider` that is not an object, or an `npm` that is not a
    string, is a shape the parser does not know: still a parse failure of the whole source."""
    if provider is None:
        return "openai"
    if not isinstance(provider, dict):
        raise ParseError(f"{where}.provider is not an object")
    npm = provider.get("npm")
    if npm is None:
        return "openai"
    if npm == "@ai-sdk/anthropic":
        return "anthropic"
    if not isinstance(npm, str):
        raise ParseError(f"{where}.provider.npm is not a string")
    dropped.append({"model": model, "reason": "unknown-dialect"})
    return None


def parse_catalog(doc) -> tuple[dict, list[dict]]:
    """models.dev's `api.json` → (`{models: {id: {name, family, tools, dialect, context, output,
    cost: [{above_tokens, in, out, cache_read, cache_write}]}}}`, the dropped rows) for the
    `opencode-go` provider: the base rows the console overlays. `dialect` is the per-model
    `provider` override's dialect (`_dialect`); a row whose override names a dialect this parser
    does not know is DROPPED — `{model, reason}` into the returned list, counted and logged by the
    refresh, and the other rows land (⇁ #2933). A row whose `status` is `deprecated` is not listed
    (the vendor's own loader drops it before any overlay — `packages/core/src/plugin/models-dev.ts`);
    `cost.tiers[]` rows are the rate above each `tier.size`; a `context_over_200k` (the legacy
    spelling) with no `tiers` beside it is a shape this parser does not know. Any other missing
    field fails the parse — whole-source shape failures stay whole-source."""
    if not isinstance(doc, dict):
        raise ParseError("not an object")
    prov = doc.get(PROVIDER)
    if not isinstance(prov, dict) or not isinstance(prov.get("models"), dict):
        raise ParseError(f"no `{PROVIDER}.models` object")
    out: dict[str, dict] = {}
    dropped: list[dict] = []
    for mid, row in prov["models"].items():
        where = f"{PROVIDER}.models.{mid}"
        if not isinstance(row, dict):
            raise ParseError(f"{where} is not an object")
        status = row.get("status")
        if status is not None and not isinstance(status, str):
            raise ParseError(f"{where}.status is not a string")
        if status == "deprecated":
            continue
        cost = row.get("cost")
        if not isinstance(cost, dict):
            raise ParseError(f"{where}.cost is not an object")
        tiers = [{"above_tokens": 0, **_flat_cost(f"{where}.cost", cost)}]
        extra = cost.get("tiers")
        if extra is not None:
            if not isinstance(extra, list):
                raise ParseError(f"{where}.cost.tiers is not a list")
            for i, c in enumerate(extra):
                if not isinstance(c, dict):
                    raise ParseError(f"{where}.cost.tiers[{i}] is not an object")
                tiers.append({"above_tokens": _tier_size(f"{where}.cost.tiers[{i}]", c.get("tier")),
                              **_flat_cost(f"{where}.cost.tiers[{i}]", c)})
        elif "context_over_200k" in cost:
            raise ParseError(f"{where}.cost carries context_over_200k with no tiers — the legacy spelling alone is not read")
        _ascending(f"{where}.cost", tiers)
        limit = _limit(where, row.get("limit"), required=True)
        tools = row.get("tool_call")
        if not isinstance(tools, bool):
            raise ParseError(f"{where}.tool_call is not a boolean")
        names = _name_family(where, row)
        dialect = _dialect(where, row.get("provider"), dropped, mid)
        if dialect is None:  # drop-and-count (#2933): the row is absent from this refresh
            continue
        out[mid] = {"name": names.get("name"), "family": names.get("family"), "tools": tools,
                    "dialect": dialect, "context": limit["context"], "output": limit["output"], "cost": tiers}
    return {"models": out}, dropped


def _config_cost(where: str, cost) -> list[dict]:
    """The console's `cost` (a list of rows, or one row — the vendor reads both): the base row,
    then each `tier: {type: context, size}` row as the rate above that many tokens."""
    if isinstance(cost, dict):
        cost = [cost]
    if not isinstance(cost, list) or not cost:
        raise ParseError(f"{where}.cost is not a non-empty list")
    tiers = []
    for i, c in enumerate(cost):
        if not isinstance(c, dict):
            raise ParseError(f"{where}.cost[{i}] is not an object")
        tier = c.get("tier")
        if i == 0:
            if tier is not None:
                raise ParseError(f"{where}.cost[0] carries a tier — the base row must not")
            above = 0
        else:
            above = _tier_size(f"{where}.cost[{i}]", tier)
        cache = c.get("cache") or {}
        if not isinstance(cache, dict):
            raise ParseError(f"{where}.cost[{i}].cache is not an object")
        tiers.append({"above_tokens": above, "in": _rate(f"{where}.cost[{i}].input", c.get("input")),
                      "out": _rate(f"{where}.cost[{i}].output", c.get("output")),
                      "cache_read": _rate(f"{where}.cost[{i}].cache.read", cache.get("read"), optional=True),
                      "cache_write": _rate(f"{where}.cost[{i}].cache.write", cache.get("write"), optional=True)})
    _ascending(f"{where}.cost", tiers)
    return tiers


def parse_config(doc) -> dict:
    """`providers["opencode-go"].models` → the workspace OVERRIDES `{overrides: {id: {disabled?,
    name?, family?, tools?, limit?: {context?, output?}, cost?: [...]}}}` — only the fields a row
    carries (the vendor applies each one "if defined" onto the catalog row). A field that is present
    but not of its shape fails the whole parse; an answer without the Go provider is no answer."""
    if not isinstance(doc, dict) or not isinstance(doc.get("providers"), dict):
        raise ParseError("no `providers` object")
    prov = doc["providers"].get(PROVIDER)
    if not isinstance(prov, dict) or not isinstance(prov.get("models"), dict):
        raise ParseError(f"no `providers.{PROVIDER}.models` object")
    out: dict[str, dict] = {}
    for mid, row in prov["models"].items():
        where = f"{PROVIDER}.models.{mid}"
        if not isinstance(row, dict):
            raise ParseError(f"{where} is not an object")
        o: dict = _name_family(where, row)
        if "disabled" in row:
            if not isinstance(row["disabled"], bool):
                raise ParseError(f"{where}.disabled is not a boolean")
            o["disabled"] = row["disabled"]
        if "capabilities" in row:
            caps = row["capabilities"]
            if not isinstance(caps, dict):
                raise ParseError(f"{where}.capabilities is not an object")
            if "tools" in caps:
                if not isinstance(caps["tools"], bool):
                    raise ParseError(f"{where}.capabilities.tools is not a boolean")
                o["tools"] = caps["tools"]
        if "limit" in row:
            o["limit"] = _limit(where, row["limit"], required=False)
        if "cost" in row:
            o["cost"] = _config_cost(where, row["cost"])
        out[mid] = o
    return {"overrides": out}, []  # the overlay never drops a row (drop-and-count reads only the catalog)


def merge(catalog: dict, config: dict) -> dict:
    """The listing — the config snapshot's body: the catalog's rows with the console's overrides
    applied the vendor's way. `disabled: true` unlists the row; a present `cost` replaces its tiers;
    a present `limit` field, `name`, `family` or `tools` wins. An override naming no catalog row is
    listed only when it is a complete row of its own (a `cost` and both limits; `tools` false
    unless it says so); anything less names nothing to list."""
    models: dict[str, dict] = {}
    overrides = config["overrides"]
    for mid, row in catalog["models"].items():
        o = overrides.get(mid)
        if o is None:
            models[mid] = row
            continue
        if o.get("disabled") is True:
            continue
        new = dict(row)
        for k in ("name", "family", "tools", "cost"):
            if k in o:
                new[k] = o[k]
        new.update(o.get("limit", {}))
        models[mid] = new
    for mid, o in overrides.items():
        if mid in catalog["models"] or o.get("disabled") is True:
            continue
        lim = o.get("limit", {})
        if "cost" in o and "context" in lim and "output" in lim:
            # A console-only row carries no models.dev `provider` override: no override → openai
            # (GW-CATALOG-GO), the same default the catalog read gives a row without one.
            models[mid] = {"name": o.get("name"), "family": o.get("family"), "tools": o.get("tools", False),
                           "dialect": "openai", "context": lim["context"], "output": lim["output"],
                           "cost": o["cost"]}
    return {"models": models}


# -- docs: the vendor's go.mdx ----------------------------------------------------------------
_PLAN_HEADER = ["Model", "Input", "Output", "Cached Read", "Cached Write", "Monthly limit"]
_FEE_HEADER = ["Plan", "Price", "Included usage"]  # the page's Plan table: `| **Go** | **$10/month** | … |`
_FEE_PLANS = {"**Go**": "go", "**Go Plus**": "go-plus"}
_FEE = re.compile(r"^\*\*\$(?P<usd>[\d.]+)/month\*\*$")
_SUFFIX = re.compile(r"^(?P<name>.+?)\s*\((?P<tag>Off-Peak|Peak|[≤>]\s*[\d.]+K tokens)\)$")
# ⚖ #2933 (ruling, case (a): the live page of 2026-10-25): a plan row's PROMOTION suffix — a
# trailing ` (<N>% off)` on a name the Endpoints table has. The name is read without it; the
# promotion multiplier N/100 (0.5 at 50% off) is kept per model, beside the Nx `bonus` multiplier
# the limit cells carry (a price promotion, not a usage one — it is the multiplier the page's own
# struck price cells display, and no row here is priced by the docs leg: §(Peak) reads only Peak rows).
_PROMO = re.compile(r"^(?P<name>.+?)\s*\((?P<digits>\d+)%\s+off\)$")
_LIMIT = re.compile(r"^(?:~~\$[\d.]+~~\s*)?\*\*\$(?P<usd>[\d.]+)\*\*(?:<br\s*/>.*)?$")
_UNLIMITED = re.compile(r"^\*\*Unlimited\*\*(?:<br\s*/>.*)?$")
_BONUS = re.compile(r"<small>\s*(?P<x>\d+)x\b")
_PRICE = re.compile(r"^\$(?P<usd>[\d.]+)$")
_SHARES = re.compile(r"5-hour\s+—\s+(?P<h5>\d+)% of the monthly limit;\s*weekly\s+—\s+(?P<w>\d+)%;\s*and\s+monthly\s+—\s+(?P<m>\d+)%")
_PEAK = re.compile(r"Peak hours are (?P<spans>\d\d:\d\d-\d\d:\d\d(?:(?:,| and) \d\d:\d\d-\d\d:\d\d)*) UTC, (?P<d0>[A-Z][a-z]+day) through (?P<d1>[A-Z][a-z]+day)")
_DAYS = {"Monday": "mon", "Tuesday": "tue", "Wednesday": "wed", "Thursday": "thu", "Friday": "fri", "Saturday": "sat", "Sunday": "sun"}


def _cells(line: str) -> list[str]:
    return [c.strip() for c in line.strip().strip("|").split("|")]


def _tables(text: str) -> list[tuple[list[str], list[list[str]]]]:
    lines = text.splitlines()
    out, i = [], 0
    while i < len(lines):
        if lines[i].lstrip().startswith("|") and i + 1 < len(lines) and re.match(r"^\s*\|\s*-{3,}", lines[i + 1]):
            header, rows, j = _cells(lines[i]), [], i + 2
            while j < len(lines) and lines[j].lstrip().startswith("|"):
                rows.append(_cells(lines[j]))
                j += 1
            out.append((header, rows))
            i = j
        else:
            i += 1
    return out


def _slot(text: str, slot: str) -> str:
    m = re.search(r'<div slot="' + re.escape(slot) + r'">(?P<body>.*?)</div>', text, re.S)
    if not m:
        raise ParseError(f'no <div slot="{slot}"> plan tab')
    return m.group("body")


def _price(where: str, cell: str) -> float | None:
    if cell == "-":
        return None
    if cell == "Free":
        return 0.0
    m = _PRICE.match(cell)
    if not m:
        raise ParseError(f"{where}: price cell {cell!r} is not $N, Free or -")
    return float(m.group("usd"))


def _hour(where: str, hhmm: str) -> int:
    h, mm = int(hhmm[:2]), int(hhmm[3:])
    if mm != 0 or not 0 <= h <= 24:
        raise ParseError(f"{where}: {hhmm} is not a whole UTC hour")
    return h


def parse_docs(text: str) -> tuple[dict, list[dict]]:
    """The Go page → (`{plan_fees: {go: usd, go-plus: usd}, plans: {go: {id: usd | "unlimited"},
    go-plus: {…}}, bonus: {id: x}, promotion: {id: multiplier}, peak: {id: {in, out, cache_read,
    cache_write}}, peak_hours_utc, peak_weekdays, window_shares}`, the dropped rows — []). Rows
    are keyed by MODEL id through the page's own Endpoints table (display name → Model ID); the
    fees by the Plan table's plan names. A plan row's trailing ` (<N>% off)` is the page's PROMOTION
    spelling on a name the table has: the row is read under the stripped name and its multiplier
    N/100 is kept per model (#2933 case (a)) — a promotion, never a dialect. A plan row whose name
    is still not in the Endpoints table is a shape the leg does not know (ruling: drop-and-count
    was ruled for the DIALECT; the docs leg keeps its parse failure — the Endpoints table is the
    page's own index, an unlisted name there is a page fault). The docs leg never drops: the list
    is always empty."""
    if not isinstance(text, str) or not text.strip():
        raise ParseError("empty page")
    ids: dict[str, str] = {}
    fees: dict[str, float] = {}
    for header, rows in _tables(text):
        if header[:2] == ["Model", "Model ID"]:
            for r in rows:
                if len(r) != len(header) or not r[0] or not r[1]:
                    raise ParseError(f"Endpoints row {r!r}: {len(r)} cells, expected {len(header)} with a name and an id")
                ids[r[0]] = r[1]
        elif header == _FEE_HEADER:
            for r in rows:
                if len(r) != len(_FEE_HEADER) or r[0] not in _FEE_PLANS:
                    raise ParseError(f"Plan row {r!r}: expected {' | '.join(_FEE_HEADER)} naming {' / '.join(_FEE_PLANS)}")
                m = _FEE.match(r[1])
                if not m:
                    raise ParseError(f"Plan row {r[0]}: price cell {r[1]!r} is not **$N/month**")
                fees[_FEE_PLANS[r[0]]] = float(m.group("usd"))
    if not ids:
        raise ParseError("no Endpoints table (Model | Model ID)")
    if set(fees) != set(PLANS):
        raise ParseError(f"no Plan table ({' | '.join(_FEE_HEADER)}) pricing both plans — read {sorted(fees) or 'none'}")
    plans: dict[str, dict] = {}
    bonus: dict[str, int] = {}
    promotion: dict[str, float] = {}
    peak: dict[str, dict] = {}
    for plan in PLANS:
        tabs = _tables(_slot(text, plan))
        if len(tabs) != 1 or tabs[0][0] != _PLAN_HEADER:
            raise ParseError(f"plan {plan}: expected one table headed {' | '.join(_PLAN_HEADER)}")
        limits: dict[str, float | str] = {}
        for r in tabs[0][1]:
            where = f"plan {plan} row {r[0]!r}"
            if len(r) != len(_PLAN_HEADER):
                raise ParseError(f"{where}: {len(r)} cells, expected {len(_PLAN_HEADER)}")
            m = _SUFFIX.match(r[0])
            name, tag = (m.group("name"), m.group("tag")) if m else (r[0], None)
            promo = None
            if tag is None and (pm := _PROMO.match(r[0])):
                name, promo = pm.group("name"), float(pm.group("digits")) / 100
            if name not in ids:
                raise ParseError(f"{where}: {name!r} is not in the Endpoints table")
            mid = ids[name]
            cell = r[5]
            if _UNLIMITED.match(cell):
                lim: float | str = "unlimited"
            elif lm := _LIMIT.match(cell):
                lim = float(lm.group("usd"))
            else:
                raise ParseError(f"{where}: monthly limit {cell!r} is neither **$N** nor **Unlimited**")
            if mid in limits and limits[mid] != lim:
                raise ParseError(f"{where}: two monthly limits for {mid} ({limits[mid]} vs {lim})")
            limits[mid] = lim
            if (bm := _BONUS.search(cell)) and plan == "go":
                bonus[mid] = int(bm.group("x"))
            if tag == "Peak" and plan == "go":
                peak[mid] = {"in": _price(where, r[1]), "out": _price(where, r[2]),
                             "cache_read": _price(where, r[3]), "cache_write": _price(where, r[4])}
            if promo is not None:
                if mid in promotion and promotion[mid] != promo:
                    raise ParseError(f"{where}: two promotion multipliers for {mid} ({promotion[mid]} vs {promo})")
                promotion[mid] = promo
        if not limits:
            raise ParseError(f"plan {plan}: the table has no rows")
        plans[plan] = limits
    shares = _SHARES.search(text)
    if not shares:
        raise ParseError("no '5-hour — N% of the monthly limit; weekly — N%; and monthly — N%' sentence")
    window_shares = {"5h": int(shares["h5"]) / 100, "7d": int(shares["w"]) / 100, "30d": int(shares["m"]) / 100}
    spans = _PEAK.findall(text)
    hours: list[list[int]] = []
    days: list[str] = []
    if len(spans) > 1:
        raise ParseError(f"{len(spans)} peak-hours sentences — the parser knows one")
    if spans:
        m = _PEAK.search(text)
        for span in re.split(r",| and ", m["spans"]):
            lo, hi = span.strip().split("-")
            hours.append([_hour("peak hours", lo), _hour("peak hours", hi)])
        if m["d0"] not in _DAYS or m["d1"] not in _DAYS:
            raise ParseError(f"peak days {m['d0']}..{m['d1']} are not weekdays")
        order = list(_DAYS.values())
        a, b = order.index(_DAYS[m["d0"]]), order.index(_DAYS[m["d1"]])
        if b < a:
            raise ParseError("peak days run backwards")
        days = order[a:b + 1]
    if peak and not hours:
        raise ParseError("peak rows but no 'Peak hours are … UTC, <day> through <day>' sentence")
    return ({"plan_fees": fees, "plans": plans, "bonus": bonus, "promotion": promotion, "peak": peak,
             "peak_hours_utc": hours, "peak_weekdays": days, "window_shares": window_shares}), []


# each parser returns (body, dropped rows) — `docs` never drops; drop-and-count rides the
# catalog read (#2933)
PARSERS: dict[str, Callable] = {"catalog": lambda r: parse_catalog(r.json()), "config": lambda r: parse_config(r.json()),
                                "docs": lambda r: parse_docs(r.text)}


@dataclass(frozen=True)
class GoModel:
    """What admission reads for one listed Go model (GW-SESSIONS-ADMIT §Capacity): its cost tiers
    `((above_tokens, row), …)` ascending, its peak row and the peak hours, its monthly limit under
    the policy's plan (None = unlimited) and the window shares."""
    cost: tuple[tuple[int, PriceRow], ...]
    peak: PriceRow | None
    peak_hours_utc: tuple[tuple[int, int], ...]
    peak_weekdays: frozenset[int]
    monthly_limit: float | None
    shares: dict[str, float]


def _row(d: dict) -> PriceRow:
    return PriceRow(d["in"], d["out"], d.get("cache_read"), d.get("cache_write"))


# -- the leg ----------------------------------------------------------------------------------
class GoCatalog:
    """The two snapshots, their refresh, and what /metrics and GET /catalog/opencode read."""

    def __init__(self, policy: Policy, store: Store, client: httpx.AsyncClient, urls: dict[str, str],
                 api_key: str | None, clock, refresh_s: float):
        self.policy = policy
        self.store = store
        self.client = client
        self.urls = urls
        self.api_key = api_key
        self.clock = clock
        self.refresh_s = refresh_s
        rail = policy.rails.get("opencode")
        self.plan = rail.plan if rail else None
        ids = ([m for tier in rail.models.values() for m in tier] + list(rail.side_models)) if rail else []
        self.policy_models = tuple(sorted({wire_model("opencode", m) for m in ids}))
        self.snapshots: dict[str, Snapshot] = {}
        self.refreshes: dict[tuple[str, str], int] = {(s, o): 0 for s in SOURCES for o in OUTCOMES}
        self.dropped: dict[tuple[str, str], int] = {(s, r): 0 for s in SOURCES for r in DROPPED_REASONS}
        self.last_outcome: dict[str, str] = {}
        self.last_attempt: dict[str, float] = {}
        self.served_from: float | None = None  # the oldest stored snapshot a restart serves instead of refreshing (startup_delay)
        for s in SOURCES:
            if (row := store.snapshot_load(s)) is not None:
                snap = Snapshot(s, row[0], row[1])
                try:
                    snap.models  # noqa: B018 — a body of another shape (an older build's) is no snapshot
                except (KeyError, TypeError, AttributeError):
                    log.error("catalog: the stored %s snapshot is not this build's shape — ignored", s)
                    continue
                self.snapshots[s] = snap
                log.info("catalog: %s snapshot loaded from the store (fetched %s, %d models)", s, iso(row[0]),
                         self.snapshots[s].models)

    def _headers(self, read: str) -> dict[str, str]:
        """Per READ: the console read carries the key and a client identity (Cloudflare answers 1010
        to a request without one; the vendor routes by session); the catalog and docs reads carry none."""
        h = {"user-agent": USER_AGENT}
        if read == "config":
            h |= {"authorization": f"Bearer {self.api_key}", "x-opencode-session": str(uuid.uuid4())}
        return h

    async def refresh_source(self, source: str) -> str:
        now = self.clock()
        self.last_attempt[source] = now
        outcome = await self._refresh(source, now)
        self.refreshes[(source, outcome)] += 1
        self.last_outcome[source] = outcome
        return outcome

    async def _refresh(self, source: str, now: float) -> str:
        """The source's reads in order (READS); the first one that fails ends the refresh with its
        outcome, the log line naming the read — no read is a guess for another."""
        if source == "config" and not self.api_key:
            log.error("catalog: %s fetch skipped — no OPENCODE_GO_API_KEY (no request is sent)", source)
            return "fetch-failed"
        parts: dict[str, dict] = {}
        dropped: list[dict] = []
        for read in READS[source]:
            try:
                r = await self.client.get(self.urls[read], headers=self._headers(read), timeout=FETCH_TIMEOUT_S)
            except httpx.HTTPError as e:
                log.warning("catalog: %s fetch failed (%s read: %s) — keeping the last good snapshot", source, read, type(e).__name__)
                return "fetch-failed"
            if r.status_code != 200:
                log.warning("catalog: %s fetch answered %d (%s read) — keeping the last good snapshot", source, r.status_code, read)
                return "fetch-failed"
            try:
                parts[read], read_dropped = PARSERS[read](r)
            except Exception as e:  # noqa: BLE001 — ANY drift from the known shape is a parse failure, never a guess
                log.error("catalog: %s parse failed (%s read — %s: %s) — keeping the last good snapshot", source, read, type(e).__name__, e)
                return "parse-failed"
            dropped += read_dropped
        if dropped:
            for d in dropped:
                self.dropped[(source, d["reason"])] += 1
            log.info("catalog: %s dropped %d model(s) — %s", source, len(dropped),
                     "; ".join(f"{d['model']} ({d['reason']})" for d in dropped))
        body = merge(parts["catalog"], parts["config"]) if source == "config" else parts["docs"]
        fresh = Snapshot(source, now, body)
        last = self.snapshots.get(source)
        if fresh.models == 0 or (last is not None and fresh.models < MIN_KEPT_SHARE * last.models):
            log.error("catalog: %s implausible — %d models against the last good %d — keeping the last good snapshot",
                      source, fresh.models, last.models if last else 0)
            return "implausible"
        self.store.snapshot_save(source, now, body)
        self.snapshots[source] = fresh
        missing = self.missing(source)
        log.info("catalog: %s refreshed — %d models%s", source, fresh.models,
                 f"; policy model(s) not covered: {', '.join(missing)}" if missing else "")
        return "ok"

    async def refresh(self) -> dict[str, str]:
        """Both sources, each on its own: one source's failure never skips the other."""
        out: dict[str, str] = {}
        for s in SOURCES:
            try:
                out[s] = await self.refresh_source(s)
            except Exception:  # noqa: BLE001 — refresh_source records every outcome; this is the last net
                log.exception("catalog: %s refresh raised", s)
                out[s] = "fetch-failed"
        return out

    def startup_delay(self, now: float) -> float:
        """Seconds the loop waits before its first refresh: 0 when a source has no stored snapshot,
        there is no schedule, or the oldest snapshot is `refresh_s` old — else the rest of the oldest
        one's interval (both sources refresh together, as every tick does), so a pod roll inside it
        serves the stored snapshots instead of re-reading the vendor. The OpenRouter leg's
        `OpenRouterCatalog.startup_delay` is the same rule (#2775 gap 2)."""
        if self.refresh_s <= 0 or any(s not in self.snapshots for s in SOURCES):
            return 0.0
        oldest = min(self.snapshots[s].fetched_at for s in SOURCES)
        delay = oldest + self.refresh_s - now
        if delay <= 0:
            return 0.0
        self.served_from = oldest
        log.info("catalog: stored snapshots are %.0fs old (the oldest) — next refresh at %s", now - oldest, iso(oldest + self.refresh_s))
        return delay

    async def run(self) -> None:
        """The schedule: the first refresh of both sources after `startup_delay`, then every `refresh_s`."""
        delay = self.startup_delay(self.clock())
        if delay > 0:
            await asyncio.sleep(delay)
        while True:
            try:
                await self.refresh()
            except Exception:  # noqa: BLE001 — the loop must outlive any one bad refresh
                log.exception("catalog: refresh raised — retrying on the next tick")
            await asyncio.sleep(self.refresh_s)

    # -- reads ----------------------------------------------------------------------------------
    def context_for(self, model: str) -> int | None:
        """GW-SESSIONS-ENV's read for a WIRE model id: the catalog's `context` (models.dev's
        `limit.context` under the console's overlay) — the dispatch answer's `context_tokens` on the
        Go rail. None when no config snapshot exists or the model has no row: never a default
        (ruling 5 — the policy holds no copy of this fact, see Policy.from_dict)."""
        cfg = self.snapshots.get("config")
        row = cfg.body["models"].get(model) if cfg is not None else None
        return row["context"] if row is not None else None

    def dialect_for(self, model: str) -> str | None:
        """GW-SESSIONS-ADMIT's dialect read for a WIRE model id: the snapshot's `dialect` — the
        per-model `provider` override's dialect (`@ai-sdk/anthropic` → anthropic, no override →
        openai, GW-CATALOG-GO §The model's dialect) — the Go cell's dialect the walk takes the
        harness from. None when no config snapshot exists, the model has no row, or a snapshot
        written before this build carries none: never a guess (the walk then falls back to the
        rail's dialects; the `not-in-catalog` gate still holds an unlisted cell)."""
        cfg = self.snapshots.get("config")
        row = cfg.body["models"].get(model) if cfg is not None else None
        return row.get("dialect") if row is not None else None

    def go_model(self, model: str) -> GoModel | str:
        """Admission's read for a WIRE model id: its facts, or why it is not in the catalog (the
        `not-in-catalog` defer's detail — ruling 4: never a fallback price)."""
        cfg, docs = self.snapshots.get("config"), self.snapshots.get("docs")
        if cfg is None:
            return "no Go catalog (config) snapshot yet"
        row = cfg.body["models"].get(model)
        if row is None:
            return "not listed by the Go catalog"
        if docs is None:
            return "no Go page snapshot yet (no monthly limit)"
        lim = docs.body["plans"].get(self.plan or "", {}).get(model)
        if lim is None:
            return f"no monthly limit under plan {self.plan}"
        peak = docs.body["peak"].get(model)
        return GoModel(
            cost=tuple((t["above_tokens"], _row(t)) for t in row["cost"]),
            peak=_row(peak) if peak else None,
            peak_hours_utc=tuple((h[0], h[1]) for h in docs.body["peak_hours_utc"]),
            peak_weekdays=frozenset(WEEKDAYS[d] for d in docs.body["peak_weekdays"]),
            monthly_limit=None if lim == "unlimited" else float(lim),
            shares=dict(docs.body["window_shares"]),
        )

    def retry_at(self, now: float, fallback_s: float) -> float:
        """When a `not-in-catalog` verdict may change: the next scheduled refresh — `refresh_s` after
        this process's last attempt, or, before it attempts one, after the stored snapshot it serves
        (startup_delay) — else `fallback_s`."""
        anchor = max(self.last_attempt.values(), default=self.served_from)
        if anchor is not None and self.refresh_s > 0:
            return max(anchor + self.refresh_s, now + 1)
        return now + fallback_s

    def plan_fee(self) -> float | None:
        """The policy plan's monthly fee from the docs snapshot's Plan table (GW-MODEL-TIERS: the Go
        rail's price divides it). None = no docs snapshot, or one written before the table was read."""
        docs = self.snapshots.get("docs")
        if docs is None or self.plan is None:
            return None
        fee = (docs.body.get("plan_fees") or {}).get(self.plan)
        return float(fee) if isinstance(fee, (int, float)) else None

    def listed(self) -> list[str]:
        """The config snapshot's listed wire ids ([] = no snapshot)."""
        cfg = self.snapshots.get("config")
        return sorted(cfg.body["models"]) if cfg else []

    def monthly_limit(self, model: str) -> float | str | None:
        """The plan's monthly limit for a WIRE model id: usd, "unlimited", or None (no row)."""
        docs = self.snapshots.get("docs")
        if docs is None or self.plan is None:
            return None
        return docs.body["plans"].get(self.plan, {}).get(model)

    def missing(self, source: str) -> list[str]:
        """Policy Go models the source's snapshot does not cover (config: not listed; docs: no
        monthly-limit row under the policy's plan). [] when the source has no snapshot."""
        snap = self.snapshots.get(source)
        if snap is None:
            return []
        if source == "config":
            return [m for m in self.policy_models if m not in snap.body["models"]]
        return [m for m in self.policy_models if self.monthly_limit(m) is None]

    def view(self, pricing: dict | None = None) -> dict:
        """`GET /catalog/opencode`; `pricing` = the Go rail's price per model (capacity.go_pricing —
        the plan fee over what the plan bought; the app hands it in, this leg holds no ledger)."""
        now = self.clock()
        cfg, docs = self.snapshots.get("config"), self.snapshots.get("docs")
        listed = cfg.body["models"] if cfg else {}
        plan_rows = docs.body["plans"].get(self.plan, {}) if docs and self.plan else {}
        shares = docs.body["window_shares"] if docs else {}
        models = {}
        for mid in sorted(set(listed) | set(plan_rows)):
            row = listed.get(mid)
            lim = plan_rows.get(mid)
            models[mid] = {
                "listed": row is not None,
                "family": row["family"] if row else None,
                "tools": row["tools"] if row else None,
                "context": row["context"] if row else None,
                "output": row["output"] if row else None,
                "cost": row["cost"] if row else [],
                "peak": docs.body["peak"].get(mid) if docs else None,
                "bonus": docs.body["bonus"].get(mid) if docs else None,
                "promotion": docs.body.get("promotion", {}).get(mid) if docs else None,
                "monthly_limit_usd": lim,
                "windows_usd": ({w: round(lim * s, 6) for w, s in shares.items()} if isinstance(lim, float) else None),
            }
        return {
            "plan": self.plan,
            "plan_fee_usd_month": self.plan_fee(),
            "pricing": pricing if pricing is not None else {"fee_usd_month": None, "draw_30d_usd": 0.0, "models": {}},
            "sources": {s: {"fetched_at": iso(self.snapshots[s].fetched_at) if s in self.snapshots else None,
                            "age_s": round(now - self.snapshots[s].fetched_at, 3) if s in self.snapshots else None,
                            "models": self.snapshots[s].models if s in self.snapshots else 0,
                            "last_outcome": self.last_outcome.get(s),
                            "last_attempt_at": iso(self.last_attempt.get(s))} for s in SOURCES},
            "peak_hours_utc": docs.body["peak_hours_utc"] if docs else [],
            "peak_weekdays": docs.body["peak_weekdays"] if docs else [],
            "window_shares": shares,
            "models": models,
            "policy_models": {m: {"listed": m in listed, "monthly_limit_usd": plan_rows.get(m)} for m in self.policy_models},
        }

    def render(self) -> list[str]:
        """The `gateway_go_catalog_*` families (GW-CATALOG-GO; declared in metrics.schema.json)."""
        now = self.clock()
        out = ["# HELP gateway_go_catalog_age_seconds Seconds since the source's last good snapshot was fetched (absent: no snapshot yet).",
               "# TYPE gateway_go_catalog_age_seconds gauge"]
        out += [f'gateway_go_catalog_age_seconds{{source="{s}"}} {now - self.snapshots[s].fetched_at:.0f}'
                for s in SOURCES if s in self.snapshots]
        out += ["# HELP gateway_go_catalog_models Models in the source's last good snapshot (0: none yet).",
                "# TYPE gateway_go_catalog_models gauge"]
        out += [f'gateway_go_catalog_models{{source="{s}"}} {self.snapshots[s].models if s in self.snapshots else 0}' for s in SOURCES]
        out += ["# HELP gateway_go_catalog_refresh_total Refresh attempts by source and outcome.",
                "# TYPE gateway_go_catalog_refresh_total counter"]
        out += [f'gateway_go_catalog_refresh_total{{source="{s}",outcome="{o}"}} {self.refreshes[(s, o)]}'
                for s in SOURCES for o in OUTCOMES]
        out += ["# HELP gateway_go_catalog_last_outcome 1 for the outcome of the source's latest refresh attempt, 0 for the others.",
                "# TYPE gateway_go_catalog_last_outcome gauge"]
        out += [f'gateway_go_catalog_last_outcome{{source="{s}",outcome="{o}"}} {1 if self.last_outcome.get(s) == o else 0}'
                for s in SOURCES for o in OUTCOMES]
        out += ["# HELP gateway_go_catalog_policy_models_missing Policy Go models the source's snapshot does not cover (absent: no snapshot yet).",
                "# TYPE gateway_go_catalog_policy_models_missing gauge"]
        out += [f'gateway_go_catalog_policy_models_missing{{source="{s}"}} {len(self.missing(s))}' for s in SOURCES if s in self.snapshots]
        out += ["# HELP gateway_go_catalog_models_dropped_total Listed models the refreshes dropped (#2933: a dialect this parser does not know, drop-and-count), by reason.",
                "# TYPE gateway_go_catalog_models_dropped_total counter"]
        out += [f'gateway_go_catalog_models_dropped_total{{source="{s}",reason="{r}"}} {self.dropped[(s, r)]}'
                for s in SOURCES for r in DROPPED_REASONS]
        return out

