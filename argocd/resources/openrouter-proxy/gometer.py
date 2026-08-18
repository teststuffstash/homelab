#!/usr/bin/env python3
"""gometer — shared Go-rail usage metering for the homelab OpenCode Go subscription.

This module is the SINGLE HOME for Go-rail pricing, usage extraction, and the subscription
WINDOW semantics (budgets + epoch anchors), consumed by BOTH the openrouter-proxy pod
(cluster-side metering, /opencode-limit) and the jail shim (scripts/claude-model-shim.py).

Matrix snapshot date: 2026-08-13 (docs/spikes/opencode-model-matrix.md). Curated from console
billing — there is no pricing API on this rail. Edits here are the only place prices change.
"""
import calendar
import os
import re
import sys
import time

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


def _price_row(bare_model: str, in_tokens: int) -> tuple:
    """The (in_p, out_p, cr_p, cw_p, half, warning) row for a bare model at the given input
    size — the ONE place prices resolve, shared by the billed-style `price()` and the
    window-draw `window_draw()` so the two cannot drift. Unknown model → the most expensive
    known row (fail conservative) with a warning."""
    row = GO_PRICES.get(bare_model)
    warning = None
    if row is None:
        warning = f"Go model {bare_model} not in GO_PRICES — using fallback ${_GO_MAX_PRICE}/M"
        row = (_GO_MAX_PRICE / 2, _GO_MAX_PRICE / 2, 0, 0, False)
    in_p, out_p, cr_p, cw_p, half = row
    # Long-context tier override: input_tokens > threshold -> use long-context rates
    if bare_model in GO_PRICES_LONG:
        threshold, long_rates = GO_PRICES_LONG[bare_model]
        if in_tokens > threshold:
            in_p, out_p, cr_p, cw_p = long_rates
            # half flag inherited from base row (unchanged)
    return in_p, out_p, cr_p, cw_p, half, warning


