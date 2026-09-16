#!/usr/bin/env python3
"""Pre-flight budget estimator for agent sessions — size the per-session cap BEFORE dispatch.

The cost autopsy (agents/README.md) showed a single qwen3-coder run ate the whole weekly project
budget ($5.79): OpenRouter default-routed to a pricey provider (AtlasCloud) at 0% prompt caching and
the agent *looped* (187 requests), each re-sending ~27K of context. The fix is a per-session HARD
cap (an ephemeral OpenRouterKey, see ../../openrouter-operator) sized by a quick estimate.

This module is that estimator. It is deliberately a coarse SIZING tool, not a predictor: the cap is
the circuit breaker (OpenRouter 403s past it), so the estimate only needs to land in the right TIER.
Worst-case assumptions (0% cache by default) are intentional — over-sizing slightly beats throttling
a legit fix.

    cost ≈ rounds × requests/round × context_tokens × eff_$/M_input × (1 − cache_hit) / 1e6

Pricing (FU-062, docs/agents/model-routing.md §M3): a LIVE registry of OpenRouter's /models +
/models/<id>/endpoints, cached 24h in one JSON file, prices any model by its cache-aware effective
input $/M — min over cache-supporting providers ≥95% uptime of (1−h)·prompt + h·cache_read.
Lookup order: --price-per-mtok override > registry > the static offline table > $1.0/M default —
and every table is tried for the id AS GIVEN first, then for its base id (a provider-routing suffix
stripped: `:exacto` pins provider routing, never price; see `base_id`).

Pure core (`estimate_cost`, `requests_per_round`, `pick_tier`, and the registry math on a plain
dict) has no I/O and is covered by `--self-test`. The CLI wraps it and can emit a ready ephemeral
OpenRouterKey CR.

Usage:
    python3 agents/estimate_budget.py --issue-file issue.md --model qwen/qwen3-coder
    python3 agents/estimate_budget.py --model tencent/hy3 --lookup   # registry price + provider pin
    gh issue view 42 --json title,body -q '.title+"\\n"+.body' \\
        | python3 agents/estimate_budget.py --model openrouter/deepseek/deepseek-v4-flash \\
              --project sleep-tracking --session issue-42-round-1 --emit-cr
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model_id  # noqa: E402 — the ONE model-id parser (FU-127), a sibling module

# ── Tunable assumptions (documented so the numbers aren't magic) ─────────────────────────────────
CHARS_PER_TOKEN = 4  # rough English/code average; we only need order-of-magnitude
DEFAULT_CONTEXT_TOKENS = 20_000  # context re-sent each request (autopsy saw ~27K); the cache lever
DEFAULT_ROUNDS = 3  # max review rounds before escalating to a human (workflow.md hazard)
DEFAULT_CACHE_HIT = 0.0  # size for the WORST case (no caching) — the cap is a safety bound
# Headroom over the point estimate before choosing a tier. Raised 1.5 → 2.0 (retro r3 F5,
# docs/agents/retros/2026-08-11-oracle-r3-context.md): the headroom lands on the ESTIMATE while the
# CAP is the circuit breaker, so a run near a tier edge got a cap barely above its true spend —
# oracle-fleet#1 attempt 3 estimated $0.3024, ×1.5 = $0.4536 → tier sm ($0.50), then died at $0.5086
# on `403 Key limit exceeded` after 65 min with zero artifact. At 2.0 it lands in md ($1.00) and
# finishes. Consistent with this module's stated intent above: over-sizing beats throttling a legit
# fix, and an unspent cap costs $0.
BUFFER = 2.0

# Requests per round, banded by issue size. Grounded loosely in the autopsy: owl solved an issue in
# 72 requests; the looping qwen run hit 187. A bigger issue = more tool turns = more requests.
_REQ_TINY = 50  # < 500 tok  — a one-liner / config tweak
_REQ_SMALL = 90  # < 2000 tok — a normal bug fix
_REQ_LARGE = 160  # ≥ 2000 tok — a multi-file change

# ── Live model registry (FU-062, docs/agents/model-routing.md §M3) ───────────────────────────────
OPENROUTER_API = "https://openrouter.ai/api/v1"
REGISTRY_TTL_HOURS = 24.0
# Skip providers having a bad half hour — the autopsy's Google-Vertex-at-37%-uptime trap.
REGISTRY_UPTIME_FLOOR = 95.0
# Default h for the effective-price blend (the autopsy's measured cache-hit rate). Overridable via
# the existing --cache-hit param.
REGISTRY_CACHE_HIT = 0.8

# OFFLINE fallback price table — used only when the registry is unreachable AND no cache file
# exists (air-gapped runs, cold CI). Never delete it; the registry supersedes it at runtime.
# "Effective" = the price of a CACHING, sanely routed provider, NOT the model-page headline.
# A model failing mid-run costs one infra STRIKE (chain re-dispatch, docs/agents/model-routing.md),
# so free/new models are fair chain entries; the per-session cap is the guardrail. NB: still avoid
# *cloaked* models (the former owl-alpha) as PRIMARY — OpenRouter rotates them out and they 404
# mid-run. (The old "free ≈ 8 rpm" note here was a dated 2026-06-30 measurement — free-tier limits
# are account-dependent; measure, don't repeat it.)
_MODEL_PRICE: dict[str, float] = {
    "qwen/qwen3-coder:free": 0.0,
    "openrouter/qwen/qwen3-coder:free": 0.0,
    "qwen/qwen3-coder": 0.30,  # DeepInfra effective input (the cheap caching provider)
    "openrouter/qwen/qwen3-coder": 0.30,
    # The long-standing default: cheap + many cached providers @ 99%+ uptime (≈$0.09–0.10/M in,
    # ~$0.02/M cached) — but 2/4 harness-deaths on file-recreation (oracle #1); chain, don't pin.
    "deepseek/deepseek-v4-flash": 0.10,
    "openrouter/deepseek/deepseek-v4-flash": 0.10,
    # tencent/hy3: tool-capable, $0.14/M headline (2026-07-09); :free tier = $0.
    "tencent/hy3:free": 0.0,
    "openrouter/tencent/hy3:free": 0.0,
    "tencent/hy3": 0.14,
    "openrouter/tencent/hy3": 0.14,
}
_DEFAULT_PRICE = 1.0  # conservative fallback for an unknown paid model

# Budget tiers: name -> (selection ceiling, enforced cap), both USD. The smallest tier whose
# SELECTION ceiling ≥ estimate×buffer wins; the key is minted at the ENFORCED cap. An estimate
# above the top selection ceiling escalates (flagged) rather than silently minting a huge cap.
#
# Why two numbers (operator ruling 2026-09-14, retro r4 F5 / deepseek r4 F3): the cap is a
# guardrail, not a forecast — its job is to stop a $0.25 task running to $5 and to stop one bad
# child eating a Goal's whole `Budget:`; 2–3× over the estimate is fine when it is rare. The old
# single number was both the selector and the cap, so every estimator-picked ride sat at 72–105 %
# of its cap after the r3 headroom raise (two over cap, both at the `sm` ceiling; oracle-fleet#1
# died at $0.5086 on a $0.50 cap, oracle-fleet#355 at $0.7092). Doubling the ceilings ALONE would
# have shifted the tier picks too (a $0.20 estimate ×2.0 = $0.40 lands in `sm` today and would
# land in `xs` under a doubled ladder), and the selection ceilings are what keep ordinary work on
# the cheap tiers — a cheaper model with more turns is preferred over an `md`/`lg` pick. So the
# selection thresholds stay where they were and only the enforced cap doubles. Re-read after
# Goal #1640 (router) and the effort theme land; a token-denominated cap was considered and
# rejected as too complicated for a guardrail.
TIERS: list[tuple[str, float, float]] = [
    ("xs", 0.25, 0.50),
    ("sm", 0.50, 1.00),
    ("md", 1.00, 2.00),
    ("lg", 2.00, 4.00),
]


@dataclass(frozen=True)
class Estimate:
    estimate_usd: float
    tier: str
    cap_usd: float
    escalate: bool  # estimate exceeds the top tier — a human should look before spending this
    model: str
    price_per_mtok: float
    issue_tokens: int
    requests_per_round: int
    rounds: int
    cache_hit: float


def count_tokens(*, chars: int) -> int:
    """Coarse token count from a character length."""
    return max(0, chars) // CHARS_PER_TOKEN


def requests_per_round(issue_tokens: int) -> int:
    """Heuristic request count for one round, banded by issue size."""
    if issue_tokens < 500:
        return _REQ_TINY
    if issue_tokens < 2000:
        return _REQ_SMALL
    return _REQ_LARGE


def model_price(model: str, override: float | None) -> float:
    """Effective input $/M for a model (explicit override wins; unknown paid model → conservative).
    Static-table-only form kept for pure-core callers; the CLI resolves via `resolve_price`. Same
    miss-driven candidate order as that path: the id as given first, then its base id."""
    if override is not None:
        return override
    return next((_MODEL_PRICE[c] for c in lookup_ids(model) if c in _MODEL_PRICE), _DEFAULT_PRICE)


def estimate_cost(
    *,
    issue_tokens: int,
    rounds: int,
    price_per_mtok: float,
    context_tokens: int,
    cache_hit: float,
) -> float:
    """The cost model. Input-token dominated (the autopsy showed output is negligible); output is
    folded into BUFFER downstream."""
    reqs = requests_per_round(issue_tokens) * rounds
    billed_tokens = reqs * context_tokens * (1.0 - cache_hit)
    return billed_tokens * price_per_mtok / 1_000_000.0


def pick_tier(estimate_usd: float, *, label: str | None = None) -> tuple[str, float, bool]:
    """Choose (tier, cap, escalate). A `agent-budget/<tier>` label forces that tier; otherwise the
    smallest tier whose SELECTION ceiling ≥ estimate×buffer, minted at that tier's ENFORCED cap
    (2× the ceiling). Above the top ceiling → top cap + escalate=True."""
    if label:
        forced = label.rsplit("/", 1)[-1]
        for name, _select, cap in TIERS:
            if name == forced:
                return name, cap, False
        raise ValueError(f"unknown budget label tier: {label!r} (valid: {[n for n, _, _ in TIERS]})")

    needed = estimate_usd * BUFFER
    for name, select, cap in TIERS:
        if needed <= select:
            return name, cap, False
    top_name, _top_select, top_cap = TIERS[-1]
    return top_name, top_cap, True


def estimate(
    *,
    issue_tokens: int,
    model: str,
    price_override: float | None = None,
    rounds: int = DEFAULT_ROUNDS,
    context_tokens: int = DEFAULT_CONTEXT_TOKENS,
    cache_hit: float = DEFAULT_CACHE_HIT,
    label: str | None = None,
) -> Estimate:
    price = model_price(model, price_override)
    cost = estimate_cost(
        issue_tokens=issue_tokens,
        rounds=rounds,
        price_per_mtok=price,
        context_tokens=context_tokens,
        cache_hit=cache_hit,
    )
    tier, cap, escalate = pick_tier(cost, label=label)
    return Estimate(
        estimate_usd=round(cost, 4),
        tier=tier,
        cap_usd=cap,
        escalate=escalate,
        model=model,
        price_per_mtok=price,
        issue_tokens=issue_tokens,
        requests_per_round=requests_per_round(issue_tokens),
        rounds=rounds,
        cache_hit=cache_hit,
    )


# ── Registry: pure math over a plain dict (self-testable, no I/O) ────────────────────────────────
# Cache-file shape (one JSON file, prices normalized to $/M floats at fetch time):
#   { "fetched_at": "<iso>",
#     "models":    { "<id>": {prompt, input_cache_read|null, context_length, tools} },
#     "endpoints": { "<id>": {"fetched_at": "<iso>",
#                             "endpoints": [{provider, prompt, input_cache_read|null,
#                                            uptime|null, tools}]} } }


def normalize_model(model: str) -> str:
    """Registry ids are bare vendor/model. FU-127: the rule lives in model_id.py — this is the
    rail-namespace half of that parse (openrouter/vendor/model → vendor/model, while a cloaked
    openrouter/<codename> keeps its prefix because the id really lives there)."""
    return model_id.parse(model)["model"]


# ── Provider-routing suffixes (the PRICING-path half of FU-127; homelab#1670) ────────────────────
# OpenRouter overloads an id with routing shorthands — `:exacto` (tool-call-quality provider
# ordering), `:nitro` (throughput), `:floor` (price), `:online` (web plugin). They pin ROUTING,
# never PRICE, and the registry keys a model by its BARE id. So an id this platform's own router
# appends — `:exacto` from FU-186 `provider_policy` on the coding class, the PR#1639 flip — used to
# miss every lookup in this file, price at the conservative $1.0/M default, and print a PHANTOM
# `⚠ ESCALATE`: 31× the real price on the #1665 ride, which a coordinator following
# `agents/coordinator/README.md` step 3 ("stop, label agent/blocked") turns into every queued item
# on the stack parked for a human, with correct numbers and a wrong conclusion.
#
# The retry is MISS-DRIVEN, and that is the whole safety argument: the id AS GIVEN is tried first
# against the registry and the static table, and only an id NOTHING carries is retried as its base.
# `:free` is therefore never degraded to its paid sibling — it is a variant OpenRouter lists in its
# own right (`tencent/hy3:free`), priced as itself while any table still carries it — and a
# genuinely unknown model still reaches the $1.0/M default and can still escalate.
#
# ONE HOME for the pricing path: `base_id`/`lookup_ids` below are the single definition the
# registry read, the static table and `--lookup`'s report all go through, so those three can never
# disagree about what an id costs. The two BOOKKEEPING sites (the proxy's cooldown/breaker key, the
# router's `record_provider_event`) still strip `:exacto` inline, and the hoist that would give the
# rule ONE home platform-wide is the FU-127 parser (`agents/model_id.py`) — a governance path
# outside this issue's declared `Touches:` footprint, so it is sibling child homelab#1697, not this
# diff. These three functions move there verbatim.
def base_id(model: str) -> str | None:
    """`model` truncated at its last `:` — the id a lookup RETRIES when nothing carries `model`
    itself. Pricing-only: the suffix pins provider routing, so the FULL id stays the dispatch id
    (`Estimate.model`, the claim, the routed model)."""
    base, sep, _suffix = model.rpartition(":")
    return base if sep and base else None


def base_ids(model: str) -> list[str]:
    """Every id `model` reduces to by dropping ONE colon-suffix at a time, nearest first (#1693's
    doubled `:exacto` on a pre-suffixed chain entry reduces to the paid id, and `tencent/hy3:free`
    reduces to `tencent/hy3` only AFTER itself has been tried)."""
    out: list[str] = []
    rest = base_id(model)
    while rest and rest not in out:
        out.append(rest)
        rest = base_id(rest)
    return out


def lookup_ids(model: str) -> list[str]:
    """The ids a PRICE lookup tries for `model`, in order: the id as given, its rail-normalized
    form, then each one's successive base ids — best first, never degrading an id a table already
    carries."""
    out: list[str] = []
    for candidate in (model, normalize_model(model)):
        for one in (candidate, *base_ids(candidate)):
            if one and one not in out:
                out.append(one)
    return out


def routing_suffix(model: str, priced: str) -> str | None:
    """The routing suffix `priced` dropped from `model` (e.g. ':exacto'), or None when `priced` is
    not `model`'s base id — a rail prefix normalized away is NOT a routing suffix. Both sides are
    normalized, so `priced` may be a candidate carrying the rail prefix itself."""
    normalized, base = normalize_model(model), normalize_model(priced)
    return normalized[len(base):] if base and normalized.startswith(base + ":") else None


def registry_hit(registry: dict | None, model: str) -> str | None:
    """The lookup id `registry` actually CARRIES for `model`, or None when it carries none — the
    hit/miss signal `registry_key`'s fallback return cannot give (a miss and an absent registry
    both return the normalized id, so a caller deciding "did the registry price this?" needs
    this, not that)."""
    models = (registry or {}).get("models") or {}
    return next((c for c in lookup_ids(model) if c in models), None)


def registry_key(registry: dict | None, model: str) -> str:
    """The key `registry` carries for `model`, else the normalized id — for the dict lookups that
    want a key which simply misses. Use `registry_hit` when a MISS must be distinguishable."""
    return registry_hit(registry, model) or normalize_model(model)


def priced_as(model: str, registry: dict | None) -> str:
    """The id the price actually came from — the same fallback chain `resolve_price` walks, so the
    two cannot disagree: the registry hit, else the static-table candidate, else the normalized id
    (→ the $1.0/M default). Equals `normalize_model(model)` whenever no suffix had to be dropped.
    Reported by `--lookup`."""
    hit = registry_hit(registry, model)
    if hit is not None:
        return hit
    return next((c for c in lookup_ids(model) if c in _MODEL_PRICE), normalize_model(model))


def _blend(prompt: float, cache_read: float, h: float) -> float:
    """Effective input $/M when a fraction h of input tokens hit the provider's prompt cache."""
    return (1.0 - h) * prompt + h * cache_read


