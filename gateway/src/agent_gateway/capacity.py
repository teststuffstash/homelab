"""The ladder's capacity half as admission facts (GW-SESSIONS-ADMIT, sessions.md §Capacity).

Three per-rail checks the admission walk consults after the slot count, each driven only by
`rails.<rail>.admission` in policy (no threshold, hold or price lives in this file):

- **utilization** — the subscription rail's last-seen `anthropic-ratelimit-unified-<w>-*` reading:
  a window at/over its threshold blocks the rail until that window's reset. A reading whose reset
  has passed, or that is older than `reading_stale_s`, is no reading (admits — never blocks).
- **cell cooldown** — every upstream 429 cools the (rail, model) CELL that saw it until its reset
  (`retry-after`, else OpenRouter's `x-ratelimit-reset` in epoch ms, else the rail's
  `latch_429_hold_s`, else the policy `defer_retry_s`); admission skips a cooled cell and any 2xx
  on that cell clears it. A 429 is a model's fact unless the rail is one account.
- **429 latch** — the account-scope signal: a rail whose policy declares `latch_429_hold_s` (the
  subscription rails, one account each) is latched by a 429 for the same reset; any 2xx on the
  rail clears it.
- **credential rejected** — an upstream 401, or a 403 whose error names a credential reason, marks
  THAT credential (rail + sha256 of the value, never the value) rejected. It RECOVERS WITHOUT
  TRAFFIC: a rail with a policy `credential_probe` is re-verified by the gateway itself on a
  doubling backoff (`reprobe()`, the app's background loop) and cleared by the probe's 2xx; a rail
  without one is re-admitted half-open after `credential_hold_s` (a fresh rejection doubles the
  hold). A 2xx on the credential clears it, and a changed value is a different fingerprint.
- **the marks survive a restart** (operator ruling 2026-10-21): every cooldown, latch, rejection and
  the backoff it doubles from is written through to the store's `capacity_marks` table as it is set,
  cleared or re-scheduled, and a new gateway on the same DB reloads them at start (`_reload`) —
  minus what the in-memory logic would already have let go: a cooldown or latch past its `until`,
  and a no-probe rail's rejection past its half-open (its hold stays, so a repeat still doubles).
  A probe rail's rejection past its due time reloads as due: the first pass after the roll sends it.
- **window draw** — the Go rail's spend per MODEL per subscription window, priced from the four
  token classes at the Go catalog's list rates (gometer `window_draw()` semantics), read from the
  gateway's own request ledger; a window at/over `threshold × monthly limit × share` blocks the
  cell until that window resets. A model the catalog does not list (or gives no monthly limit
  under the policy's plan) is `not-in-catalog` — refused, never priced at a fallback.
- **the Go price** (`go_pricing`, GW-MODEL-TIERS §Cost per clean ride): the plan's monthly fee
  over what the plan bought — per model, the list price × `fee ÷ max(the rail's trailing-30-day
  list-priced draw, the model's own monthly limit)`: the fee buys at least the model's allowance
  (the `promise` basis), and a busier rail makes every Go token cheaper (`measured`). An
  unlimited model prices at 0. The same ledger and the same list rates as the window draw.

`blocked(rail, now, model)` answers `(reason, free_at, detail)` or None; the walk skips a blocked
rail exactly like a full one.
"""

from __future__ import annotations

import calendar
import hashlib
import logging
import threading
import time
from collections.abc import Mapping
from dataclasses import dataclass
from typing import TYPE_CHECKING

from .config import RAIL_PREFIX, SUBSCRIPTION_WINDOWS, DrawWindow, Policy, PriceRow, WindowDraw, wire_model
from .store import Store

if TYPE_CHECKING:
    from .catalog import GoCatalog, GoModel

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


