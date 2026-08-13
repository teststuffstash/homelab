#!/usr/bin/env python3
"""gometer — shared Go-rail usage metering for the homelab OpenCode Go subscription.

This module is the SINGLE HOME for Go-rail pricing and usage extraction logic, consumed by BOTH
the openrouter-proxy pod (cluster-side metering) and the jail shim (scripts/claude-model-shim.py).

Matrix snapshot date: 2026-08-13 (docs/spikes/opencode-model-matrix.md). Curated from console
billing — there is no pricing API on this rail. Edits here are the only place prices change.
"""
import re

# GO_PRICES: OpenCode Go model pricing matrix (snapshot: docs/spikes/opencode-model-matrix.md 2026-08-13).
# Keys are bare model ids (prefix/suffix stripped); values: $/M tokens for in/out/cR/cW + half flag.
# "half=True" = (2x usage) badge models — they draw subscription windows at HALF list price
# (community-confirmed: "double the api worth" / "50 percent discounted").
# Prices curated from console billing (2026-08-13); no pricing API exists on this rail.
GO_PRICES = {
    # model              in       out      cR       cW       half
    "qwen3.5-plus":    (0.25,   1.00,   0.025,   None,  False),  # console-derived (2026-08-13)
    "kimi-k3":         (3.00,  15.00,   0.30,    None,  False),  # $15 pool
    "qwen3.8-max":     (2.00,   6.00,   0.25,    2.50,  False),  # $15 pool
    "glm-5.2":         (1.40,   4.40,   0.26,    None,  False),  # $60 pool
    "glm-5.1":         (1.40,   4.40,   0.26,    None,  False),  # $60 pool
    "deepseek-v4-flash": (0.14, 0.28,  0.0028,  None,  True),   # $60 pool, 2x badge
    "deepseek-v4-pro": (0.435,  0.87,  0.003625, None,  False),  # $15 pool
    "mimo-v2.5":       (0.14,   0.28,   0.0028,  None,  False),  # $60 pool
    "mimo-v2.5-pro":   (0.435,  0.87,  0.003625, None,  False),  # $15 pool
    "kimi-k2.7-code":  (0.95,   4.00,   0.19,    None,  False),  # $60 pool
    "kimi-k2.6":       (0.95,   4.00,   0.16,    None,  False),  # $60 pool
    "minimax-m3":      (0.30,   1.20,   0.06,    None,  False),  # $60 pool
    "minimax-m2.7":    (0.30,   1.20,   0.06,    0.375, False),  # $60 pool
    "qwen3.7-max":     (2.50,   7.50,   0.50,    3.125, False),  # $60 pool
    "qwen3.7-plus":    (0.40,   1.60,   0.04,    0.50,  False),  # <=256k; >256k = 1.20/4.80/0.12/1.50
    "qwen3.6-plus":    (0.50,   3.00,   0.05,    0.625, False),  # <=256k; >256k = 2.00/6.00/0.20/2.50
    "gpt-5.6-luna":    (0.20,   1.20,   0.02,    0.25,  True),   # <=272k; 2x badge
    "grok-4.5":        (2.00,   6.00,   0.30,    None,  False),  # $15 pool
    "hy3":             (0.14,   0.58,   0.035,   None,  False),  # $60 pool
}
# Fallback: use the most expensive known row when a model is unseen (fail conservative).
_GO_MAX_PRICE = max((p[0] + p[1] for p in GO_PRICES.values()), default=10.0)
_GO_PRICED_MODELS = frozenset(GO_PRICES.keys())
# Long-context price tiers (matrix #long-context; trigger = input_tokens threshold per pricing pages).
# qwen3.7-plus >256k: 1.20/4.80/0.12/1.50, qwen3.6-plus >256k: 2.00/6.00/0.20/2.50,
# gpt-5.6-luna >272k: 0.40/1.80/0.04/0.50. Half flag inherited from base row.
GO_PRICES_LONG = {
    "qwen3.7-plus": (256000, (1.20, 4.80, 0.12, 1.50)),
    "qwen3.6-plus": (256000, (2.00, 6.00, 0.20, 2.50)),
    "gpt-5.6-luna": (272000, (0.40, 1.80, 0.04, 0.50)),
}

# Usage extraction regex — matches both SSE (message_start/message_delta) and non-stream JSON.
# The pattern finds "usage": {...} blocks; the caller max-merges overlapping matches.
_USAGE_RE = re.compile(r'"usage"\s*:\s*(\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\})')


def extract_usage(head: bytes, tail: bytes) -> dict:
    """Extract token usage from a Go-leg response.

    Args:
        head: First 16KB of the response (for JSON with usage at start).
        tail: Last 16KB of the response (for JSON with usage at end).

    Returns:
        A dict with keys: input_tokens, output_tokens, cache_read_input_tokens,
        cache_creation_input_tokens — all integers (0 if not found).
    """
    merged = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_read_input_tokens": 0,
        "cache_creation_input_tokens": 0,
    }
    text = (head + tail).decode("utf-8", errors="replace")
    for m in _USAGE_RE.finditer(text):
        try:
            u = __import__("json").loads(m.group(1))
            for k in ("input_tokens", "output_tokens", "cache_read_input_tokens",
                      "cache_creation_input_tokens"):
                if k in u:
                    merged[k] = max(merged.get(k, 0), u[k])
        except (__import__("json").JSONDecodeError, KeyError):
            pass
    return merged


def price(bare_model: str, merged: dict) -> tuple[float, str | None]:
    """Compute the USD cost for a Go-leg completion.

    Args:
        bare_model: The model id without prefix/suffix (e.g. "deepseek-v4-flash").
        merged: Usage dict from extract_usage() with token counts.

    Returns:
        A tuple (usd, warning_or_None). warning is set when an unknown model triggers
        the fallback pricing (caller should log it); None for known models.
    """
    in_tokens = merged.get("input_tokens", 0)
    out_tokens = merged.get("output_tokens", 0)
    cr_tokens = merged.get("cache_read_input_tokens", 0)
    cw_tokens = merged.get("cache_creation_input_tokens", 0)

    price_row = GO_PRICES.get(bare_model)
    warning = None
    if price_row is None:
        # Unknown model: use most expensive known row + warn (fail conservative)
        warning = f"Go model {bare_model} not in GO_PRICES — using fallback ${_GO_MAX_PRICE}/M"
        price_row = (_GO_MAX_PRICE / 2, _GO_MAX_PRICE / 2, 0, 0, False)

    in_p, out_p, cr_p, cw_p, half = price_row

    # Long-context tier override: input_tokens > threshold -> use long-context rates
    if bare_model in GO_PRICES_LONG:
        threshold, long_rates = GO_PRICES_LONG[bare_model]
        if in_tokens > threshold:
            in_p, out_p, cr_p, cw_p = long_rates
            # half flag inherited from base row (unchanged)

    # Compute USD: tokens * ($/M) then apply badge halving if applicable
    usd = (
        in_tokens * in_p / 1e6 +
        out_tokens * out_p / 1e6 +
        (cr_tokens * cr_p / 1e6 if cr_p else 0.0) +
        (cw_tokens * cw_p / 1e6 if cw_p else 0.0)
    )
    if half:
        usd *= 0.5

    return (usd, warning)