def effective_price(
    endpoints: list[dict],
    *,
    h: float = REGISTRY_CACHE_HIT,
    uptime_floor: float = REGISTRY_UPTIME_FLOOR,
) -> tuple[float, str] | None:
    """The M3 price rule → (effective $/M, note). Min over CACHE-SUPPORTING providers at ≥ the
    uptime floor of (1−h)·prompt + h·cache_read; no such provider → min headline prompt price,
    flagged. Deliberately NOT filtered on tools support — this prices tokens, `pinned_provider`
    picks who serves them."""
    up = [e for e in endpoints if (e.get("uptime") or 0.0) >= uptime_floor]
    cached = [e for e in up if e.get("input_cache_read") is not None]
    if cached:
        return min(_blend(e["prompt"], e["input_cache_read"], h) for e in cached), ""
    pool = up or endpoints
    if not pool:
        return None
    note = "(no caching provider)" if up else "(no caching provider; none ≥ uptime floor)"
    return min(e["prompt"] for e in pool), note


def market_row(market: dict | None, endpoint: dict) -> dict | None:
    """The endpoint's market effective-pricing row ({'in': $/M, 'hit': rate}), matched by slug
    then display name (ADR-096: rows are keyed by both, lowercased)."""
    if not market:
        return None
    return (market.get((endpoint.get("slug") or "").lower())
            or market.get((endpoint.get("provider") or "").lower()))


