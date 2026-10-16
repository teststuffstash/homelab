"""The ladder's capacity half as admission facts (GW-SESSIONS-ADMIT, sessions.md §Capacity).

Three per-rail checks the admission walk consults after the slot count, each driven only by
`rails.<rail>.admission` in policy (no threshold, hold or price lives in this file):

- **utilization** — the subscription rail's last-seen `anthropic-ratelimit-unified-<w>-*` reading:
  a window at/over its threshold blocks the rail until that window's reset. A reading whose reset
  has passed, or that is older than `reading_stale_s`, is no reading (admits — never blocks).
- **429 latch** — an upstream 429 on a rail whose policy declares `latch_429_hold_s` blocks that
  rail until `retry-after` (else the hold); any 2xx on the rail clears it. In memory: a restart
  forgets, the next 429 re-latches.
- **window draw** — the Go rail's spend per subscription window, priced from the four token
  classes at list rates (gometer `window_draw()` semantics), read from the gateway's own request
  ledger; a window at/over `threshold × budget_usd` blocks the rail until that window resets.

`blocked(rail, now)` answers `(reason, free_at, detail)` or None; the walk skips a blocked rail
exactly like a full one.
"""

from __future__ import annotations

import calendar
import logging
import threading
import time
from collections.abc import Mapping
from dataclasses import dataclass

from .config import SUBSCRIPTION_WINDOWS, DrawWindow, Policy, PriceRow, WindowDraw
from .store import Store

log = logging.getLogger("gateway.capacity")


def subscription_windows(headers: Mapping[str, str]) -> dict[str, tuple[float, float]]:
    """{window: (utilization 0–1, reset epoch)} from `anthropic-ratelimit-unified-<w>-*`; a window
    with an absent or malformed field is left out (no guessing)."""
    out: dict[str, tuple[float, float]] = {}
    for w in SUBSCRIPTION_WINDOWS:
        try:
            out[w] = (float(headers[f"anthropic-ratelimit-unified-{w}-utilization"]),
                      float(headers[f"anthropic-ratelimit-unified-{w}-reset"]))
        except (KeyError, ValueError, TypeError):
            continue
    return out


@dataclass(frozen=True)
class Reading:
    utilization: float
    reset: float
    seen_at: float


@dataclass(frozen=True)
class Block:
    reason: str  # a `post.defer.reason` value: rail-window | rail-latched
    free_at: float  # epoch the rail may admit again
    detail: str


def is_peak(wd: WindowDraw, ts: float) -> bool:
    gt = time.gmtime(ts)
    return gt.tm_wday in wd.peak_weekdays and any(lo <= gt.tm_hour < hi for lo, hi in wd.peak_hours_utc)


def price_row(wd: WindowDraw, model: str, ts: float) -> PriceRow:
    """The row a request at `ts` draws at: the peak row inside a peak hour, else the base row;
    an unpriced model → the fallback row (fail conservative, gometer `_GO_MAX_PRICE`)."""
    if model in wd.peak_prices and is_peak(wd, ts):
        return wd.peak_prices[model]
    return wd.prices.get(model, wd.fallback)


def draw_usd(row: PriceRow, tokens_in: int, cache_read: int, cache_write: int, tokens_out: int) -> float:
    """gometer `window_draw()`: uncached input + output at list, each cache class at its OWN list
    rate; a class with no rate (`None`) draws nothing."""
    d = (tokens_in * row.tokens_in + tokens_out * row.tokens_out) / 1e6
    d += cache_read * row.cache_read / 1e6 if row.cache_read else 0.0
    d += cache_write * row.cache_write / 1e6 if row.cache_write else 0.0
    return d


def _monthly(year: int, month: int, day: int, hour: int, minute: int) -> float:
    days = calendar.monthrange(year, month)[1]
    return calendar.timegm((year, month, min(day, days), hour, minute, 0, 0, 0, 0))


def window_bounds(w: DrawWindow, now: float, request_ts: list[float]) -> tuple[float, float] | None:
    """(start, reset) of the window open at `now`, or None when none is open (gometer
    `go_window_bounds`). `request_ts` = the rail's metered request timestamps, ascending (chain only)."""
    if w.anchor == "chain":
        open_at: float | None = None
        for ts in request_ts:
            if ts > now - w.chain_lookback_s and (open_at is None or ts >= open_at + w.span_s):
                open_at = ts
        if open_at is None or now >= open_at + w.span_s:
            return None  # idle past expiry: no open window, nothing drawn
        return open_at, open_at + w.span_s
    if w.anchor == "weekly":
        gt = time.gmtime(now)
        midnight = now - (gt.tm_hour * 3600 + gt.tm_min * 60 + gt.tm_sec)
        last = midnight - ((gt.tm_wday - w.weekday) % 7) * 86400 + w.hour * 3600 + w.minute * 60
        if last > now:
            last -= 7 * 86400
        return last, last + 7 * 86400
    # monthly
    gt = time.gmtime(now)
    y, m = gt.tm_year, gt.tm_mon
    last = _monthly(y, m, w.month_day, w.hour, w.minute)
    if last > now:
        y, m = (y - 1, 12) if m == 1 else (y, m - 1)
        last = _monthly(y, m, w.month_day, w.hour, w.minute)
    ny, nm = (y + 1, 1) if m == 12 else (y, m + 1)
    return last, _monthly(ny, nm, w.month_day, w.hour, w.minute)


