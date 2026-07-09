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
Lookup order: --price-per-mtok override > registry > the static offline table > $1.0/M default.

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
import sys
import tempfile
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

# ── Tunable assumptions (documented so the numbers aren't magic) ─────────────────────────────────
CHARS_PER_TOKEN = 4  # rough English/code average; we only need order-of-magnitude
DEFAULT_CONTEXT_TOKENS = 20_000  # context re-sent each request (autopsy saw ~27K); the cache lever
DEFAULT_ROUNDS = 3  # max review rounds before escalating to a human (workflow.md hazard)
DEFAULT_CACHE_HIT = 0.0  # size for the WORST case (no caching) — the cap is a safety bound
BUFFER = 1.5  # headroom over the point estimate before choosing a tier

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

# Budget tiers: name -> hard cap (USD). The smallest tier whose cap ≥ estimate×buffer wins. An
# estimate above the top tier escalates (flagged) rather than silently minting a huge cap.
TIERS: list[tuple[str, float]] = [
    ("xs", 0.25),
    ("sm", 0.50),
    ("md", 1.00),
    ("lg", 2.00),
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
    Static-table-only form kept for pure-core callers; the CLI resolves via `resolve_price`."""
    if override is not None:
        return override
    return _MODEL_PRICE.get(model, _DEFAULT_PRICE)


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
    smallest tier whose cap ≥ estimate×buffer. Above the top tier → top cap + escalate=True."""
    if label:
        forced = label.rsplit("/", 1)[-1]
        for name, cap in TIERS:
            if name == forced:
                return name, cap, False
        raise ValueError(f"unknown budget label tier: {label!r} (valid: {[n for n, _ in TIERS]})")

    needed = estimate_usd * BUFFER
    for name, cap in TIERS:
        if needed <= cap:
            return name, cap, False
    top_name, top_cap = TIERS[-1]
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
    """Registry ids are bare vendor/model — drop the conventional openrouter/ prefix, but ONLY when
    a vendor/model slug remains: OpenRouter's own cloaked models genuinely live under openrouter/."""
    stripped = model.removeprefix("openrouter/")
    return stripped if "/" in stripped else model


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


def pinned_provider(
    endpoints: list[dict],
    *,
    h: float = REGISTRY_CACHE_HIT,
    uptime_floor: float = REGISTRY_UPTIME_FLOOR,
) -> dict | None:
    """The M4 session pin: the effective-cheapest provider to put first in `provider.order`.
    Unlike `effective_price`, tools support is REQUIRED here — the pin exists to serve a
    tool-driving worker, and per-endpoint tools support varies (GMICloud serves hy3 without it).
    Preference order: cached+tools ≥ floor → tools ≥ floor → any tools endpoint.
    Consumers put the entry's `slug` (not `provider`) into OpenRouter's provider.order."""
    tooled = [e for e in endpoints if e.get("tools")]

    def eff(e: dict) -> float:
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
            return {**best, "effective_per_mtok": round(eff(best), 4)}
    return None


def registry_model(registry: dict, model: str) -> dict | None:
    return (registry.get("models") or {}).get(normalize_model(model))


def registry_endpoints(registry: dict, model: str) -> list[dict] | None:
    entry = (registry.get("endpoints") or {}).get(normalize_model(model))
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


def resolve_price(
    model: str, override: float | None, registry: dict | None, *, h: float
) -> tuple[float, str, str]:
    """(price $/M, source, note) — lookup order: explicit override > live registry > the static
    offline table > the $1.0/M conservative default ("unpriced", not "forbidden")."""
    if override is not None:
        return override, "override", ""
    if registry:
        got = registry_price(registry, model, h=h)
        if got is not None:
            price, note = got
            return price, "registry", note
    if model in _MODEL_PRICE:
        return _MODEL_PRICE[model], "static", "(offline fallback table)"
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
    model_id = normalize_model(model)
    if model_id not in (registry.get("models") or {}):
        return  # not a registry model — nothing to fetch
    entry = registry.setdefault("endpoints", {}).get(model_id)
    if entry and not refresh and _fresh(entry.get("fetched_at")):
        return
    try:
        data = _fetch_json(f"{OPENROUTER_API}/models/{model_id}/endpoints")
        endpoints = []
        for e in (data.get("data") or {}).get("endpoints") or []:
            pricing = e.get("pricing") or {}
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
            "endpoints": endpoints,
        }
        _save_registry(registry, path)
    except Exception as e:  # noqa: BLE001
        print(
            f"registry: endpoints fetch failed for {model_id} ({e}) — using the model-level price",
            file=sys.stderr,
        )


def session_secret_name(project: str, session: str) -> str:
    """The Secret the operator writes for an ephemeral session key. emit_cr sets this EXPLICITLY in
    the CR (rather than relying on the operator's derived default) so the dispatcher reads ONE
    authoritative name and never reconstructs it from the CR's metadata.name (which differs — that
    guess is what crash-loops the worker on a 'secret not found')."""
    return f"{project}-session-{session}-openrouter"


def emit_cr(est: Estimate, *, project: str, session: str, ttl_hours: float) -> str:
    """Render an ephemeral OpenRouterKey CR sized to the estimate (consumed by openrouter-operator)."""
    expires = (datetime.now(UTC) + timedelta(hours=ttl_hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
    name = f"{project}-{session}".replace("_", "-").lower()
    return (
        "apiVersion: openrouter.teststuff.net/v1alpha1\n"
        "kind: OpenRouterKey\n"
        f"metadata: {{ name: {name}, namespace: {project} }}\n"
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
    # 2h comfortably covers a single worker run. It need not outlast the whole multi-round session:
    # the openrouter-operator self-heals — applying the CR before each dispatch re-mints if the prior
    # key died (it no longer NoOps on an expired/revoked key). So mint immediately before dispatch.
    p.add_argument("--ttl-hours", type=float, default=2.0, help="ephemeral key TTL (--emit-cr)")
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
        endpoints = registry_endpoints(registry, args.model) if registry else None
        pin = pinned_provider(endpoints, h=h) if endpoints else None
        print(
            json.dumps(
                {
                    "model": normalize_model(args.model),
                    "price_per_mtok": round(price, 4),
                    "price_source": source,
                    "price_note": note,
                    "cache_hit": h,
                    "tools": registry_tools(registry, args.model) if registry else None,
                    "provider_count": len(endpoints) if endpoints else 0,
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

    # the autopsy scenario: paid qwen, looping, no cache → a real (capped) cost
    paid = estimate(issue_tokens=1000, model="qwen/qwen3-coder", price_override=1.15)
    # 90 req × 3 rounds × 20k tok × $1.15/M = ~$6.21 → above top tier → escalate, capped at lg
    assert paid.estimate_usd > 2.0 and paid.escalate and paid.cap_usd == 2.00

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
    assert forced.tier == "lg" and forced.cap_usd == 2.00

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
    assert pin["slug"] == "deepinfra"
    assert pinned_provider(fixture["endpoints"]["acme/chatty"]["endpoints"], h=0.8) is None

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


if __name__ == "__main__":
    raise SystemExit(_run_cli(sys.argv[1:]))