def pinned_provider(
    endpoints: list[dict],
    *,
    h: float = REGISTRY_CACHE_HIT,
    uptime_floor: float = REGISTRY_UPTIME_FLOOR,
    market: dict | None = None,
) -> dict | None:
    """The M4 session pin: the effective-cheapest provider to put first in `provider.order`.
    Unlike `effective_price`, tools support is REQUIRED here — the pin exists to serve a
    tool-driving worker, and per-endpoint tools support varies (GMICloud serves hy3 without it).
    Preference order: cached+tools ≥ floor → tools ≥ floor → any tools endpoint.
    Consumers put the entry's `slug` (not `provider`) into OpenRouter's provider.order.
    `market` (ADR-096, mirrors the proxy's compute_pin — keep in step): per-provider MARKET
    effective input prices (30d traffic-weighted, real cache hit baked in) override the h-blend
    of list prices wherever a provider has a row."""
    tooled = [e for e in endpoints if e.get("tools")]

    def eff(e: dict) -> float:
        row = market_row(market, e)
        if row and row.get("in", 0) > 0:
            return row["in"]
        if e.get("input_cache_read") is not None:
            return _blend(e["prompt"], e["input_cache_read"], h)
        return e["prompt"]

    for pool in (
        [e for e in tooled if e.get("input_cache_read") is not None and (e.get("uptime") or 0.0) >= uptime_floor],
        [e for e in tooled if (e.get("uptime") or 0.0) >= uptime_floor],
        tooled,
    ):
        if pool:
            best = min(pool, key=eff)
            return {**best, "effective_per_mtok": round(eff(best), 4),
                    "basis": "market" if market_row(market, best) else "list"}
    return None


def session_pin(
    endpoints: list[dict] | None,
    *,
    suffix: str | None,
    h: float = REGISTRY_CACHE_HIT,
    market: dict | None = None,
) -> dict | None:
    """`pinned_provider` as reported to a SESSION (agent-session.sh's opencode config): the pin
    itself, or None when `suffix` marks a provider-routing suffix on the id. Two reasons, one skip:
    the suffix pins routing upstream (`:exacto` = tool-call-quality ordering, FU-186), so a provider
    order derived from the BASE id's endpoints would fight it; and those endpoints are the base
    model's, i.e. a pin for an id we are not dispatching. The proxy applies the same skip
    (exacto_no_pin, openrouter-proxy.py); this is its estimator-side twin."""
    if suffix is not None:
        return None
    return pinned_provider(endpoints, h=h, market=market) if endpoints else None


