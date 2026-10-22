"""The OpenRouter catalog leg (GW-CATALOG-OR, specs/endpoints/catalog.md; homelab#2742).

The openrouter rail's registry — the GW-CATALOG-GO shape on the other rail (operator rulings
2026-10-19): the candidate set is never a hand table; a provider ENTERS the order only after a
clean canary through our stack; the canary is on demand, part of this catalog's update, and
CAPPED by a budget.

- **Candidates** = the vendor's weekly ranking (the MCP `list-daily-model-rankings`, `period:
  week`, one call per policy slice — `programming` is a category, `tool_calling` a modality; the
  latest week's rows, top N by tokens; rows are DATED permaslugs, joined to ids by stripping the
  stamp) ∩ AA-benched (the MCP `list-benchmarks`, source artificial-analysis; a `:variant` id
  joins its family's row, as GW-MODEL-TIERS joins). Both calls ride the openrouter account key
  (`rails.openrouter.catalog.account_ref`, a labelled Secret) over the MCP's JSON-RPC — the old
  proxy's proven `_mcp_call` shape, UA included.
- **Per candidate**: `GET <openrouter>/v1/models/<id>/endpoints`, unauthenticated, parsed strictly
  by `providers.parse_endpoints`. A model whose endpoints cannot be read is absent from this
  refresh (counted); fewer than half the last good snapshot's models = implausible, nothing taken.
- **The snapshot** is the store's `catalog_snapshots.openrouter-endpoints` row — what
  GW-RAIL-OPENROUTER §Selection reads (`providers.EndpointSnapshot`) — plus a `provider_cells`
  table carrying each `(model, provider)` cell's entry state: `candidate` (new, or back from
  exclusion after the cooldown), `eligible` (one canary ride completed clean on exactly that
  cell), `excluded` (a canary struck — with the class and a cooldown). Selection pins only
  `eligible` cells; a model with none rides unpinned.
- **The view** (`GET /catalog/openrouter`) says, per endpoint row and per harness the policy's
  `providers.tool_choice` names, whether the cell is `pinnable` — the floors' verdict from
  `providers.eligible()`, THE one predicate selection uses — and `floor`, its reason where it is
  not (homelab#2775: the first canary window of 2026-10-20 admitted `open-inference` fp4 first —
  eligible after its clean ride, never pinnable, because the launcher walked candidates
  alphabetically with the floors unknown to it).
- **The canary** is a session (`POST /sessions` with `canary: {model, provider}`, the policy's
  canary role and harness, rail openrouter) pinned to that cell with no failover; its outcome is
  the verdict. Admission is capped: `canary.max_per_refresh` canaries between refreshes and
  `canary.usd_per_day` of metered spend (the gateway's own token accounting on canary sessions at
  the cell's endpoint price); over either → `canary-budget`, and `gateway_canary_budget_exhausted`
  says so while candidates wait.
"""

from __future__ import annotations

import asyncio
import logging
import re
from collections.abc import Callable
from dataclasses import dataclass

import httpx

from . import __version__
from .config import Policy
from .credentials import CredentialResolver, CredentialTransient, CredentialUnresolved
from .providers import SNAPSHOT_SOURCE, EndpointSnapshot, ParseError, eligible, parse_endpoints
from .store import Store, iso

log = logging.getLogger("gateway.orcatalog")

OUTCOMES = ("ok", "fetch-failed", "parse-failed", "implausible")
CELL_STATES = ("candidate", "eligible", "excluded")
CANARY_OUTCOMES = ("eligible", "excluded", "no-verdict")  # no-verdict: a 429'd canary (operator 2026-10-22)
CANARY_ADMISSIONS = ("dispatch", "budget", "not-due", "not-in-catalog")
# The ranking slices the policy may name → the MCP tool's arguments (period week on both).
SLICES: dict[str, dict] = {"programming": {"period": "week", "category": "programming"},
                           "tool_calling": {"period": "week", "modality": "tool_calling"}}