class Capacity:
    def __init__(self, policy: Policy, store: Store):
        self.policy = policy
        self.store = store
        self._lock = threading.Lock()
        self.readings: dict[str, dict[str, Reading]] = {}
        self.latched_until: dict[str, float] = {}

    # -- the data plane reports --------------------------------------------------------------
    def observe(self, rail: str, status: int, headers: Mapping[str, str], now: float) -> str:
        """Fold one upstream answer into the rail's state. Returns a log-safe note suffix."""
        adm = self.policy.rails[rail].admission
        note = ""
        if adm.utilization_thresholds:
            seen = subscription_windows(headers)
            if seen:
                with self._lock:
                    r = self.readings.setdefault(rail, {})
                    for w, (util, reset) in seen.items():
                        r[w] = Reading(util, reset, now)
        if status == 429 and adm.latch_429_hold_s:
            try:
                hold = float(headers.get("retry-after") or 0) or adm.latch_429_hold_s
            except (TypeError, ValueError):  # an HTTP-date or junk: the policy hold
                hold = adm.latch_429_hold_s
            with self._lock:
                self.latched_until[rail] = now + hold
            log.warning("capacity: %s 429 — rail latched for %.0f s", rail, hold)
            note = "+429-latched"
        elif 200 <= status < 300:
            with self._lock:
                if self.latched_until.pop(rail, 0.0) > now:
                    log.info("capacity: %s 2xx while latched — latch cleared", rail)
                    note = "+latch-cleared"
        return note

    # -- the admission walk asks ------------------------------------------------------------
    def blocked(self, rail: str, now: float) -> Block | None:
        """The rail's capacity verdict at `now`: every block that holds, merged — the rail frees
        when the LAST of them lifts; the reason is the one that lifts last."""
        adm = self.policy.rails[rail].admission
        blocks: list[Block] = []
        with self._lock:
            until = self.latched_until.get(rail, 0.0)
            readings = dict(self.readings.get(rail, {}))
        if until > now:
            blocks.append(Block("rail-latched", until, f"{rail} 429-latched"))
        for w, thr in adm.utilization_thresholds.items():
            rd = readings.get(w)
            if rd is None or thr <= 0 or now >= rd.reset:
                continue  # no reading, window off, or the window already reset (dead data)
            if now - rd.seen_at > (adm.reading_stale_s or 0):
                continue  # stale: no header for reading_stale_s — an unavailable reading is no reading
            if rd.utilization >= thr:
                blocks.append(Block("rail-window", rd.reset, f"{rail} {w} utilization {rd.utilization:g} >= {thr:g}"))
        if adm.window_draw is not None:
            blocks += self._draw_blocks(rail, adm.window_draw, now)
        if not blocks:
            return None
        return max(blocks, key=lambda b: b.free_at)

    def draws(self, rail: str, wd: WindowDraw, now: float) -> dict[str, tuple[float, tuple[float, float] | None]]:
        """{window: (draw usd, bounds)} over the gateway's own ledger for this rail."""
        lookback = max((w.chain_lookback_s if w.anchor == "chain" else 32 * 86400) for w in wd.windows)
        rows = self.store.rail_usage_since(rail, now - lookback)
        ts_list = [r[0] for r in rows]
        out: dict[str, tuple[float, tuple[float, float] | None]] = {}
        for w in wd.windows:
            bounds = window_bounds(w, now, ts_list)
            if bounds is None:
                out[w.name] = (0.0, None)
                continue
            start = bounds[0]
            out[w.name] = (sum(draw_usd(price_row(wd, model, ts), tin, cr, cw, tout)
                               for ts, model, tin, cr, cw, tout in rows if start <= ts <= now), bounds)
        return out

    def _draw_blocks(self, rail: str, wd: WindowDraw, now: float) -> list[Block]:
        blocks = []
        draws = self.draws(rail, wd, now)
        for w in wd.windows:
            draw, bounds = draws[w.name]
            if bounds is None or w.threshold <= 0:
                continue
            if draw >= w.threshold * w.budget_usd:
                blocks.append(Block("rail-window", bounds[1],
                                    f"{rail} {w.name} window draw ${draw:.4f} >= {w.threshold:g} x ${w.budget_usd:g}"))
        return blocks