def registry_model(registry: dict, model: str) -> dict | None:
    return (registry.get("models") or {}).get(registry_key(registry, model))


def registry_endpoints(registry: dict, model: str) -> list[dict] | None:
    entry = (registry.get("endpoints") or {}).get(registry_key(registry, model))
    return entry.get("endpoints") if entry else None


def registry_tools(registry: dict, model: str) -> bool | None:
    """Does the model advertise `tools` in supported_parameters? None = not in the registry."""
    entry = registry_model(registry, model)
    return None if entry is None else bool(entry.get("tools"))


def registry_price(registry: dict, model: str, *, h: float) -> tuple[float, str] | None:
    """Effective $/M from the registry: per-provider endpoints preferred; the /models aggregate
    pricing as the degraded fallback (endpoints fetch failed)."""
    endpoints = registry_endpoints(registry, model)
    if endpoints:
        return effective_price(endpoints, h=h)
    entry = registry_model(registry, model)
    if entry is None:
        return None
    if entry.get("input_cache_read") is not None:
        return (
            _blend(entry["prompt"], entry["input_cache_read"], h),
            "(model-level price; per-provider endpoints unavailable)",
        )
    return entry["prompt"], "(no caching provider)"


def _pricing_note(given: str, priced: str, note: str) -> str:
    """Append the routing-suffix disclosure whenever the price came from the base id: a stripped
    suffix must never be silent in the verdict line the coordinator reads. Silent otherwise — a
    rail prefix normalized away is the pre-existing, documented behaviour, not news."""
    suffix = routing_suffix(given, priced)
    if suffix is None:
        return note
    return f"{note} (priced as {priced} — {suffix!r} pins provider routing, not price)".strip()


def resolve_price(
    model: str, override: float | None, registry: dict | None, *, h: float
) -> tuple[float, str, str]:
    """(price $/M, source, note) — lookup order: explicit override > live registry > the static
    offline table > the $1.0/M conservative default ("unpriced", not "forbidden"). Every table is
    tried for the id AS GIVEN first, only then for its base id (`lookup_ids`), so a provider-routing
    suffix cannot manufacture an unpriced model — while an id no table carries still lands on the
    conservative default and can still escalate."""
    if override is not None:
        return override, "override", ""
    if registry:
        got = registry_price(registry, model, h=h)
        if got is not None:
            price, note = got
            return price, "registry", _pricing_note(model, registry_key(registry, model), note)
    for candidate in lookup_ids(model):
        if candidate in _MODEL_PRICE:
            return (
                _MODEL_PRICE[candidate],
                "static",
                _pricing_note(model, candidate, "(offline fallback table)"),
            )
    return _DEFAULT_PRICE, "default", "(unpriced model — conservative $1.0/M)"


# ── Registry: fetch + cache (the only networked code; every failure degrades, never raises) ──────
def default_registry_cache() -> str:
    """One JSON cache file alongside the script; /tmp when the script dir isn't writable (e.g. a
    read-only image layer)."""
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, ".openrouter-registry.json")
    if os.path.exists(path) or os.access(here, os.W_OK):
        return path
    return os.path.join(tempfile.gettempdir(), "openrouter-registry.json")


def _fetch_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": "homelab-estimate-budget"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)


def _price_mtok(pricing: dict, key: str) -> float | None:
    """OpenRouter prices are $/token strings → $/M floats (None = provider doesn't offer it)."""
    value = pricing.get(key)
    if value is None:
        return None
    try:
        return float(value) * 1e6
    except (TypeError, ValueError):
        return None


def _fresh(stamp: str | None) -> bool:
    if not stamp:
        return False
    try:
        fetched = datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)
    except ValueError:
        return False
    return datetime.now(UTC) - fetched < timedelta(hours=REGISTRY_TTL_HOURS)


def _save_registry(registry: dict, path: str) -> None:
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", suffix=".tmp")
        with os.fdopen(fd, "w") as fh:
            json.dump(registry, fh, separators=(",", ":"))
        os.replace(tmp, path)
    except OSError as e:
        print(f"registry: cache write failed ({e}) — pricing still works, uncached", file=sys.stderr)


def load_registry(path: str, *, refresh: bool = False) -> dict | None:
    """The cached /models catalog: fresh file → as-is; stale/absent → refetch (trimmed to the fields
    we use); network down → the stale file if any, else None (→ static-table fallback)."""
    registry: dict = {}
    if os.path.exists(path):
        try:
            with open(path, encoding="utf-8") as fh:
                registry = json.load(fh)
        except (OSError, ValueError):
            registry = {}
    if not refresh and registry.get("models") and _fresh(registry.get("fetched_at")):
        return registry

    try:
        data = _fetch_json(OPENROUTER_API + "/models")
        models = {}
        for m in data.get("data", []):
            pricing = m.get("pricing") or {}
            models[m["id"]] = {
                "prompt": _price_mtok(pricing, "prompt") or 0.0,
                "input_cache_read": _price_mtok(pricing, "input_cache_read"),
                "context_length": m.get("context_length"),
                "tools": "tools" in (m.get("supported_parameters") or []),
            }
        registry["models"] = models
        registry["fetched_at"] = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        # Prune endpoint entries for vanished models (cloaked rotations) so the file stays bounded.
        registry["endpoints"] = {
            k: v for k, v in (registry.get("endpoints") or {}).items() if k in models
        }
        _save_registry(registry, path)
        return registry
    except Exception as e:  # noqa: BLE001 — any fetch failure degrades identically
        if registry.get("models"):
            print(f"registry: refresh failed ({e}) — using the STALE cache at {path}", file=sys.stderr)
            return registry
        print(f"registry: unavailable ({e}) — falling back to the static offline table", file=sys.stderr)
        return None


def ensure_endpoints(registry: dict, model: str, path: str, *, refresh: bool = False) -> None:
    """Lazily fetch per-provider endpoints for ONE model into the same cache file (fetching all ~340
    models' endpoints per refresh would be 340 requests for data we never read)."""
    model_id = registry_key(registry, model)
    if model_id not in (registry.get("models") or {}):
        return  # not a registry model — nothing to fetch
    entry = registry.setdefault("endpoints", {}).get(model_id)
    if entry and not refresh and _fresh(entry.get("fetched_at")):
        return
    try:
        data = _fetch_json(f"{OPENROUTER_API}/models/{model_id}/endpoints")
        endpoints = []
        permaslug = None
        for e in (data.get("data") or {}).get("endpoints") or []:
            pricing = e.get("pricing") or {}
            if permaslug is None:  # "StreamLake | deepseek/deepseek-v4-flash-20260423" (ADR-096)
                m = re.search(r"\|\s*([a-z0-9-]+/[A-Za-z0-9._:-]+)\s*$", e.get("name") or "")
                permaslug = m.group(1) if m else None
            endpoints.append(
                {
                    "provider": e.get("provider_name") or e.get("name"),
                    # The ROUTING id: OpenRouter's provider.order matches the endpoint tag's base
                    # slug ("deepinfra/fp4" → "deepinfra"), NOT the display provider_name —
                    # measured 2026-07-09: order:["DeepInfra"] silently no-ops ("No endpoints
                    # found" with allow_fallbacks:false). Pin with slug, report with provider.
                    "slug": (e.get("tag") or "").split("/")[0] or None,
                    "prompt": _price_mtok(pricing, "prompt") or 0.0,
                    "input_cache_read": _price_mtok(pricing, "input_cache_read"),
                    "uptime": e.get("uptime_last_30m"),
                    "tools": "tools" in (e.get("supported_parameters") or []),
                }
            )
        registry["endpoints"][model_id] = {
            "fetched_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "permaslug": permaslug,
            "endpoints": endpoints,
        }
        _save_registry(registry, path)
    except Exception as e:  # noqa: BLE001
        print(
            f"registry: endpoints fetch failed for {model_id} ({e}) — using the model-level price",
            file=sys.stderr,
        )