def price(bare_model: str, merged: dict) -> tuple[float, str | None]:
    """Compute the BILLED-STYLE USD estimate for a Go-leg completion — the number the PROVIDER
    CONSOLE BILLS (homelab#540, 2026-08-18 console reconciliation): list price ×1 for every
    model, badge models included, with cache-read/cache-creation tokens at their discounted
    rates. This is the LEDGER/COST-REPORTING number, NOT the window draw.

    Contrast with `window_draw()`: the subscription window draws at LIST price on raw tokens
    and badge-halves EVERYTHING (draw = list on raw, badge-halved); the BILLED estimate here is
    list ×1 with cache discounts and NO badge halving. The two numbers differ by design and
    must not be conflated (the 2026-08-17 pricing defect fix split them; homelab#540 corrected
    the billed side to list ×1).

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
    in_p, out_p, cr_p, cw_p, _half, warning = _price_row(bare_model, in_tokens)

    # BILLED = list price ×1 for every token class at its own rate (cache reads/writes at their
    # discounted rates). NO badge halving here — the matrix's console-verified ruling is that
    # badge models BILL at full list ×1 (docs/spikes/opencode-model-matrix.md); the badge
    # halving is the WINDOW-DRAW (limit-side) effect only, applied in window_draw().
    usd = (
        in_tokens * in_p / 1e6 +
        out_tokens * out_p / 1e6 +
        (cr_tokens * cr_p / 1e6 if cr_p else 0.0) +
        (cw_tokens * cw_p / 1e6 if cw_p else 0.0)
    )

    return (usd, warning)


def window_draw(bare_model: str, merged: dict, cache_read: int | None = None,
                cache_creation: int | None = None) -> float:
    """The price OpenCode's subscription window DRAWS against for one completion: LIST price on
    RAW tokens, halved for badge models — the limit-side number the window utilization (the
    latch, /opencode-limit) MUST use. Reconciliation 2026-08-17 (uploads/opencode-go.txt): a 5h
    window of 50.56M in / 0.488M out of badged deepseek-v4-flash drew ≈ $3.6–3.7 at list, while
    the billed-style price() above (cache-read discounts) read ≈ $0.15 — a ~30× under-count.

    CACHE SPLIT (homelab#540): when `cache_read`/`cache_creation` are KNOWN (the Anthropic-compat
    surface carries them and extract_usage reads them), those tokens draw at their LIST cache
    rates, badge-halved like the rest — the old docstring claim that "the usage blocks on these
    surfaces carry no cache split" is FALSE for the Anthropic-compat surface. Tokens WITHOUT a
    split keep pricing as RAW INPUT (the conservative status quo for HISTORICAL rows, which
    predate the cache columns — recomputation only improves NEW rows)."""
    in_tokens = int(merged.get("input_tokens") or 0)
    out_tokens = int(merged.get("output_tokens") or 0)
    cr_tokens = int(cache_read if cache_read is not None else merged.get("cache_read_input_tokens") or 0)
    cw_tokens = int(cache_creation if cache_creation is not None else merged.get("cache_creation_input_tokens") or 0)
    in_p, out_p, cr_p, cw_p, half, _warning = _price_row(bare_model, in_tokens)
    # Raw input+output at LIST, plus cache-read/creation at their LIST rates when the split is
    # present. Note: rows WITHOUT the split price cache tokens as raw input — the conservative
    # status quo for historical rows.
    draw = (in_tokens * in_p + out_tokens * out_p) / 1e6
    draw += (cr_tokens * cr_p / 1e6 if cr_p else 0.0)
    draw += (cw_tokens * cw_p / 1e6 if cw_p else 0.0)
    if half:
        draw *= 0.5
    return draw


# ── Go subscription windows: budget + span + ANCHOR (homelab#422 / 2026-08-17 fix) ─────────────
# Each window is `rolling` (a pure trailing span) OR EPOCH-ANCHORED (the span floor is
# max(now - span, last_reset_epoch), so the sum counts spend since the LAST RESET — never a
# rolling total that lets LAST week's spend inflate THIS week's utilization).
#
# Defaults, MEASURED from the operator's console:
#   • 5h  is FIRST-USE/EXPIRY-CHAINED (`chain`, homelab#540, 2026-08-18). The provider console's
#         resets ran the x:01 lattice (first request of the day 06:01Z → observed reset 11:01Z),
#         while the 2026-08-17 `grid:217m` calibration predicted the x:37 lattice (18:37Z). The
#         old arithmetic was sound on the WRONG model: under CONTINUOUS use an expiry-chained
#         window degenerates to a span-lattice anchored at the day's first request —
#         indistinguishable from a fixed grid for one day. Real model: a new 5h window OPENS at
#         the first request after the previous window expires; reset = open + span; idle > span
#         ⇒ the next request opens a fresh window. The ledger walk over go_usage.ts recovers the
#         current open window (router.go_usage_chain_open; gometer's chain_fn seam). Degrade:
#         an unreadable ledger / no open window falls back to the 5h GRID default (offset 217m),
#         loudly logged — a failed probe is not a fact.
#   • 7d  "resets in 6d14h" (~10:00Z) and "resets in 6d11h" (~12:35Z) — boundary
#         2026-08-24T00:00Z — and 2026-08-24 is a MONDAY (2026-08-17 was Monday, the
#         operator's own dateline). → anchor `weekly` mon 00:00. (An earlier reading of the
#         same numbers mislabelled 08-24 a Sunday; the seat corrected it pre-push.)
#   • 30d "resets in 26d23h" (~12:35Z) — boundary ~2026-09-13T11:30Z: the monthly window is
#         billing-cycle anchored, day 13 ~11:30 UTC. → anchor `monthly` 13:11:30.
#
# GO_WINDOW_ANCHORS overrides any/all of the three, e.g.
#   GO_WINDOW_ANCHORS="5h=chain,7d=weekly:mon:00:00,30d=monthly:13:11:30"
# Grammar per window: `grid:<offset>` | `weekly:<mon..sun>[:HH[:MM]]` |
# `monthly:<1..31>[:HH[:MM]]` | `chain[:<lookback>]` | `rolling`. Parsing is DEFENSIVE: an
# unparseable or unknown spec falls back to that window's default with one loud log line — it
# never crashes the proxy. `rolling` stays a supported value and is the conservative fallback
# for an anchor nobody has measured yet.
_GO_WINDOW_ORDER = ("5h", "7d", "30d")
_WEEKDAYS = {"mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}


def _golog(msg: str) -> None:
    print(f"gometer: {msg}", file=sys.stderr, flush=True)


_GO_WINDOW_DEFAULTS = {
    "5h":  {"budget_usd": 12.0, "span_s": 5 * 3600, "anchor": "chain",
            "chain_lookback_s": 7 * 86400, "grid_offset_min": 217},
    "7d":  {"budget_usd": 30.0, "span_s": 7 * 86400,
            "anchor": "weekly", "weekday": "mon", "hour": 0, "minute": 0},
    "30d": {"budget_usd": 60.0, "span_s": 30 * 86400,
            "anchor": "monthly", "month_day": 13, "hour": 11, "minute": 30},
}

_MIN_RE = re.compile(r"^\s*(?:(\d+)h)?\s*(?:(\d+)m)?\s*$")


def _parse_minutes(val: str) -> int | None:
    """'217m' → 217, '3h37m' → 217, '5h' → 300; None when unparseable."""
    m = _MIN_RE.match(val.strip())
    if not m or (m.group(1) is None and m.group(2) is None):
        return None
    return int(m.group(1) or 0) * 60 + int(m.group(2) or 0)


def _parse_anchor_spec(spec_str: str) -> dict | None:
    """One GO_WINDOW_ANCHORS value → a spec-key override dict, or None when unparseable.
    Supported: 'rolling', 'grid:<offset>', 'chain[:<lookback>]',
    'weekly:<day>[:HH[:MM]]', 'monthly:<day>[:HH[:MM]]'."""
    s = spec_str.strip().lower()
    if s == "rolling":
        return {"anchor": "rolling"}
    if s.startswith("grid:"):
        minutes = _parse_minutes(s[len("grid:"):])
        return {"anchor": "grid", "grid_offset_min": minutes} if minutes is not None else None
    if s == "chain" or s.startswith("chain:"):
        lookback = s[len("chain:"):] if s.startswith("chain:") else ""
        if lookback:
            minutes = _parse_minutes(lookback)
            if minutes is None:
                return None
            return {"anchor": "chain", "chain_lookback_s": minutes * 60}
        return {"anchor": "chain"}
    if s.startswith("weekly:"):
        parts = s[len("weekly:"):].split(":")
        if parts[0] not in _WEEKDAYS or len(parts) > 3:
            return None
        try:
            hour = int(parts[1]) % 24 if len(parts) > 1 else 0
            minute = int(parts[2]) % 60 if len(parts) > 2 else 0
        except ValueError:
            return None
        return {"anchor": "weekly", "weekday": parts[0], "hour": hour, "minute": minute}
    if s.startswith("monthly:"):
        parts = s[len("monthly:"):].split(":")
        try:
            day = int(parts[0])
            if not 1 <= day <= 31 or len(parts) > 3:
                return None
            hour = int(parts[1]) % 24 if len(parts) > 1 else 0
            minute = int(parts[2]) % 60 if len(parts) > 2 else 0
        except ValueError:
            return None
        return {"anchor": "monthly", "month_day": day, "hour": hour, "minute": minute}
    return None


def apply_anchor_overrides(raw: str | None, defaults: dict | None = None) -> dict:
    """A {window: spec} copy of the defaults with GO_WINDOW_ANCHORS applied. DEFENSIVE: an
    unparseable spec, an unknown window, or a chunk without '=' logs one loud line and keeps
    that window's default. Never raises."""
    base = {w: dict(s) for w, s in (defaults or _GO_WINDOW_DEFAULTS).items()}
    if not raw:
        return base
    for chunk in raw.split(","):
        chunk = chunk.strip()
        if not chunk:
            continue
        if "=" not in chunk:
            _golog(f"GO_WINDOW_ANCHORS: {chunk!r} has no '=' — ignored")
            continue
        win, _, spec_str = chunk.partition("=")
        win, spec_str = win.strip(), spec_str.strip()
        if win not in base:
            _golog(f"GO_WINDOW_ANCHORS: unknown window {win!r} — ignored (known: {sorted(base)})")
            continue
        parsed = _parse_anchor_spec(spec_str)
        if parsed is None:
            _golog(f"GO_WINDOW_ANCHORS: unparseable spec {spec_str!r} for {win} — keeping "
                   f"default ({base[win].get('anchor')})")
            continue
        base[win].update(parsed)
    return base