MCP_URL = "https://mcp.openrouter.ai/mcp"
USER_AGENT = f"agent-gateway/{__version__} (openrouter-catalog)"
FETCH_TIMEOUT_S = 30.0
MIN_KEPT_SHARE = 0.5  # ⚖ the Go catalog's plausibility rule, kept
DAY_S = 86400.0
_STAMP = re.compile(r"-\d{8}(?=:|$)")  # a dated permaslug → the model id (the old proxy's _CAP_ID_RE)
_VARIANT = re.compile(r":[a-z0-9-]+$")


class McpError(Exception):
    """The MCP answered, but not with a tool result this leg can read (a parse failure)."""


class McpUnavailable(Exception):
    """The MCP did not answer 200 (a fetch failure)."""


def permaslug_id(slug: str) -> str:
    return _STAMP.sub("", slug)


async def mcp_call(client: httpx.AsyncClient, url: str, key: str, tool: str, arguments: dict) -> dict:
    """One `tools/call` as JSON-RPC over HTTP (an `initialize` first — the server takes both in
    sequence without a session header; the old proxy's `_mcp_call`). Returns the tool's JSON."""
    headers = {"content-type": "application/json", "accept": "application/json, text/event-stream",
               "authorization": f"Bearer {key}", "user-agent": USER_AGENT}
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "agent-gateway", "version": __version__}}}
    r = await client.post(url, json=init, headers=headers, timeout=FETCH_TIMEOUT_S)
    if r.status_code != 200:
        raise McpUnavailable(f"initialize answered {r.status_code}")
    call = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": tool, "arguments": arguments}}
    r = await client.post(url, json=call, headers=headers, timeout=FETCH_TIMEOUT_S)
    if r.status_code != 200:
        raise McpUnavailable(f"tools/call {tool} answered {r.status_code}")
    try:
        reply = r.json()
        content = (reply.get("result") or {}).get("content") or []
        text = content[0].get("text") if content and isinstance(content[0], dict) else None
        import json

        doc = json.loads(text or "")
    except (ValueError, AttributeError, TypeError, IndexError) as e:
        raise McpError(f"tools/call {tool}: no JSON tool result ({type(e).__name__})") from e
    if not isinstance(doc, dict):
        raise McpError(f"tools/call {tool}: the tool result is not an object")
    return doc


def latest_week(rows: list, top_n: int) -> dict[str, int]:
    """`{model id: tokens}` of the newest `date` bucket, top_n by tokens (`other` dropped); the
    stamps of one model (two dated permaslugs → one id) are summed ⚖."""
    if not isinstance(rows, list):
        raise ParseError("rankings: `data` is not a list")
    dated = [r for r in rows if isinstance(r, dict) and r.get("model_permaslug") and r.get("date")]
    if not dated:
        raise ParseError("rankings: no dated rows")
    newest = max(str(r["date"]) for r in dated)
    week = [r for r in dated if str(r["date"]) == newest and r["model_permaslug"] != "other"]
    summed: dict[str, int] = {}
    for r in week:
        try:
            mid = permaslug_id(str(r["model_permaslug"]))
            summed[mid] = summed.get(mid, 0) + int(r.get("total_tokens") or 0)
        except (TypeError, ValueError) as e:
            raise ParseError(f"rankings: total_tokens of {r['model_permaslug']} is not an integer") from e
    return dict(sorted(summed.items(), key=lambda x: -x[1])[:top_n])


def benched(rows: list) -> dict[str, dict]:
    """`{model id: {intelligence, coding, agentic}}` from the AA benchmark rows."""
    if not isinstance(rows, list):
        raise ParseError("benchmarks: `data` is not a list")
    out: dict[str, dict] = {}
    for r in rows:
        if not isinstance(r, dict) or not r.get("model_permaslug"):
            raise ParseError("benchmarks: a row without model_permaslug")
        out[permaslug_id(str(r["model_permaslug"]))] = {"intelligence": r.get("intelligence_index"), "coding": r.get("coding_index"),
                                                       "agentic": r.get("agentic_index")}
    return out