def fetch_market(registry: dict, model: str) -> dict | None:
    """ADR-096 market effective pricing for `pinned_provider(market=)` — the model page's chart
    data (per-provider 30d traffic-weighted effective input price + REAL cache hit rate), keyed
    by lowercased providerSlug AND providerName. Live fetch at lookup time (never cached in the
    registry file: 30d averages don't belong in a 24h cache shape), fail-soft → None (list-blend
    basis). Twin of the proxy's market_for — keep in step."""
    entry = (registry.get("endpoints") or {}).get(registry_key(registry, model)) or {}
    permaslug = entry.get("permaslug")
    if not permaslug:
        return None
    try:
        data = _fetch_json(
            "https://openrouter.ai/api/frontend/v1/stats/effective-pricing?"
            + urllib.parse.urlencode({"permaslug": permaslug})
        ).get("data") or {}
        rows: dict = {}
        for s in data.get("providerSummaries") or []:
            row = {"in": float(s.get("effectiveInputPrice") or 0.0),
                   "hit": float(s.get("cacheHitRate") or 0.0)}
            for key in (s.get("providerSlug"), s.get("providerName")):
                if key:
                    rows[str(key).lower()] = row
        return rows or None
    except Exception as e:  # noqa: BLE001
        print(f"market: effective-pricing fetch failed for {permaslug} ({e}) — list-price basis",
              file=sys.stderr)
        return None


def session_secret_name(project: str, session: str) -> str:
    """The Secret the operator writes for an ephemeral session key. emit_cr sets this EXPLICITLY in
    the CR (rather than relying on the operator's derived default) so the dispatcher reads ONE
    authoritative name and never reconstructs it from the CR's metadata.name (which differs — that
    guess is what crash-loops the worker on a 'secret not found')."""
    return f"{project}-session-{session}-openrouter"