# The EFFECTIVE window table (defaults + env overrides), computed once at import.
GO_WINDOWS = apply_anchor_overrides(os.environ.get("GO_WINDOW_ANCHORS"))

# Per-window utilization thresholds — the dispatch-deferral gate (0 disables a window). Same
# env grammar as the proxy's anthropic thresholds: OPENCODE_UTIL_THRESHOLD is the base, a
# per-window OPENCODE_UTIL_THRESHOLD_<W> overrides it.
GO_UTIL_THRESHOLD = float(os.environ.get("OPENCODE_UTIL_THRESHOLD", "0.80"))
GO_UTIL_THRESHOLDS = {w: float(os.environ.get(f"OPENCODE_UTIL_THRESHOLD_{w.upper()}",
                                             GO_UTIL_THRESHOLD)) for w in _GO_WINDOW_ORDER}


def _days_in_month(year: int, month: int) -> int:
    if month == 2:
        leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0
        return 29 if leap else 28
    return 30 if month in (4, 6, 9, 11) else 31


def _monthly_epoch(year: int, month: int, day: int, hour: int, minute: int) -> float:
    """Epoch for the day-of-month HH:MM UTC boundary (a day past the month's length clamps
    to the last day)."""
    return calendar.timegm((year, month, min(day, _days_in_month(year, month)),
                            hour, minute, 0, 0, 0, 0))