def reset_at(headers: Mapping[str, str], now: float) -> float | None:
    """When a 429's limit resets, read from the wire: `retry-after` (delta seconds) first, then
    `x-ratelimit-reset` — OpenRouter sends epoch MILLISECONDS and no `retry-after` (the 2026-10-17
    free-model experiment's tap); an epoch in seconds and a small delta are read as such. A reset
    already past is clamped to `now + 1`. None = the wire names no reset (an HTTP-date, junk)."""
    ra = headers.get("retry-after")
    if ra is not None:
        try:
            v = float(ra)
            if v >= 0:
                return now + max(v, 1.0)
        except (TypeError, ValueError):
            pass
    xr = headers.get("x-ratelimit-reset")
    if xr is not None:
        try:
            v = float(xr)
        except (TypeError, ValueError):
            return None
        if v > 1e11:  # epoch milliseconds
            v /= 1000.0
        elif v < 1e9:  # a delta in seconds
            v += now
        return max(v, now + 1.0)
    return None


def fingerprint(credential: str) -> str:
    """The credential-rejected key: a short sha256 of the value — never the value (GW-REDACT)."""
    return hashlib.sha256(credential.encode()).hexdigest()[:16]


def _cell_key(rail: str, model: str, provider: str) -> str:
    """The stored `cooled` mark's key — `rail|model|provider` (no policy model id or slug carries `|`)."""
    return f"{rail}|{model}|{provider}"


def _cred_key(rail: str, fp: str) -> str:
    """The stored `rejected` / `hold` mark's key — `rail|<fingerprint>`: the sha256 prefix, never the value."""
    return f"{rail}|{fp}"


@dataclass
class Rejection:
    stack: str  # a stack whose ref resolved to this credential (the probe re-resolves through it)
    since: float
    next_at: float  # the probe is due (probe rails) / the half-open re-admission (no-probe rails)
    backoff: float


@dataclass(frozen=True)
class Reading:
    utilization: float
    reset: float
    seen_at: float


@dataclass(frozen=True)
class Block:
    reason: str  # a `post.defer.reason` value: rail-window | rail-latched | cell-cooled | not-in-catalog
    free_at: float  # epoch the rail may admit again
    detail: str


def is_peak(m: GoModel, ts: float) -> bool:
    gt = time.gmtime(ts)
    return gt.tm_wday in m.peak_weekdays and any(lo <= gt.tm_hour < hi for lo, hi in m.peak_hours_utc)


