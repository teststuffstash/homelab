"""The Go catalog leg (GW-CATALOG-GO, specs/endpoints/catalog.md).

The opencode rail's vendor facts, read from the vendor on a schedule instead of copied by hand
(docs/spikes/opencode-go-catalog.md, operator rulings 2026-10-17). Two sources, each its own
snapshot:

- **config** — `GET https://opencode.ai/console/api/v2/config` (the Go key as a bearer, a
  User-Agent and a fresh `x-opencode-session`): the `opencode-go` provider's listed models, their
  `cost[]` tiers, context/output limits and tool support.
- **docs** — the vendor's Go page source (`go.mdx`, fetched unauthenticated from the vendor repo):
  each model's monthly limit per plan, the promotion multiplier, the peak price rows, the peak
  hours and the 5h/weekly/monthly share of the monthly limit. Parsed strictly: any drift from the
  shape this file knows is a parse failure, never a guess.

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
OUTCOMES = ("ok", "fetch-failed", "parse-failed", "implausible")
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


# -- config: the console's V2 config ----------------------------------------------------------
def _rate(where: str, v, *, optional: bool = False) -> float | None:
    if v is None and optional:
        return None
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v < 0:
        raise ParseError(f"{where} is not a non-negative number: {v!r}")
    return float(v)


def parse_config(doc) -> dict:
    """`providers["opencode-go"].models` → `{models: {id: {name, family, tools, context, output,
    cost: [{above_tokens, in, out, cache_read, cache_write}]}}}`. A row marked `disabled` is not
    listed; any other row that lacks a field the leg reads fails the whole parse."""
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
        if row.get("disabled") is True:
            continue
        cost = row.get("cost")
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
                if not isinstance(tier, dict) or tier.get("type") != "context" or not isinstance(tier.get("size"), int):
                    raise ParseError(f"{where}.cost[{i}].tier is not {{type: context, size: <int>}}")
                above = tier["size"]
            cache = c.get("cache") or {}
            if not isinstance(cache, dict):
                raise ParseError(f"{where}.cost[{i}].cache is not an object")
            tiers.append({"above_tokens": above, "in": _rate(f"{where}.cost[{i}].input", c.get("input")),
                          "out": _rate(f"{where}.cost[{i}].output", c.get("output")),
                          "cache_read": _rate(f"{where}.cost[{i}].cache.read", cache.get("read"), optional=True),
                          "cache_write": _rate(f"{where}.cost[{i}].cache.write", cache.get("write"), optional=True)})
        if [t["above_tokens"] for t in tiers] != sorted({t["above_tokens"] for t in tiers}):
            raise ParseError(f"{where}.cost tiers are not strictly ascending by context size")
        limit = row.get("limit") or {}
        caps = row.get("capabilities") or {}
        if not isinstance(limit, dict) or not isinstance(caps, dict):
            raise ParseError(f"{where}.limit / .capabilities is not an object")
        ctx, outp = limit.get("context"), limit.get("output")
        if not isinstance(ctx, int) or not isinstance(outp, int):
            raise ParseError(f"{where}.limit.context / .output is not an integer")
        out[mid] = {"name": row.get("name"), "family": row.get("family"), "tools": caps.get("tools") is True,
                    "context": ctx, "output": outp, "cost": tiers}
    return {"models": out}


# -- docs: the vendor's go.mdx ----------------------------------------------------------------
_PLAN_HEADER = ["Model", "Input", "Output", "Cached Read", "Cached Write", "Monthly limit"]
_SUFFIX = re.compile(r"^(?P<name>.+?)\s*\((?P<tag>Off-Peak|Peak|[≤>]\s*[\d.]+K tokens)\)$")
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


def parse_docs(text: str) -> dict:
    """The Go page → `{plans: {go: {id: usd | "unlimited"}, go-plus: {…}}, bonus: {id: x},
    peak: {id: {in, out, cache_read, cache_write}}, peak_hours_utc, peak_weekdays, window_shares}`.
    Rows are keyed by MODEL id through the page's own Endpoints table (display name → Model ID)."""
    if not isinstance(text, str) or not text.strip():
        raise ParseError("empty page")
    ids: dict[str, str] = {}
    for header, rows in _tables(text):
        if header[:2] == ["Model", "Model ID"]:
            for r in rows:
                if len(r) != len(header) or not r[0] or not r[1]:
                    raise ParseError(f"Endpoints row {r!r}: {len(r)} cells, expected {len(header)} with a name and an id")
                ids[r[0]] = r[1]
    if not ids:
        raise ParseError("no Endpoints table (Model | Model ID)")
    plans: dict[str, dict] = {}
    bonus: dict[str, int] = {}
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
    return {"plans": plans, "bonus": bonus, "peak": peak, "peak_hours_utc": hours,
            "peak_weekdays": days, "window_shares": window_shares}


PARSERS: dict[str, Callable] = {"config": lambda r: parse_config(r.json()), "docs": lambda r: parse_docs(r.text)}


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
        self.last_outcome: dict[str, str] = {}
        self.last_attempt: dict[str, float] = {}
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

    def _headers(self, source: str) -> dict[str, str] | None:
        h = {"user-agent": USER_AGENT}
        if source == "config":
            if not self.api_key:
                return None
            # Cloudflare answers 1010 to a request without a client identity; the vendor routes by session.
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
        headers = self._headers(source)
        if headers is None:
            log.error("catalog: %s fetch skipped — no OPENCODE_GO_API_KEY", source)
            return "fetch-failed"
        try:
            r = await self.client.get(self.urls[source], headers=headers, timeout=FETCH_TIMEOUT_S)
        except httpx.HTTPError as e:
            log.warning("catalog: %s fetch failed (%s) — keeping the last good snapshot", source, type(e).__name__)
            return "fetch-failed"
        if r.status_code != 200:
            log.warning("catalog: %s fetch answered %d — keeping the last good snapshot", source, r.status_code)
            return "fetch-failed"
        try:
            body = PARSERS[source](r)
        except Exception as e:  # noqa: BLE001 — ANY drift from the known shape is a parse failure, never a guess
            log.error("catalog: %s parse failed (%s: %s) — keeping the last good snapshot", source, type(e).__name__, e)
            return "parse-failed"
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

    async def run(self) -> None:
        """The schedule: one refresh of both sources at start, then every `refresh_s`."""
        while True:
            try:
                await self.refresh()
            except Exception:  # noqa: BLE001 — the loop must outlive any one bad refresh
                log.exception("catalog: refresh raised — retrying on the next tick")
            await asyncio.sleep(self.refresh_s)

    # -- reads ----------------------------------------------------------------------------------
    def go_model(self, model: str) -> GoModel | str:
        """Admission's read for a WIRE model id: its facts, or why it is not in the catalog (the
        `not-in-catalog` defer's detail — ruling 4: never a fallback price)."""
        cfg, docs = self.snapshots.get("config"), self.snapshots.get("docs")
        if cfg is None:
            return "no console catalog snapshot yet"
        row = cfg.body["models"].get(model)
        if row is None:
            return "not listed by the console catalog"
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
        """When a `not-in-catalog` verdict may change: the next scheduled refresh, else `fallback_s`."""
        last = max(self.last_attempt.values(), default=None)
        if last is not None and self.refresh_s > 0:
            return max(last + self.refresh_s, now + 1)
        return now + fallback_s

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

    def view(self) -> dict:
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
                "monthly_limit_usd": lim,
                "windows_usd": ({w: round(lim * s, 6) for w, s in shares.items()} if isinstance(lim, float) else None),
            }
        return {
            "plan": self.plan,
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
        return out