def go_window_bounds(spec: dict, now: float,
                     chain_fn=None) -> tuple[float | None, float | None]:
    """(window_start_epoch, resets_at_epoch) for a window spec at `now`.

    - rolling:  window_start = now - span_s (pure trailing floor); resets_at = None.
    - chain:    the window OPENS at the first request after the previous window expired and
                resets at open + span_s (first-use/expiry-chained, homelab#540). The open epoch
                is recovered from the LEDGER via the optional `chain_fn(span_s, lookback_s)`
                callback (returns the current open window's start epoch, or None when there is
                no open window / the probe failed). A None result DEGRADES to this window's
                GRID default (offset 217m) with one loud log line — a failed probe is not a
                fact, and a missing open window (idle > span) means there is no spend to count
                but the grid boundary is still the best-known next-reset prediction.
    - grid:     resets daily at (midnight UTC + offset + k*span_s), k = 0.. — i.e. for
                5h/217m the five daily times 03:37/08:37/13:37/18:37/23:37 UTC. The last one
                at-or-before now and the next after.
    - weekly:   resets on the named weekday HH:MM UTC, 7 days apart.
    - monthly:  resets on the named day-of-month HH:MM UTC, one month apart.
    An unknown anchor type degrades to rolling (never a crash — the conservative floor)."""
    span = float(spec.get("span_s", 0))
    anchor = spec.get("anchor", "rolling")
    if anchor == "chain" and span > 0:
        if chain_fn is not None:
            try:
                open_epoch = chain_fn(span, float(spec.get("chain_lookback_s", 7 * 86400)))
            except Exception as e:
                _golog(f"chain_fn for {anchor} raised {e!r} — degrading to grid default")
                open_epoch = None
            if open_epoch is not None:
                # Convention (documented, pinned in tests): when `now` is still inside the open
                # window it is [open, open+span); when now is at/after open+span there is NO
                # open window → usage 0 and the reset metric falls back to the GRID boundary
                # (best-known next reset for a dormant window), so the payload still carries a
                # plausible resets_at rather than None.
                if now < open_epoch + span:
                    return open_epoch, open_epoch + span
                _golog(f"chain window {anchor}: open {open_epoch:.0f} + span {span:.0f} <= now "
                       f"{now:.0f} — no open window (idle past expiry); grid fallback for reset")
            else:
                _golog(f"chain window {anchor}: chain_fn returned None (no open window / "
                       f"unreadable ledger) — degrading to grid default for this probe")
        else:
            _golog(f"chain window {anchor}: no chain_fn wired — degrading to grid default")
        # Degrade to this window's grid default (never a crash, never a silent zero).
        spec = {**spec, "anchor": "grid"}
        anchor = "grid"
    if anchor == "rolling" or span <= 0:
        return now - span, None
    if anchor == "grid":
        offset = float(spec.get("grid_offset_min", 0)) * 60
        gt = time.gmtime(now)
        day_mid = now - (gt.tm_hour * 3600 + gt.tm_min * 60 + gt.tm_sec)
        cands: list[float] = []
        for d in (-1, 0, 1):
            base = day_mid + d * 86400
            t, k = base + offset, 0
            while t < base + 86400:
                cands.append(t)
                k += 1
                t = base + offset + k * span
        cands.sort()
        last = max(c for c in cands if c <= now)
        nxt = min(c for c in cands if c > now)
        return last, nxt
    if anchor == "weekly":
        offset = float(spec.get("hour", 0)) * 3600 + float(spec.get("minute", 0)) * 60
        gt = time.gmtime(now)
        today_mid = now - (gt.tm_hour * 3600 + gt.tm_min * 60 + gt.tm_sec)
        days_back = (gt.tm_wday - _WEEKDAYS[spec.get("weekday", "mon")]) % 7
        last = today_mid - days_back * 86400 + offset
        if last > now:
            last -= 7 * 86400
        return last, last + 7 * 86400
    if anchor == "monthly":
        day = int(spec.get("month_day", 13))
        hour = int(spec.get("hour", 0))
        minute = int(spec.get("minute", 0))
        gt = time.gmtime(now)
        ly, lm = gt.tm_year, gt.tm_mon
        last = _monthly_epoch(ly, lm, day, hour, minute)
        if last > now:  # before this month's boundary → last was last month's
            ly, lm = (ly - 1, 12) if lm == 1 else (ly, lm - 1)
            last = _monthly_epoch(ly, lm, day, hour, minute)
        # next is one month AFTER `last` — NOT the month after `now`: when now precedes this
        # month's boundary, `next` is THIS month's boundary (which is in the future).
        ny, nm = (ly + 1, 1) if lm == 12 else (ly, lm + 1)
        return last, _monthly_epoch(ny, nm, day, hour, minute)
    return now - span, None