def price_row(m: GoModel, ts: float, prompt_tokens: int) -> PriceRow:
    """The row a request at `ts` draws at: the model's peak row inside a peak hour; else the cost
    tier its prompt falls in — the base row, or the highest `tier: {type: context, size}` row the
    prompt (uncached + cache read + cache write) exceeds."""
    if m.peak is not None and is_peak(m, ts):
        return m.peak
    row = m.cost[0][1]
    for above, tier in m.cost[1:]:
        if prompt_tokens > above:
            row = tier
    return row


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
    def __init__(self, policy: Policy, store: Store, catalog: GoCatalog | None = None, clock=time.time):
        self.policy = policy
        self.store = store
        self.catalog = catalog  # the Go catalog (GW-CATALOG-GO); None = every Go model is not-in-catalog
        self._lock = threading.Lock()
        self.readings: dict[str, dict[str, Reading]] = {}
        self.latched_until: dict[str, float] = {}
        # (rail, policy model id, provider) -> epoch; provider '' = the model's own (unpinned) cooldown, a
        # slug = that provider's cell on the model (GW-RAIL-OPENROUTER: the cell is (rail, model, provider))
        self.cooled_until: dict[tuple[str, str, str], float] = {}
        self.rejected: dict[tuple[str, str], Rejection] = {}  # (rail, credential fingerprint) -> the mark
        self._hold: dict[tuple[str, str], float] = {}  # the last hold/backoff per credential, for doubling
        # The four dicts above are store-backed (`capacity_marks`): every set / pop below writes through
        # under this lock, and a new gateway on the same DB starts from what the last one held.
        self._reload(clock())

    def _reload(self, now: float) -> None:
        """Load the stored marks a restart must keep, dropping (and deleting) the ones the in-memory
        logic would have let go by `now`: an expired cooldown or latch, a no-probe rail's rejection
        past its half-open (the hold row stays: a repeat still doubles), anything on a rail the
        policy no longer names. A probe rail's rejection past its due time is kept — the first
        re-probe pass sends it."""
        kept: dict[str, int] = {"cooled": 0, "latched": 0, "rejected": 0, "hold": 0}
        dropped = 0
        with self._lock:
            for row in self.store.marks_load():
                kind, key, until = row["kind"], row["key"], row["until"]
                rail = key.split("|", 1)[0]
                rp = self.policy.rails.get(rail)
                keep = rp is not None and kind in kept
                if keep and kind in ("cooled", "latched"):
                    keep = until is not None and until > now
                if keep and kind == "rejected":
                    keep = until is not None and (rp.credential_probe is not None or until > now)
                if not keep:
                    self.store.mark_delete(kind, key)
                    dropped += 1
                    continue
                if kind == "cooled":
                    r, model, provider = key.split("|", 2)
                    self.cooled_until[(r, model, provider)] = until
                elif kind == "latched":
                    self.latched_until[rail] = until
                elif kind == "rejected":
                    fp = key.split("|", 1)[1]
                    self.rejected[(rail, fp)] = Rejection(row["stack"] or "", float(row["at"] or until), until, float(row["backoff"] or 0.0))
                else:
                    fp = key.split("|", 1)[1]
                    self._hold[(rail, fp)] = float(row["backoff"] or 0.0)
                kept[kind] += 1
        log.info("capacity: reloaded %d marks from the store (%d cooled, %d latched, %d rejected, %d holds; %d dropped as expired)",
                 sum(kept.values()), kept["cooled"], kept["latched"], kept["rejected"], kept["hold"], dropped)

    # -- the data plane reports --------------------------------------------------------------
    def observe(self, rail: str, status: int, headers: Mapping[str, str], now: float, model: str | None = None,
                credential: str | None = None, provider: str = "") -> str:
        """Fold one upstream answer into the rail's and the cell's state. Returns a log-safe note suffix."""
        adm = self.policy.rails[rail].admission
        note = ""
        if adm.utilization_thresholds:
            seen = subscription_windows(headers)
            if seen:
                with self._lock:
                    r = self.readings.setdefault(rail, {})
                    for w, (util, reset) in seen.items():
                        r[w] = Reading(util, reset, now)
        if status == 429:
            until = reset_at(headers, now)
            if until is None:
                until = now + (adm.latch_429_hold_s or self.policy.defer_retry_s)
            if model is not None:
                with self._lock:
                    self.cooled_until[(rail, model, provider)] = until
                    self.store.mark_set("cooled", _cell_key(rail, model, provider), until)
                log.warning("capacity: %s 429 on %s%s — cell cooled for %.0f s", rail, model,
                            f" @{provider}" if provider else "", until - now)
                note = "+cell-cooled"
            if adm.latch_429_hold_s and adm.latch_scope == "account":
                with self._lock:
                    self.latched_until[rail] = until
                    self.store.mark_set("latched", rail, until)
                log.warning("capacity: %s 429 — rail latched for %.0f s (account scope: the rail declares latch_429_hold_s)",
                            rail, until - now)
                note += "+429-latched"
        elif 200 <= status < 300:
            with self._lock:
                if rail in self.latched_until:
                    if self.latched_until.pop(rail) > now:
                        log.info("capacity: %s 2xx while latched — latch cleared", rail)
                        note = "+latch-cleared"
                    self.store.mark_delete("latched", rail)
                if model is not None and (rail, model, provider) in self.cooled_until:
                    if self.cooled_until.pop((rail, model, provider)) > now:
                        log.info("capacity: %s 2xx on %s%s while cooled — cell cleared", rail, model, f" @{provider}" if provider else "")
                        note += "+cell-cleared"
                    self.store.mark_delete("cooled", _cell_key(rail, model, provider))
                if credential is not None:
                    key = (rail, fingerprint(credential))
                    if self.rejected.pop(key, None) is not None:
                        log.info("capacity: %s 2xx on a rejected credential — credential cleared", rail)
                        note += "+credential-cleared"
                        self.store.mark_delete("rejected", _cred_key(*key))
                    if self._hold.pop(key, None) is not None:
                        self.store.mark_delete("hold", _cred_key(*key))
        return note

    def reject_credential(self, rail: str, credential: str, now: float, stack: str = "") -> None:
        """An upstream credential verdict: mark this credential, due for a re-verification after the
        rail's first backoff (probe rails) or its hold (no probe), doubling on a repeat."""
        rp = self.policy.rails[rail]
        key = (rail, fingerprint(credential))
        with self._lock:
            if key in self.rejected:
                return
            first = rp.credential_probe.backoff_s[0] if rp.credential_probe else rp.credential_hold_s
            cap = rp.credential_probe.backoff_s[1] if rp.credential_probe else max(rp.credential_hold_s * 4, rp.credential_hold_s)
            prev = self._hold.get(key)
            backoff = min(prev * 2, cap) if prev else first
            self._hold[key] = backoff
            self.rejected[key] = Rejection(stack, now, now + backoff, backoff)
            self.store.mark_set("hold", _cred_key(*key), None, backoff=backoff)
            self.store.mark_set("rejected", _cred_key(*key), now + backoff, stack=stack, at=now, backoff=backoff)
        log.error("capacity: %s credential %s rejected upstream — admission skips it; %s in %.0f s",
                  rail, key[1], "re-probed" if rp.credential_probe else "re-admitted half-open", backoff)

    def credential_rejected(self, rail: str, credential: str, now: float | None = None) -> float | None:
        """When the rejected credential is next re-verified (epoch), or None when it admits. A no-probe
        rail's mark lifts at its hold (half-open: the next ride is the probe)."""
        key = (rail, fingerprint(credential))
        with self._lock:
            mark = self.rejected.get(key)
            if mark is None:
                return None
            if self.policy.rails[rail].credential_probe is None and now is not None and now >= mark.next_at:
                del self.rejected[key]  # half-open; `_hold` keeps the backoff, so a repeat doubles it
                self.store.mark_delete("rejected", _cred_key(*key))
                log.info("capacity: %s credential %s re-admitted half-open after %.0f s", rail, key[1], mark.backoff)
                return None
            return mark.next_at

    def due_probes(self, now: float) -> list[tuple[str, str, Rejection]]:
        with self._lock:
            return [(rail, fp, m) for (rail, fp), m in self.rejected.items()
                    if self.policy.rails[rail].credential_probe is not None and m.next_at <= now]

    def probe_result(self, rail: str, fp: str, ok: bool | None, now: float) -> None:
        """ok True = the probe's 2xx (cleared); False = rejected again (backoff doubles); None = no
        verdict (the upstream or the kube API away — retried at the same backoff)."""
        with self._lock:
            mark = self.rejected.get((rail, fp))
            if mark is None:
                return
            if ok:
                del self.rejected[(rail, fp)]
                self._hold.pop((rail, fp), None)
                self.store.mark_delete("rejected", _cred_key(rail, fp))
                self.store.mark_delete("hold", _cred_key(rail, fp))
                log.info("capacity: %s credential %s re-verified by the probe — cleared", rail, fp)
                return
            if ok is False:
                cap = self.policy.rails[rail].credential_probe.backoff_s[1]
                mark.backoff = min(mark.backoff * 2, cap)
                self._hold[(rail, fp)] = mark.backoff
                self.store.mark_set("hold", _cred_key(rail, fp), None, backoff=mark.backoff)
            mark.next_at = now + mark.backoff
            self.store.mark_set("rejected", _cred_key(rail, fp), mark.next_at, stack=mark.stack, at=mark.since, backoff=mark.backoff)
        log.warning("capacity: %s credential %s probe %s — next in %.0f s", rail, fp, "rejected again" if ok is False else "inconclusive",
                    mark.backoff)

    def clear_credential(self, rail: str, fp: str, why: str) -> None:
        with self._lock:
            self.rejected.pop((rail, fp), None)
            self._hold.pop((rail, fp), None)
            self.store.mark_delete("rejected", _cred_key(rail, fp))
            self.store.mark_delete("hold", _cred_key(rail, fp))
        log.info("capacity: %s credential %s cleared — %s", rail, fp, why)

    def cooled(self, rail: str, model: str, now: float, provider: str = "") -> float | None:
        """The cell's cooldown expiry, or None when the cell admits ('' = the model's unpinned cell)."""
        with self._lock:
            until = self.cooled_until.get((rail, model, provider), 0.0)
        return until if until > now else None

    def cooled_providers(self, rail: str, model: str, now: float) -> dict[str, float]:
        """The model's cooled PROVIDER cells: {slug: expiry} (GW-RAIL-OPENROUTER §Selection skips them)."""
        with self._lock:
            return {p: until for (r, m, p), until in self.cooled_until.items() if r == rail and m == model and p and until > now}

    def cooled_counts(self, now: float) -> dict[str, int]:
        with self._lock:
            out: dict[str, int] = {}
            for (rail, _model, _provider), until in self.cooled_until.items():
                if until > now:
                    out[rail] = out.get(rail, 0) + 1
            return out

    def rejected_counts(self) -> dict[str, int]:
        with self._lock:
            out: dict[str, int] = {}
            for rail, _fp in self.rejected:
                out[rail] = out.get(rail, 0) + 1
            return out

    # -- the admission walk asks ------------------------------------------------------------
    def blocked(self, rail: str, now: float, model: str | None = None) -> Block | None:
        """The rail's capacity verdict at `now` for `model`: every block that holds, merged — the
        rail frees when the LAST of them lifts; the reason is the one that lifts last (a tie names
        the first listed: the latch, then the cell)."""
        adm = self.policy.rails[rail].admission
        blocks: list[Block] = []
        with self._lock:
            until = self.latched_until.get(rail, 0.0)
            readings = dict(self.readings.get(rail, {}))
        if until > now:
            blocks.append(Block("rail-latched", until, f"{rail} 429-latched"))
        if model is not None and (cell := self.cooled(rail, model, now)) is not None:
            blocks.append(Block("cell-cooled", cell, f"{rail} cell {model} cooled (429)"))
        for w, thr in adm.utilization_thresholds.items():
            rd = readings.get(w)
            if rd is None or thr <= 0 or now >= rd.reset:
                continue  # no reading, window off, or the window already reset (dead data)
            if now - rd.seen_at > (adm.reading_stale_s or 0):
                continue  # stale: no header for reading_stale_s — an unavailable reading is no reading
            if rd.utilization >= thr:
                blocks.append(Block("rail-window", rd.reset, f"{rail} {w} utilization {rd.utilization:g} >= {thr:g}"))
        if model is not None and (mb := self.model_block(rail, model, now)) is not None:
            blocks.append(mb)
        if not blocks:
            return None
        return max(blocks, key=lambda b: b.free_at)

    def model_block(self, rail: str, model: str, now: float) -> Block | None:
        """The MODEL's own capacity verdict (the Go rail's per-model window draw and catalog
        membership): its blocks merged — it frees when the last lifts. None = the model admits."""
        wd = self.policy.rails[rail].admission.window_draw
        if wd is None:
            return None
        blocks = self._draw_blocks(rail, wd, now, model)
        return max(blocks, key=lambda b: b.free_at) if blocks else None

    def go_model(self, rail: str, model: str) -> GoModel | str:
        return self.catalog.go_model(wire_model(rail, model)) if self.catalog is not None else "no Go catalog"

    def draws(self, rail: str, wd: WindowDraw, now: float, model: str, facts: GoModel
              ) -> dict[str, tuple[float, tuple[float, float] | None]]:
        """{window: (draw usd, bounds)} over the gateway's own ledger for this rail's MODEL (the
        cell): the vendor meters each model against its own monthly limit (ruling 3)."""
        lookback = max((w.chain_lookback_s if w.anchor == "chain" else 32 * 86400) for w in wd.windows)
        rows = [r for r in self.store.rail_usage_since(rail, now - lookback) if r[1] == model]
        ts_list = [r[0] for r in rows]
        out: dict[str, tuple[float, tuple[float, float] | None]] = {}
        for w in wd.windows:
            bounds = window_bounds(w, now, ts_list)
            if bounds is None:
                out[w.name] = (0.0, None)
                continue
            start = bounds[0]
            out[w.name] = (sum(draw_usd(price_row(facts, ts, tin + cr + cw), tin, cr, cw, tout)
                               for ts, _m, tin, cr, cw, tout in rows if start <= ts <= now), bounds)
        return out

    # -- the Go price (GW-MODEL-TIERS §Cost per clean ride) ------------------------------------
    def go_pricing(self, rail: str, now: float, lookback_s: float = 30 * 86400.0) -> dict:
        """Every listed Go model's price: `{fee_usd_month, draw_30d_usd, models: {wire id: {out, in,
        discount, basis, rides: {clean, judged}}}}`. `discount` = fee ÷ max(the rail's list-priced
        draw over the trailing 30 d, the model's monthly limit) — `promise` while the draw is under
        the model's allowance, `measured` past it, `unlimited` (0) for a model with no limit; no fee
        (no docs snapshot carrying the Plan table) = no price, basis null."""
        cat = self.catalog
        fee = cat.plan_fee() if cat is not None else None
        rows = self.store.rail_usage_since(rail, now - lookback_s)
        draw = 0.0
        facts_by: dict[str, GoModel | str] = {}
        for ts, model, tin, cr, cw, tout in rows:
            wire = wire_model(rail, model)
            f = facts_by.get(wire)
            if f is None:
                f = facts_by[wire] = self.go_model(rail, model)
            if isinstance(f, str):
                continue  # a model the catalog no longer prices draws nothing here (never a fallback rate)
            draw += draw_usd(price_row(f, ts, tin + cr + cw), tin, cr, cw, tout)
        models: dict[str, dict] = {}
        for wire in (cat.listed() if cat is not None else []):
            pid = RAIL_PREFIX[rail] + wire
            f = self.go_model(rail, pid)
            rides = self.store.cell_outcomes(rail, pid).get("", (0, 0))
            row: dict = {"out": None, "in": None, "discount": None, "basis": None, "rides": {"clean": rides[0], "judged": rides[1]}}
            if not isinstance(f, str) and fee is not None:
                base = f.cost[0][1]
                if f.monthly_limit is None:
                    row.update(out=0.0, in_=0.0, discount=0.0, basis="unlimited")
                else:
                    discount = fee / max(draw, f.monthly_limit)
                    row.update(out=round(base.tokens_out * discount, 9), in_=round(base.tokens_in * discount, 9),
                               discount=round(discount, 9), basis="measured" if draw >= f.monthly_limit else "promise")
                row["in"] = row.pop("in_")
            models[wire] = row
        return {"fee_usd_month": fee, "draw_30d_usd": round(draw, 6), "models": models}

    def _draw_blocks(self, rail: str, wd: WindowDraw, now: float, model: str) -> list[Block]:
        facts = self.go_model(rail, model)
        if isinstance(facts, str):
            free_at = (self.catalog.retry_at(now, self.policy.defer_retry_s) if self.catalog is not None
                       else now + self.policy.defer_retry_s)
            return [Block("not-in-catalog", free_at, f"{rail} {model}: {facts}")]
        if facts.monthly_limit is None:
            return []  # an unlimited model draws against no window
        blocks = []
        draws = self.draws(rail, wd, now, model, facts)
        for w in wd.windows:
            draw, bounds = draws[w.name]
            budget = facts.monthly_limit * facts.shares.get(w.name, 0.0)
            if bounds is None or w.threshold <= 0 or budget <= 0:
                continue
            if draw >= w.threshold * budget:
                blocks.append(Block("rail-window", bounds[1],
                                    f"{rail} {model} {w.name} window draw ${draw:.4f} >= {w.threshold:g} x ${budget:g}"))
        return blocks
