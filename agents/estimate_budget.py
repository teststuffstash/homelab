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

Pure core (`estimate_cost`, `requests_per_round`, `pick_tier`) has no I/O and is covered by
`--self-test`. The CLI wraps it and can emit a ready ephemeral OpenRouterKey CR.

Usage:
    python3 agents/estimate_budget.py --issue-file issue.md --model qwen/qwen3-coder
    gh issue view 42 --json title,body -q '.title+"\\n"+.body' \\
        | python3 agents/estimate_budget.py --model openrouter/owl-alpha \\
              --project sleep-tracking --session issue-42-round-1 --emit-cr
"""

from __future__ import annotations

import argparse
import json
import sys
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

# Effective INPUT price ($/M tokens) for known models. "Effective" = the price of a CACHING, sanely
# routed provider, NOT the model-page headline (see the routing follow-up). Override with
# --price-per-mtok when routing/provider differs. Free cloaked/`:free` models are ~$0.
_MODEL_PRICE: dict[str, float] = {
    "openrouter/owl-alpha": 0.0,
    "qwen/qwen3-coder:free": 0.0,
    "openrouter/qwen/qwen3-coder:free": 0.0,
    "qwen/qwen3-coder": 0.30,  # DeepInfra effective input (the cheap caching provider)
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
    """Effective input $/M for a model (explicit override wins; unknown paid model → conservative)."""
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
    p.add_argument("--model", default="openrouter/owl-alpha")
    p.add_argument("--price-per-mtok", type=float, help="effective input $/M (override the table)")
    p.add_argument("--rounds", type=int, default=DEFAULT_ROUNDS)
    p.add_argument("--context-tokens", type=int, default=DEFAULT_CONTEXT_TOKENS)
    p.add_argument("--cache-hit", type=float, default=DEFAULT_CACHE_HIT, help="0..1 (default 0)")
    p.add_argument("--label", help="force a tier, e.g. agent-budget/sm")
    p.add_argument("--project", help="project/namespace (for --emit-cr)")
    p.add_argument("--session", help="unique session id (for --emit-cr)")
    p.add_argument("--ttl-hours", type=float, default=2.0, help="ephemeral key TTL (--emit-cr)")
    p.add_argument("--emit-cr", action="store_true", help="print the ephemeral OpenRouterKey CR")
    p.add_argument("--self-test", action="store_true", help="run the assertion suite and exit")
    args = p.parse_args(argv)

    if args.self_test:
        _self_test()
        print("estimate_budget self-test: OK")
        return 0

    chars = _read_issue_chars(args)
    est = estimate(
        issue_tokens=count_tokens(chars=chars),
        model=args.model,
        price_override=args.price_per_mtok,
        rounds=args.rounds,
        context_tokens=args.context_tokens,
        cache_hit=args.cache_hit,
        label=args.label,
    )

    if args.emit_cr:
        if not (args.project and args.session):
            p.error("--emit-cr requires --project and --session")
        sys.stdout.write(emit_cr(est, project=args.project, session=args.session, ttl_hours=args.ttl_hours))
        return 0

    print(json.dumps(est.__dict__, indent=2))
    return 0


def _self_test() -> None:
    """Decision-table-style assertions over the pure core — runnable offline, no deps."""
    # banding
    assert requests_per_round(100) == _REQ_TINY
    assert requests_per_round(1000) == _REQ_SMALL
    assert requests_per_round(5000) == _REQ_LARGE

    # a free model is always ~$0 → smallest tier, never escalates
    free = estimate(issue_tokens=3000, model="openrouter/owl-alpha")
    assert free.estimate_usd == 0.0 and free.tier == "xs" and not free.escalate

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
    forced = estimate(issue_tokens=100, model="openrouter/owl-alpha", label="agent-budget/lg")
    assert forced.tier == "lg" and forced.cap_usd == 2.00

    # unknown label tier is rejected
    try:
        pick_tier(0.1, label="agent-budget/huge")
    except ValueError:
        pass
    else:  # pragma: no cover
        raise AssertionError("expected ValueError for unknown label tier")


if __name__ == "__main__":
    raise SystemExit(_run_cli(sys.argv[1:]))