def go_window_status(now: float, usage_fn, chain_fn=None) -> dict:
    """The composite /opencode-limit answer (shared home, ADR-108): per-window usage/budget/
    utilization plus the anchored window_start/resets_at epochs, the by_stack breakdown for
    the BINDING window (the one with the highest utilization — the window that drives the
    verdict; the payload names it in `by_stack_window`), and the composite `limited` verdict
    (any window at/over its threshold).

    PRICING: utilization (and `limited`, and `by_stack`) use the WINDOW-DRAW amount —
    `window_draw()` (list price on raw tokens, badge-halved) — which is what OpenCode actually
    draws against the subscription windows (the 2026-08-17 reconciliation; the billed-style
    estimate under-counts ~30×). The payload states `"pricing": "window_draw"` and also carries
    `usage_usd_billed_est` per window so the two numbers cannot be conflated.

    usage_fn(name, window_start, resets_at) -> the router.go_usage_window(...) snapshot:
      {"total_usd": billed_est, "total_draw_usd": window_draw, "by_stack": {...},
       "by_stack_draw": {...}} — a callback keeps gometer import-free of router; the proxy
    wires `router.go_usage_window(GO_WINDOWS[name]['span_s'], since=window_start)` in.

    chain_fn(span_s, lookback_s) -> float | None — the CHAIN-anchor seam (homelab#540): returns
    the CURRENT open window's start epoch for a `chain`-anchored window, recovered from the
    ledger's go_usage.ts walk (router.go_usage_chain_open), or None when there is no open
    window (idle past expiry) / the ledger is unreadable. None DEGRADES that window to its
    grid default with one loud log line — a failed probe is not a fact."""
    windows: dict[str, dict] = {}
    by_stack: dict[str, float] = {}
    by_stack_window: str | None = None
    limited = False
    best_util = -1.0
    for name in _GO_WINDOW_ORDER:
        spec = GO_WINDOWS[name]
        win_start, resets_at = go_window_bounds(spec, now, chain_fn)
        snap = usage_fn(name, win_start, resets_at)
        draw = float(snap.get("total_draw_usd") or 0.0)
        billed = float(snap.get("total_usd") or 0.0)
        budget = float(spec.get("budget_usd") or 0.0)
        util = draw / budget if budget > 0 else 0.0
        windows[name] = {
            "usage_usd_window_draw": draw,
            "usage_usd_billed_est": billed,
            "budget_usd": budget,
            "utilization": util,
            "pricing": "window_draw",
            "window_start": round(win_start) if win_start is not None else None,
            "resets_at": round(resets_at) if resets_at is not None else None,
            # homelab#540: per-window anchor PROVENANCE (the CONFIGURED anchor for this window) —
            # additive, never a rename/removal of an existing field. `chain` for the 5h
            # first-use/expiry-chained window; `grid`/`weekly`/`monthly`/`rolling` for the
            # others. A `chain` window that DEGRADED to grid (unreadable ledger / idle past
            # expiry) still reports `chain` here; its window_start/resets_at are the grid-derived
            # bounds (the degrade logs loudly, so the operator can tell the difference).
            "anchor": spec.get("anchor", "rolling"),
        }
        if util >= GO_UTIL_THRESHOLDS.get(name, GO_UTIL_THRESHOLD):
            limited = True
        if util > best_util:
            best_util = util
            by_stack = dict(snap.get("by_stack_draw") or {})
            by_stack_window = name
    return {"limited": limited, "thresholds": dict(GO_UTIL_THRESHOLDS),
            "windows": windows, "by_stack": by_stack, "by_stack_window": by_stack_window,
            "pricing": "window_draw"}