def emit_cr(est: Estimate, *, project: str, session: str, ttl_hours: float) -> str:
    """Render an ephemeral OpenRouterKey CR sized to the estimate (consumed by openrouter-operator).

    Retro r1 F6: the CR carries metadata.labels so the ledger (agents/ledger.py) can read the
    estimator's own pick_tier result and point estimate — calibration_error is now computed on
    every capped ride, not only agent-budget/*-override-labelled ones.
    """
    expires = (datetime.now(UTC) + timedelta(hours=ttl_hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    name = f"{project}-{session}".replace("_", "-").lower()
    return (
        "apiVersion: openrouter.teststuff.net/v1alpha1\n"
        "kind: OpenRouterKey\n"
        f"metadata: {{ name: {name}, namespace: {project}, "
        f"labels: {{ budget-tier: {est.tier}, budget-estimate-usd: \"{est.estimate_usd}\" }} }}\n"
        "spec:\n"
        f"  project: {project}\n"
        f"  budgetUSD: {est.cap_usd}            # tier {est.tier}; estimate ${est.estimate_usd}\n"
        "  ephemeral: true\n"
        f"  session: {session}\n"
        f"  secretName: {session_secret_name(project, session)}\n"
        f'  expiresAt: "{expires}"\n'
    )


# ── CLI ──────────────────────────────────────────────────────────────────────────────────────────
def _read_issue_chars(args: argparse.Namespace) -> int:
    if args.issue_chars is not None:
        return args.issue_chars
    if args.issue_file:
        with open(args.issue_file, encoding="utf-8") as fh:
            return len(fh.read())
    if not sys.stdin.isatty():
        return len(sys.stdin.read())
    return 0  # no issue text → tiny band; the cap still applies


def _run_cli(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="Pre-flight budget estimate for an agent session.")
    src = p.add_mutually_exclusive_group()
    src.add_argument("--issue-file", help="path to the issue text (else stdin)")
    src.add_argument("--issue-chars", type=int, help="issue length in characters (skip reading)")
    p.add_argument("--model", default="openrouter/deepseek/deepseek-v4-flash")
    p.add_argument("--price-per-mtok", type=float, help="effective input $/M (override the registry)")
    p.add_argument("--rounds", type=int, default=DEFAULT_ROUNDS)
    p.add_argument("--context-tokens", type=int, default=DEFAULT_CONTEXT_TOKENS)
    p.add_argument(
        "--cache-hit",
        type=float,
        default=None,
        help="0..1 — h for the registry effective-price blend (default 0.8); for an override/static"
        " price it is the cost-formula cache discount instead (default 0 = worst case)",
    )
    p.add_argument("--label", help="force a tier, e.g. agent-budget/sm")
    p.add_argument("--registry-cache", help=f"registry cache file (default {default_registry_cache()})")
    p.add_argument("--refresh", action="store_true", help="refetch the registry even if fresh")
    p.add_argument(
        "--lookup",
        action="store_true",
        help="print the model's registry verdict (effective price, tools, provider pin) and exit",
    )
    p.add_argument("--project", help="project/namespace (for --emit-cr)")
    p.add_argument("--session", help="unique session id (for --emit-cr)")
    # 4h covers a single worker run INCLUDING slow free models — 2h did not: laguna:free at
    # ~306s/turn outlasted its key on sleep-tracking#96 (2026-08-02, full ride lost at expiry;
    # #92's clean ride was ~100min, right at the old margin). budgetUSD is the hard spend bound;
    # expiresAt is cleanup, so the wider window costs little. It need not outlast the whole
    # multi-round session: the openrouter-operator self-heals — applying the CR before each
    # dispatch re-mints if the prior key died. So mint immediately before dispatch.
    p.add_argument("--ttl-hours", type=float, default=4.0, help="ephemeral key TTL (--emit-cr)")
    p.add_argument("--emit-cr", action="store_true", help="print the ephemeral OpenRouterKey CR")
    p.add_argument("--self-test", action="store_true", help="run the assertion suite and exit")
    args = p.parse_args(argv)

    if args.self_test:
        _self_test()
        print("estimate_budget self-test: OK")
        return 0

    # Resolve the price: override > registry > static > default. The registry is skipped entirely
    # under an explicit override (no network for a decided price).
    h = args.cache_hit if args.cache_hit is not None else REGISTRY_CACHE_HIT
    cache_path = args.registry_cache or default_registry_cache()
    registry = None
    if args.price_per_mtok is None or args.lookup:
        registry = load_registry(cache_path, refresh=args.refresh)
        if registry is not None:
            ensure_endpoints(registry, args.model, cache_path, refresh=args.refresh)
    price, source, note = resolve_price(args.model, args.price_per_mtok, registry, h=h)

    # Chain models must drive tools (model-routing.md §M2) — warn loudly, don't block (the estimator
    # sizes budgets; the dispatch decision is the coordinator's).
    if registry is not None:
        tools = registry_tools(registry, args.model)
        if tools is False:
            print(
                f"⚠ {normalize_model(args.model)} does NOT advertise `tools` support — "
                "it cannot drive a goose/opencode worker (model-routing.md §M2)",
                file=sys.stderr,
            )
        elif tools is None:
            print(
                f"⚠ {normalize_model(args.model)} is not in the OpenRouter registry "
                "(typo, or a rotated-out cloaked model?)",
                file=sys.stderr,
            )

    if args.lookup:
        priced = priced_as(args.model, registry)
        suffix = routing_suffix(args.model, priced)
        endpoints = registry_endpoints(registry, args.model) if registry else None
        market = fetch_market(registry, args.model) if registry and endpoints else None
        # The endpoints a suffixed id resolves to are the BASE model's — the same model on the same
        # providers (the suffix ORDERS them, it does not restrict them), so reporting them is honest.
        # What must not be reported is the pin the bare id would get: that would override the ordering
        # the suffix asked for (session_pin = the estimator-side twin of the proxy's exacto_no_pin).
        pin = session_pin(endpoints, suffix=suffix, h=h, market=market)
        print(
            json.dumps(
                {
                    "model": normalize_model(args.model),
                    "priced_as": priced,
                    "routing_suffix": suffix,
                    "price_per_mtok": round(price, 4),
                    "price_source": source,
                    "price_note": note,
                    "cache_hit": h,
                    "tools": registry_tools(registry, args.model) if registry else None,
                    "provider_count": len(endpoints) if endpoints else 0,
                    "market_providers": len({id(v) for v in market.values()}) if market else 0,
                    "pinned_provider": pin,
                },
                indent=2,
            )
        )
        return 0

    # A registry price is already cache-blended (or cache-less) — applying the cost formula's
    # (1−cache_hit) discount on top would count the cache twice. Override/static prices keep the
    # historical semantics: flat price, cache_hit discounts (default 0 = worst case).
    if source == "registry":
        cost_cache_hit = 0.0
    else:
        cost_cache_hit = args.cache_hit if args.cache_hit is not None else DEFAULT_CACHE_HIT

    chars = _read_issue_chars(args)
    est = estimate(
        issue_tokens=count_tokens(chars=chars),
        model=args.model,
        price_override=price,
        rounds=args.rounds,
        context_tokens=args.context_tokens,
        cache_hit=cost_cache_hit,
        label=args.label,
    )

    price_line = f"→ model priced at ${round(est.price_per_mtok, 4)}/M in (source: {source}{' ' + note if note else ''})"
    if source == "default":
        price_line += " — UNPRICED model; check the id or pass --price-per-mtok"

    if args.emit_cr:
        if not (args.project and args.session):
            p.error("--emit-cr requires --project and --session")
        sys.stdout.write(emit_cr(est, project=args.project, session=args.session, ttl_hours=args.ttl_hours))
        # The CR YAML goes to stdout (→ `kubectl apply -f -`). Print the verdict + AUTHORITATIVE secret
        # name + dispatch command to STDERR, so the caller sees them even when stdout is piped. Surface
        # `escalate` here too — otherwise an emit-cr caller applies the CR blind to the gate.
        secret = session_secret_name(args.project, args.session)
        verdict = (
            f"⚠ ESCALATE — estimate ${est.estimate_usd} exceeds the top tier (cap ${est.cap_usd}); "
            f"a HUMAN must approve before dispatch (a cheaper/priced model may fix this — the cap "
            f"can't cover the estimate, so the run may 403 unfinished)."
            if est.escalate
            else f"OK — tier {est.tier}, cap ${est.cap_usd}, estimate ${est.estimate_usd} (no escalation)."
        )
        print(
            f"\n→ {verdict}\n"
            f"{price_line}\n"
            f"→ session Secret (pass verbatim to --openrouter-secret): {secret}\n"
            f"→ dispatch:  bash agents/agent-session.sh {args.project} "
            f'--openrouter-secret {secret} --run "<recipe …>"',
            file=sys.stderr,
        )
        return 0

    print(json.dumps({**est.__dict__, "price_source": source, "price_note": note}, indent=2))
    print(price_line, file=sys.stderr)
    return 0


def _self_test() -> None:
    """Decision-table-style assertions over the pure core — runnable offline, no deps, no network."""
    # banding
    assert requests_per_round(100) == _REQ_TINY
    assert requests_per_round(1000) == _REQ_SMALL
    assert requests_per_round(5000) == _REQ_LARGE

    # a free model is always ~$0 → smallest tier, never escalates
    free = estimate(issue_tokens=3000, model="qwen/qwen3-coder:free")
    assert free.estimate_usd == 0.0 and free.tier == "xs" and not free.escalate

    # emit_cr sets an explicit, authoritative secretName (the -session- form) so the dispatcher never
    # reconstructs it from metadata.name (sleep-tracking-issue-7-round-1 → -openrouter = wrong key)
    assert session_secret_name("p", "issue-7-round-1") == "p-session-issue-7-round-1-openrouter"
    cr = emit_cr(free, project="p", session="issue-7-round-1", ttl_hours=2)
    assert "secretName: p-session-issue-7-round-1-openrouter" in cr and "ephemeral: true" in cr
    # Retro r1 F6: the CR carries budget-tier and budget-estimate-usd labels so the ledger can
    # read the estimator's own pick_tier result even without an agent-budget/* override label.
    assert "budget-tier: xs" in cr
    assert "budget-estimate-usd: \"0.0\"" in cr

    # the autopsy scenario: paid qwen, looping, no cache → a real (capped) cost
    paid = estimate(issue_tokens=1000, model="qwen/qwen3-coder", price_override=1.15)
    # 90 req × 3 rounds × 20k tok × $1.15/M = ~$6.21 → above top tier → escalate, capped at lg
    assert paid.estimate_usd > 2.0 and paid.escalate and paid.cap_usd == 4.00

    # caching crushes the bill: same run at 90% cache hit drops below a tier boundary
    cached = estimate(
        issue_tokens=1000, model="qwen/qwen3-coder", price_override=1.15, cache_hit=0.9
    )
    assert cached.estimate_usd < paid.estimate_usd and not cached.escalate

    # tier monotonicity: pricier/bigger never picks a smaller cap
    small = estimate(issue_tokens=100, model="x", price_override=0.05).cap_usd
    big = estimate(issue_tokens=5000, model="x", price_override=0.05).cap_usd
    assert big >= small

    # label override forces the tier regardless of estimate
    forced = estimate(issue_tokens=100, model="qwen/qwen3-coder:free", label="agent-budget/lg")
    assert forced.tier == "lg" and forced.cap_usd == 4.00

    # retro r4 F5's two over-cap ledger rows, replayed through pick_tier (2026-09-14). Selection
    # thresholds are UNCHANGED from the single-number ladder, so neither row moves tier; only the
    # rope doubles. oracle-fleet#1: estimate $0.3024 → ×2.0 = $0.6048 > sm's $0.50 ceiling → md,
    # enforced $2.00 ≥ the $0.5086 it died at (it sat in sm under the 1.5 headroom of its day).
    # The #355 shape: a $0.20 estimate → $0.40 → sm, enforced $1.00 ≥ the $0.7092 it died at on
    # the old $0.50 cap.
    assert pick_tier(0.3024) == ("md", 2.00, False)
    assert pick_tier(0.20) == ("sm", 1.00, False)
    assert pick_tier(0.10) == ("xs", 0.50, False)
    assert pick_tier(0.30, label="agent-budget/xs") == ("xs", 0.50, False)

    # unknown label tier is rejected
    try:
        pick_tier(0.1, label="agent-budget/huge")
    except ValueError:
        pass
    else:  # pragma: no cover
        raise AssertionError("expected ValueError for unknown label tier")

    # ── registry math, on a FIXTURE dict (the qwen3-coder measurement from model-routing.md §M3,
    #    plus the uptime trap + a tools-less endpoint) — pure, no network ────────────────────────
    fixture = {
        "fetched_at": "2099-01-01T00:00:00Z",
        "models": {
            "acme/coder": {"prompt": 0.22, "input_cache_read": None, "context_length": 262144, "tools": True},
            "acme/chatty": {"prompt": 0.50, "input_cache_read": None, "context_length": 8192, "tools": False},
            "qwen/qwen3-coder": {"prompt": 0.22, "input_cache_read": 0.05, "context_length": 262144, "tools": True},
            # #1670: the routing-suffix pair. The registry carries the BARE id; `:free` is a
            # VARIANT listed in its own right (a different price from its paid sibling).
            "deepseek/deepseek-v4.1-flash": {"prompt": 0.09, "input_cache_read": 0.018, "context_length": 163840, "tools": True},
            "tencent/hy3": {"prompt": 0.14, "input_cache_read": None, "context_length": 163840, "tools": True},
            "tencent/hy3:free": {"prompt": 0.0, "input_cache_read": None, "context_length": 163840, "tools": True},
        },
        "endpoints": {
            "acme/coder": {
                "fetched_at": "2099-01-01T00:00:00Z",
                "endpoints": [
                    # Venice: headline $0.35 but cache-read $0.035 → effective @ h=0.8 = $0.098 (wins)
                    {"provider": "Venice", "slug": "venice", "prompt": 0.35, "input_cache_read": 0.035, "uptime": 99.9, "tools": False},
                    # DeepInfra: effective 0.2·0.30 + 0.8·0.10 = $0.14
                    {"provider": "DeepInfra", "slug": "deepinfra", "prompt": 0.30, "input_cache_read": 0.10, "uptime": 99.0, "tools": True},
                    # Google: headline-cheapest but NO cache → excluded from the cached min
                    {"provider": "Google", "slug": "google-ai-studio", "prompt": 0.22, "input_cache_read": None, "uptime": 99.9, "tools": True},
                    # Vertex: cheapest of all but 37% uptime → the trap the floor exists for
                    {"provider": "Vertex", "slug": "vertex", "prompt": 0.05, "input_cache_read": 0.01, "uptime": 37.0, "tools": True},
                    # WandB: cache-read = full price (the 2026-07-09 measurement) → blend $1.00;
                    # only a MARKET row can ever make it win (the ADR-096 basis test).
                    {"provider": "WandB", "slug": "wandb", "prompt": 1.00, "input_cache_read": 1.00, "uptime": 99.0, "tools": True},
                ],
            },
            "acme/chatty": {
                "fetched_at": "2099-01-01T00:00:00Z",
                "endpoints": [
                    {"provider": "Solo", "slug": "solo", "prompt": 0.50, "input_cache_read": None, "uptime": 99.0, "tools": False},
                ],
            },
        },
    }

    # effective price: Venice's blend wins; Vertex excluded by uptime; Google excluded (no cache)
    price, note = effective_price(fixture["endpoints"]["acme/coder"]["endpoints"], h=0.8)
    assert abs(price - 0.098) < 1e-9 and note == ""

    # no cache-supporting provider → min headline, flagged
    price, note = effective_price(fixture["endpoints"]["acme/chatty"]["endpoints"], h=0.8)
    assert price == 0.50 and note == "(no caching provider)"

    # all providers under the uptime floor → still priced (min headline over all), flagged
    lowup = [{"provider": "X", "prompt": 0.30, "input_cache_read": 0.10, "uptime": 50.0, "tools": True}]
    price, note = effective_price(lowup, h=0.8)
    assert price == 0.30 and "uptime floor" in note
    assert effective_price([], h=0.8) is None

    # the session pin REQUIRES tools: Venice is effective-cheapest but tool-less → DeepInfra pins.
    # The pin carries the ROUTING slug (provider.order matches tags, not display names).
    pin = pinned_provider(fixture["endpoints"]["acme/coder"]["endpoints"], h=0.8)
    assert pin and pin["provider"] == "DeepInfra" and abs(pin["effective_per_mtok"] - 0.14) < 1e-9
    assert pin["slug"] == "deepinfra" and pin["basis"] == "list"
    assert pinned_provider(fixture["endpoints"]["acme/chatty"]["endpoints"], h=0.8) is None

    # ADR-096 market basis: a MARKET effective price overrides the list blend per provider —
    # WandB's measured $0.05 beats DeepInfra's $0.14 blend, flipping the pin; matched by slug
    # or display name (lowercased), and the pin reports basis=market.
    mkt = {"wandb": {"in": 0.05, "hit": 0.7}, "deepinfra": {"in": 0.30, "hit": 0.6}}
    pin = pinned_provider(fixture["endpoints"]["acme/coder"]["endpoints"], h=0.8, market=mkt)
    assert pin and pin["provider"] == "WandB" and pin["basis"] == "market"
    assert abs(pin["effective_per_mtok"] - 0.05) < 1e-9
    # a zero/absent market row falls back to the blend for that provider
    pin = pinned_provider(fixture["endpoints"]["acme/coder"]["endpoints"], h=0.8,
                          market={"wandb": {"in": 0.0, "hit": 0.0}})
    assert pin and pin["provider"] == "DeepInfra" and pin["basis"] == "list"

    # registry price via endpoints; model-level fallback when endpoints are missing
    price, note = registry_price(fixture, "acme/coder", h=0.8)
    assert abs(price - 0.098) < 1e-9
    price, note = registry_price(fixture, "qwen/qwen3-coder", h=0.8)
    assert abs(price - (0.2 * 0.22 + 0.8 * 0.05)) < 1e-9 and "model-level" in note

    # openrouter/ prefix normalization (vendor slug stripped; a cloaked openrouter/<name> kept)
    assert normalize_model("openrouter/acme/coder") == "acme/coder"
    assert normalize_model("openrouter/owl-alpha") == "openrouter/owl-alpha"
    assert registry_tools(fixture, "openrouter/acme/coder") is True
    assert registry_tools(fixture, "acme/chatty") is False
    assert registry_tools(fixture, "gone/model") is None

    # resolve order: override > registry > static > default
    assert resolve_price("acme/coder", 9.9, fixture, h=0.8)[0:2] == (9.9, "override")
    assert resolve_price("qwen/qwen3-coder", None, fixture, h=0.8)[1] == "registry"  # beats static
    assert resolve_price("qwen/qwen3-coder", None, None, h=0.8)[0:2] == (0.30, "static")
    assert resolve_price("gone/model", None, None, h=0.8)[0:2] == (_DEFAULT_PRICE, "default")
    assert resolve_price("gone/model", None, fixture, h=0.8)[1] == "default"  # in no table at all

    # ── homelab#1670: the provider-routing suffix is priced as the BASE id, never as an unknown
    #    model. The #1665 reproduction (31× over-price, `⚠ ESCALATE` on a $0.5-cap `xs` item): a
    #    suffixed id the registry does not carry must resolve through the registry, not the $1.0/M
    #    default — and the note must SAY so, or the coordinator reads a bare price line.
    suffix_price, _ = registry_price(fixture, "deepseek/deepseek-v4.1-flash:exacto", h=0.8)
    bare_price, _ = registry_price(fixture, "deepseek/deepseek-v4.1-flash", h=0.8)
    assert suffix_price == bare_price == _blend(0.09, 0.018, 0.8)  # $0.0324/M — the #1670 read
    assert registry_key(fixture, "deepseek/deepseek-v4.1-flash:exacto") == "deepseek/deepseek-v4.1-flash"
    assert priced_as("deepseek/deepseek-v4.1-flash:exacto", fixture) == "deepseek/deepseek-v4.1-flash"
    assert routing_suffix("deepseek/deepseek-v4.1-flash:exacto", "deepseek/deepseek-v4.1-flash") == ":exacto"
    # a rail prefix normalized away is NOT a routing suffix (no disclosure for it)
    assert routing_suffix("openrouter/acme/coder", "acme/coder") is None
    price, source, note = resolve_price("deepseek/deepseek-v4.1-flash:exacto", None, fixture, h=0.8)
    assert (price, source) == (suffix_price, "registry") and ":exacto" in note
    # the SAME issue text lands on the same tier with and without the suffix
    with_suffix = estimate(issue_tokens=1000, model="deepseek/deepseek-v4.1-flash:exacto",
                           price_override=price)
    without = estimate(issue_tokens=1000, model="deepseek/deepseek-v4.1-flash", price_override=price)
    assert (with_suffix.tier, with_suffix.cap_usd, with_suffix.escalate) == (
        without.tier, without.cap_usd, without.escalate) and not with_suffix.escalate

    # ...and the candidate order NEVER degrades a variant to its sibling: the miss-driven retry
    # tries the id as given FIRST, so `:free` is priced as `:free` (0.0) while a genuine routing
    # suffix on the same family falls back to the paid base id — both directions, one rule.
    assert registry_price(fixture, "tencent/hy3:free", h=0.8)[0] == 0.0
    assert registry_key(fixture, "tencent/hy3:free") == "tencent/hy3:free"
    assert registry_price(fixture, "tencent/hy3:exacto", h=0.8)[0] == 0.14
    assert registry_tools(fixture, "tencent/hy3:exacto") is True  # resolves, so no typo warning
    assert registry_key(fixture, "tencent/hy3:thinking") == "tencent/hy3"
    # the SESSION pin is suppressed under a routing suffix: the endpoints read are the BASE id's, so
    # their provider order would route a model we are not dispatching (FU-186's exacto skip, the
    # estimator-side twin of the proxy's exacto_no_pin) — agent-session.sh reads this field.
    _eps = fixture["endpoints"]["acme/coder"]["endpoints"]
    assert session_pin(_eps, suffix=None, h=0.8)["provider"] == "DeepInfra"
    assert session_pin(_eps, suffix=":exacto", h=0.8) is None
    assert session_pin(None, suffix=None, h=0.8) is None

    # the static offline table retries the base id too (registry unreachable: cold CI, air-gapped),
    # and its disclosure is the same one line; a genuinely unpriced id keeps the $1.0/M default.
    assert resolve_price("deepseek/deepseek-v4-flash:exacto", None, None, h=0.8)[0:2] == (0.10, "static")
    assert resolve_price("qwen/qwen3-coder:free", None, None, h=0.8)[0] == 0.0  # variant, not base
    # A NON-EMPTY registry that does not carry the model at all: the static table prices it, and
    # `priced_as`/`routing_suffix` must agree with the note `resolve_price` already discloses —
    # `registry_key`'s miss return is indistinguishable from its no-registry return, which is why
    # `registry_hit` exists. Without it `priced_as` reports the un-stripped id and `routing_suffix`
    # reports None, contradicting `price_note` in the same `--lookup` blob and silently disarming
    # `session_pin`'s suffix suppression.
    price, source, note = resolve_price("deepseek/deepseek-v4-flash:exacto", None, fixture, h=0.8)
    assert (price, source) == (0.10, "static") and ":exacto" in note
    assert priced_as("deepseek/deepseek-v4-flash:exacto", fixture) == "deepseek/deepseek-v4-flash"
    assert routing_suffix(
        "deepseek/deepseek-v4-flash:exacto",
        priced_as("deepseek/deepseek-v4-flash:exacto", fixture),
    ) == ":exacto"
    assert registry_hit(fixture, "deepseek/deepseek-v4-flash:exacto") is None
    assert registry_hit(fixture, "deepseek/deepseek-v4.1-flash:exacto") == "deepseek/deepseek-v4.1-flash"
    # a DOUBLED suffix (homelab#1693: the router re-appending `:exacto` to an already-suffixed chain
    # entry — the platform primary IS pre-suffixed) reduces all the way to the paid id, nearest
    # truncation first, so a doubling cannot re-open the phantom escalation either.
    assert resolve_price("deepseek/deepseek-v4-flash:exacto:exacto", None, None, h=0.8)[0:2] == (0.10, "static")
    assert registry_price(fixture, "tencent/hy3:free:exacto", h=0.8)[0] == 0.0  # variant survives
    assert registry_price(fixture, "tencent/hy3:exacto:exacto", h=0.8)[0] == 0.14
    price, source, note = resolve_price("gone/model:exacto", None, fixture, h=0.8)
    assert (price, source) == (_DEFAULT_PRICE, "default") and "unpriced" in note
    # ...and that default still ESCALATES: the conservative path is correct and stays reachable.
    unpriced = estimate(issue_tokens=3000, model="gone/model:exacto")
    assert unpriced.escalate and unpriced.cap_usd == 4.00


if __name__ == "__main__":
    raise SystemExit(_run_cli(sys.argv[1:]))