@dataclass(frozen=True)
class CellVerdict:
    state: str
    klass: str | None
    cooldown_until: float | None
    retry_at: float | None = None  # a 429'd canary's re-try horizon (candidate cells only; None = none)
    backoff_s: float | None = None  # the step the horizon doubled to
    limit_source: str | None = None  # the 429 body's `error.metadata.limit_source`


class OpenRouterCatalog:
    """The leg: refresh (ranking ∩ benched → endpoints → the snapshot + the cells), the cell states
    the selection and the canary admission read, the budget meter, the view and the families."""

    def __init__(self, policy: Policy, store: Store, client: httpx.AsyncClient, resolver: CredentialResolver,
                 snapshot: EndpointSnapshot, upstream_base: str, mcp_url: str, clock, refresh_s: float):
        self.policy = policy
        self.store = store
        self.client = client
        self.resolver = resolver
        self.snapshot = snapshot
        self.upstream_base = upstream_base
        self.mcp_url = mcp_url
        self.clock = clock
        self.refresh_s = refresh_s
        rail = policy.rails.get("openrouter")
        self.catalog = rail.catalog if rail else None
        self.canary = rail.canary if rail else None
        self.refreshes: dict[str, int] = {o: 0 for o in OUTCOMES}
        self.last_outcome: str | None = None
        self.last_attempt: float | None = None
        # The stored snapshot a restart serves instead of refreshing (startup_delay): the schedule
        # counts from its fetched_at until this process attempts a refresh of its own.
        self.served_from: float | None = None
        self.last_refresh_at: float | None = store.meta_get("openrouter-catalog.refreshed_at")  # the per-refresh canary window's start
        self.endpoint_failures: int = 0  # candidates whose endpoints could not be read, last refresh
        self.canary_rides: dict[str, int] = {o: 0 for o in CANARY_OUTCOMES}
        self.canary_admissions: dict[str, int] = {o: 0 for o in CANARY_ADMISSIONS}
        self.sources: dict = (store.snapshot_load(SNAPSHOT_SOURCE) or (None, {}))[1].get("sources") or {}

    @property
    def enabled(self) -> bool:
        return self.catalog is not None

    # -- the refresh ----------------------------------------------------------------------------
    async def refresh(self) -> str:
        now = self.clock()
        self.last_attempt = now
        try:
            outcome = await self._refresh(now)
        except Exception:  # noqa: BLE001 — the last net: a refresh never takes the process down
            log.exception("orcatalog: refresh raised")
            outcome = "fetch-failed"
        self.refreshes[outcome] += 1
        self.last_outcome = outcome
        return outcome

    async def _refresh(self, now: float) -> str:
        cat = self.catalog
        if cat is None:
            return "fetch-failed"
        try:
            key = await self.resolver.resolve_ref(cat.account_ref, "OPENROUTER_API_KEY")
        except (CredentialUnresolved, CredentialTransient) as e:
            log.error("orcatalog: the account key %s does not resolve (%s) — keeping the last good snapshot", cat.account_ref, type(e).__name__)
            return "fetch-failed"
        ranked: dict[str, dict[str, int]] = {}
        try:
            for s in cat.ranking_slices:
                doc = await mcp_call(self.client, self.mcp_url, key, "list-daily-model-rankings", {"request": SLICES[s]})
                for mid, tokens in latest_week(doc.get("data"), cat.ranking_top_n).items():
                    ranked.setdefault(mid, {})[s] = tokens
            bench_doc = await mcp_call(self.client, self.mcp_url, key, "list-benchmarks", {"request": {"source": "artificial-analysis"}})
            aa = benched(bench_doc.get("data"))
        except (httpx.HTTPError, McpUnavailable) as e:
            log.warning("orcatalog: the MCP source failed (%s: %s) — keeping the last good snapshot", type(e).__name__, e)
            return "fetch-failed"
        except (ParseError, McpError) as e:
            log.error("orcatalog: the MCP answer parse failed (%s) — keeping the last good snapshot", e)
            return "parse-failed"
        candidates = {mid: ranked[mid] for mid in ranked if _VARIANT.sub("", mid) in aa}
        models: dict[str, dict] = {}
        failures = 0
        for mid, slices in sorted(candidates.items()):
            try:
                r = await self.client.get(f"{self.upstream_base}/v1/models/{mid}/endpoints",
                                          headers={"user-agent": USER_AGENT}, timeout=FETCH_TIMEOUT_S)
            except httpx.HTTPError as e:
                log.warning("orcatalog: endpoints of %s unreachable (%s) — absent from this refresh", mid, type(e).__name__)
                failures += 1
                continue
            if r.status_code != 200:
                log.warning("orcatalog: endpoints of %s answered %d — absent from this refresh", mid, r.status_code)
                failures += 1
                continue
            try:
                parsed = parse_endpoints(r.json())
            except (ParseError, ValueError) as e:
                log.error("orcatalog: endpoints of %s parse failed (%s) — absent from this refresh", mid, e)
                failures += 1
                continue
            models[mid] = {"endpoints": parsed["endpoints"], "fetched_at": iso(now), "ranking": slices,
                           "aa": aa[_VARIANT.sub("", mid)]}
        self.endpoint_failures = failures
        last = self.store.snapshot_load(SNAPSHOT_SOURCE)
        last_n = len(last[1].get("models") or {}) if last else 0
        if not models or (last_n and len(models) < MIN_KEPT_SHARE * last_n):
            log.error("orcatalog: implausible — %d models against the last good %d — keeping the last good snapshot", len(models), last_n)
            return "implausible"
        sources = {"ranking": {"slices": list(cat.ranking_slices), "top_n": cat.ranking_top_n, "ranked": len(ranked)},
                   "benchmarks": {"source": "artificial-analysis", "as_of": (bench_doc.get("meta") or {}).get("as_of"), "rows": len(aa)},
                   "candidates": len(candidates), "endpoint_failures": failures}
        self.store.snapshot_save(SNAPSHOT_SOURCE, now, {"models": models, "sources": sources})
        self.sources = sources
        self.snapshot.reload()
        entrants = self.store.cells_sync([(mid, e["slug"]) for mid, m in models.items() for e in m["endpoints"]], now)
        self.store.meta_set("openrouter-catalog.refreshed_at", now)
        self.last_refresh_at = now
        log.info("orcatalog: refreshed — %d ranked, %d benched, %d candidates, %d models with endpoints (%d unreadable), %d new candidate cells",
                 len(ranked), len(aa), len(candidates), len(models), failures, entrants)
        return "ok"

    def startup_delay(self, now: float) -> float:
        """Seconds the loop waits before its first refresh: 0 when there is no stored snapshot, no
        schedule, or the snapshot is `refresh_s` old — else the rest of the interval, so a pod roll
        inside it serves the stored snapshot and keeps the persisted `refreshed_at` (the canary
        window's start) where it was (#2775 gap 2: three windows in 70 min on 2026-10-20, none by
        the timer). The Go leg's `GoCatalog.startup_delay` is the same rule."""
        row = self.store.snapshot_load(SNAPSHOT_SOURCE)
        if row is None or self.refresh_s <= 0:
            return 0.0
        fetched_at = row[0]
        delay = fetched_at + self.refresh_s - now
        if delay <= 0:
            return 0.0
        self.served_from = fetched_at
        log.info("orcatalog: stored snapshot is %.0fs old — next refresh at %s", now - fetched_at, iso(fetched_at + self.refresh_s))
        return delay

    async def run(self) -> None:
        """The schedule: the first refresh after `startup_delay`, then every `refresh_s`."""
        delay = self.startup_delay(self.clock())
        if delay > 0:
            await asyncio.sleep(delay)
        while True:
            try:
                await self.refresh()
            except Exception:  # noqa: BLE001
                log.exception("orcatalog: refresh raised — retrying on the next tick")
            await asyncio.sleep(self.refresh_s)

    def retry_at(self, now: float, fallback_s: float) -> float:
        """The next scheduled refresh: `refresh_s` after this process's last attempt — or, before it
        attempts one, after the stored snapshot it serves (startup_delay) — else `fallback_s`."""
        anchor = self.last_attempt if self.last_attempt is not None else self.served_from
        if anchor is not None and self.refresh_s > 0:
            return max(anchor + self.refresh_s, now + 1)
        return now + fallback_s

    # -- the cells ------------------------------------------------------------------------------
    def cell(self, model: str, provider: str, now: float) -> CellVerdict:
        """The cell's entry state at `now`: an exclusion past its cooldown reads `candidate` again."""
        row = self.store.cell_get(model, provider)
        if row is None:
            return CellVerdict("candidate", None, None)
        if row["state"] == "excluded" and row["cooldown_until"] is not None and now >= row["cooldown_until"]:
            return CellVerdict("candidate", row["class"], None)
        return CellVerdict(row["state"], row["class"], row["cooldown_until"],
                           row.get("retry_at"), row.get("backoff_s"), row.get("limit_source"))

    def eligible_slugs(self, model: str, now: float) -> set[str]:
        return {p for p, r in self.store.cell_states(model).items() if r["state"] == "eligible"}

    def judge(self, model: str, provider: str, clean: bool, klass: str | None, now: float) -> None:
        """A canary session's outcome → the cell's state (GW-CATALOG-OR §The entry canary)."""
        if clean:
            self.store.cell_set(model, provider, "eligible", None, now, None)
            self.canary_rides["eligible"] += 1
            log.info("orcatalog: canary clean — (%s, %s) eligible", model, provider)
        else:
            cooldown = now + (self.canary.cooldown_s if self.canary else 0.0)
            self.store.cell_set(model, provider, "excluded", klass, now, cooldown)
            self.canary_rides["excluded"] += 1
            log.warning("orcatalog: canary struck %s — (%s, %s) excluded until %s", klass, model, provider, iso(cooldown))

    def throttle(self, model: str, provider: str, limit_source: str | None, now: float) -> float:
        """A 429 on a canary ride's pinned cell (GW-CATALOG-OR §The entry canary, operator ruling
        2026-10-22): NO verdict — the cell stays `candidate`, its re-try horizon is `canary.backoff_s`
        on the first 429'd canary and doubles per consecutive one up to `canary.backoff_max_s`; a
        verdict resets it (cell_set). Returns the horizon's end. The admission is not consumed
        (store.canary_sessions_since skips the session)."""
        can = self.canary
        base = can.backoff_s if can else 0.0
        cap = can.backoff_max_s if can else 0.0
        row = self.store.cell_get(model, provider)
        prev = row.get("backoff_s") if row else None
        step = base if not prev else min(prev * 2, cap)
        retry_at = now + step
        self.store.cell_throttle(model, provider, retry_at, step, limit_source, now)
        self.canary_rides["no-verdict"] += 1
        log.warning("orcatalog: canary 429 on (%s, %s) — no verdict (%s); candidate again at %s (backoff %.0f s)",
                    model, provider, limit_source or "limit_source unnamed", iso(retry_at), step)
        return retry_at

    # -- the budget -----------------------------------------------------------------------------
    def prices(self, model: str, provider: str) -> tuple[float, float] | None:
        for e in self.snapshot.endpoints(model) or ():
            if e.slug == provider and e.service_tier is None:
                return (e.in_price or 0.0, e.out_price or 0.0)
        for e in self.snapshot.endpoints(model) or ():
            if e.slug == provider:
                return (e.in_price or 0.0, e.out_price or 0.0)
        return None

    def spend_1d(self, now: float) -> float:
        """Metered canary spend over the trailing day: the gateway's own token accounting on canary
        sessions at the cell's endpoint price (cache reads at the input rate ⚖ — an upper bound)."""
        usd = 0.0
        for model, provider, tin, cr, _cw, tout in self.store.canary_usage_since(now - DAY_S):
            p = self.prices(model, provider)
            if p is None:
                continue
            usd += ((tin + cr) * p[0] + tout * p[1]) / 1e6
        return usd

    def budget(self, now: float) -> dict:
        can = self.canary
        if can is None:
            return {"max_per_refresh": None, "usd_per_day": None, "admitted_this_refresh": 0, "spend_usd_1d": 0.0, "exhausted": False,
                    "cooldown_s": None, "backoff_s": None, "backoff_max_s": None}
        since = self.last_refresh_at if self.last_refresh_at is not None else 0.0
        admitted = self.store.canary_sessions_since(since)
        spend = self.spend_1d(now)
        return {"max_per_refresh": can.max_per_refresh, "usd_per_day": can.usd_per_day, "admitted_this_refresh": admitted,
                "spend_usd_1d": round(spend, 6), "exhausted": admitted >= can.max_per_refresh or spend >= can.usd_per_day,
                "cooldown_s": can.cooldown_s, "backoff_s": can.backoff_s, "backoff_max_s": can.backoff_max_s}

    def budget_retry(self, now: float, fallback_s: float) -> float:
        """When asking again may help: the next refresh (the per-refresh cap) or the hour (the day roll) ⚖."""
        return min(self.retry_at(now, fallback_s), now + 3600.0)

    # -- reads ----------------------------------------------------------------------------------
    def floors(self, model: str) -> dict[str, tuple[dict[str, bool], dict[str, str]]]:
        """Per provider slug of `model`, (`pinnable`, `floor`): for every harness the policy's
        `providers.tool_choice` names, whether the provider's representative endpoint clears the
        floors (`providers.eligible()` — the data plane's own predicate, never a second one) and,
        where it does not, the reason. A provider's service tiers are one cell: they carry the
        representative's verdict. No providers policy = nothing is ever pinned: both maps empty."""
        rail = self.policy.rails.get("openrouter")
        pol = rail.providers if rail else None
        if pol is None:
            return {}
        eps = self.snapshot.endpoints(model) or []
        out: dict[str, tuple[dict[str, bool], dict[str, str]]] = {}
        for harness in pol.tool_choice:
            kept, dropped = eligible(eps, pol, harness)
            for e in kept:
                out.setdefault(e.slug, ({}, {}))[0][harness] = True
            for slug, why in dropped.items():
                pinnable, floor = out.setdefault(slug, ({}, {}))
                pinnable[harness] = False
                floor[harness] = why
        return out

    def view(self, order: Callable[[str], list[str]]) -> dict:
        """`GET /catalog/openrouter`: the snapshot with every cell's state and its floors verdict per
        harness (`pinnable` / `floor`), the selected provider per model (`order(model)[0]` — the
        eligible order the data plane would pin), the budget."""
        now = self.clock()
        row = self.store.snapshot_load(SNAPSHOT_SOURCE)
        fetched_at = row[0] if row else None
        body = row[1] if row else {}
        rail = self.policy.rails.get("openrouter")
        harnesses = tuple(rail.providers.tool_choice) if rail and rail.providers else ()
        models = {}
        for mid, m in sorted((body.get("models") or {}).items()):
            states = self.store.cell_states(mid)
            rides = self.store.cell_outcomes("openrouter", mid)  # GW-MODEL-TIERS: the cell's clean-ride evidence
            verdicts = self.floors(mid)
            eps = []
            for e in m["endpoints"]:
                v = self.cell(mid, e["slug"], now)
                clean, judged = rides.get(e["slug"], (0, 0))
                pinnable, floor = verdicts.get(e["slug"], ({h: False for h in harnesses}, {}))
                eps.append({**e, "state": v.state, "class": v.klass, "cooldown_until": iso(v.cooldown_until),
                            "retry_at": iso(v.retry_at), "backoff_s": v.backoff_s, "limit_source": v.limit_source,
                            "rides": {"clean": clean, "judged": judged},
                            "pinnable": {h: pinnable.get(h, False) for h in harnesses}, "floor": dict(floor)})
            ranked = order(mid)
            cells = {e["slug"]: e["state"] for e in eps}  # a provider's service tiers are ONE cell
            models[mid] = {"ranking": m.get("ranking") or {}, "aa": m.get("aa") or {}, "fetched_at": m.get("fetched_at"),
                           "endpoints": eps, "selected": ranked[0] if ranked else None, "order": ranked,
                           "cells": {s: sum(1 for st in cells.values() if st == s) for s in CELL_STATES}}
            del states
        counts = {s: 0 for s in CELL_STATES}
        for m in models.values():
            for s in CELL_STATES:
                counts[s] += m["cells"][s]
        return {
            "fetched_at": iso(fetched_at), "age_s": round(now - fetched_at, 3) if fetched_at else None,
            "models_count": len(models), "last_outcome": self.last_outcome, "last_attempt_at": iso(self.last_attempt),
            "refresh_s": self.refresh_s, "sources": self.sources, "endpoint_failures": self.endpoint_failures,
            "models": models, "cells": counts, "canary": self.budget(now),
        }

    def render(self) -> list[str]:
        now = self.clock()
        row = self.store.snapshot_load(SNAPSHOT_SOURCE)
        out = ["# HELP gateway_openrouter_catalog_age_seconds Seconds since the last good OpenRouter catalog refresh (absent: no snapshot yet).",
               "# TYPE gateway_openrouter_catalog_age_seconds gauge"]
        if row:
            out.append(f"gateway_openrouter_catalog_age_seconds {now - row[0]:.0f}")
        out += ["# HELP gateway_openrouter_catalog_models Models in the last good OpenRouter catalog snapshot (0: none yet).",
                "# TYPE gateway_openrouter_catalog_models gauge",
                f"gateway_openrouter_catalog_models {len(row[1].get('models') or {}) if row else 0}",
                "# HELP gateway_openrouter_catalog_refresh_total OpenRouter catalog refresh attempts by outcome.",
                "# TYPE gateway_openrouter_catalog_refresh_total counter"]
        out += [f'gateway_openrouter_catalog_refresh_total{{outcome="{o}"}} {self.refreshes[o]}' for o in OUTCOMES]
        out += ["# HELP gateway_openrouter_catalog_last_outcome 1 for the outcome of the latest OpenRouter catalog refresh attempt, 0 for the others.",
                "# TYPE gateway_openrouter_catalog_last_outcome gauge"]
        out += [f'gateway_openrouter_catalog_last_outcome{{outcome="{o}"}} {1 if self.last_outcome == o else 0}' for o in OUTCOMES]
        counts = self.store.cells_count(now)
        out += ["# HELP gateway_openrouter_cells (model, provider) cells of the OpenRouter catalog by entry state.",
                "# TYPE gateway_openrouter_cells gauge"]
        out += [f'gateway_openrouter_cells{{state="{s}"}} {counts.get(s, 0)}' for s in CELL_STATES]
        b = self.budget(now)
        out += ["# HELP gateway_canary_spend_usd Metered spend of canary sessions over the trailing day, at the cell's endpoint price.",
                "# TYPE gateway_canary_spend_usd gauge", f"gateway_canary_spend_usd {b['spend_usd_1d']:.6f}",
                "# HELP gateway_canary_budget_exhausted 1 while the canary budget (per refresh or per day) is spent and candidate cells wait.",
                "# TYPE gateway_canary_budget_exhausted gauge",
                f"gateway_canary_budget_exhausted {1 if b['exhausted'] and counts.get('candidate', 0) > 0 else 0}",
                "# HELP gateway_canary_rides_total Canary verdicts: the cell became eligible, or was excluded.",
                "# TYPE gateway_canary_rides_total counter"]
        out += [f'gateway_canary_rides_total{{outcome="{o}"}} {self.canary_rides[o]}' for o in CANARY_OUTCOMES]
        out += ["# HELP gateway_canary_admissions_total Canary admissions by answer.",
                "# TYPE gateway_canary_admissions_total counter"]
        out += [f'gateway_canary_admissions_total{{outcome="{o}"}} {self.canary_admissions[o]}' for o in CANARY_ADMISSIONS]
        return out
