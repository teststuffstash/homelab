"""The codex rail's account headroom as an admission input (GW-CODEX-HEADROOM).

Ported from `experiments/codex-rail/headroom.py` (FU-270). One account, one immutable snapshot,
gateway state only — no Prometheus read (ADR-108). The ingress shape is the gateway's own
normalised schema, not a vendor payload:

    {"observed_at": <epoch s>, "source": "poll"|"upstream"|"jail", "limited": bool,
     "windows": [{"used_percent": 0–100, "resets_at": <epoch s>, "window_minutes": <int>}, …]}

`observe()` is the seam: who may call it (an authenticated, account-bound producer) is a `⚑ gap`
(no poll, no upstream-header reading, no jail ingress yet), so a fresh gateway answers
`quota-unknown` and the rail defers — fail closed. Freshness, the ceiling and the window profile
are policy (`rails.codex.headroom`, `rails.opencode.headroom`), never code literals. The Go rail
(GW-SESSIONS-ADMIT §Capacity) is the same engine with named windows: its report's windows carry
`window` (a name) where codex carries `window_minutes`, and the policy's `window_key` says which.
An ACCEPTED snapshot is handed to `on_accept` (§Gauges: `app.py` binds the metrics' two subscription
gauges there); a refused report reaches no listener. No rendering lives here.
"""

from __future__ import annotations

import math
from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum
from threading import RLock

from .config import HeadroomPolicy
from .oauth import finite

SOURCES = ("upstream", "poll", "jail")


class Verdict(StrEnum):
    ADMIT = "admit"
    UNKNOWN = "quota-unknown"
    STALE = "quota-stale"
    LIMITED = "quota-limited"


class ReportError(Exception):
    """A fixed reason only — never the report's content."""


@dataclass(frozen=True)
class Window:
    used: float  # 0–1
    resets_at: float
    key: int | str  # the policy's profile entry: a span in minutes (codex) or a window name (opencode)


@dataclass(frozen=True)
class Snapshot:
    observed_at: float
    source: str
    limited: bool
    windows: tuple[Window, ...]


def normalize(report, now: float, policy: HeadroomPolicy) -> Snapshot:
    """Validate one report against the policy's window profile, read under `policy.window_key`. A report
    missing a window, naming one outside the profile, or carrying a non-finite / bool-as-number /
    expired value is refused whole — zero usage alone is not capacity."""
    if not isinstance(report, dict):
        raise ReportError("quota-invalid")
    at = report.get("observed_at")
    if not finite(at) or at > now or now - at >= policy.max_age_s:
        raise ReportError("quota-time-invalid")
    source = report.get("source")
    if source not in SOURCES or type(report.get("limited")) is not bool:
        raise ReportError("quota-invalid")
    raw = report.get("windows")
    if not isinstance(raw, list) or len(raw) != len(policy.windows):
        raise ReportError("quota-invalid")
    windows = []
    for item in raw:
        if not isinstance(item, dict):
            raise ReportError("quota-invalid")
        used, reset, key = item.get("used_percent"), item.get("resets_at"), item.get(policy.window_key)
        if (not finite(used) or not 0 <= used <= 100 or not finite(reset) or reset <= now
                or type(key) not in (int, str) or key not in policy.windows):
            raise ReportError("quota-invalid")
        windows.append(Window(used / 100, reset, key))
    if {w.key for w in windows} != set(policy.windows):
        raise ReportError("quota-invalid")
    return Snapshot(at, source, report["limited"], tuple(sorted(windows, key=lambda w: w.key)))


class Headroom:
    def __init__(self, clock: Callable[[], float], policy: HeadroomPolicy):
        self.clock, self.policy = clock, policy
        self.snapshot: Snapshot | None = None
        self.on_accept: Callable[[Snapshot], None] | None = None  # bound by the composition, never a renderer
        self.lock = RLock()

    def observe(self, report) -> Snapshot:
        """Accept a strictly newer, valid report; anything else raises and leaves the last snapshot."""
        with self.lock:
            now = self.clock()
            if not finite(now):
                raise ReportError("quota-time-invalid")
            snapshot = normalize(report, now, self.policy)
            if self.snapshot and snapshot.observed_at <= self.snapshot.observed_at:
                raise ReportError("quota-out-of-order")
            self.snapshot = snapshot
            if self.on_accept is not None:
                self.on_accept(snapshot)
            return snapshot

    def verdict(self) -> Verdict:
        with self.lock:
            s, now = self.snapshot, self.clock()
            if s is None:
                return Verdict.UNKNOWN
            if (not finite(now) or now < s.observed_at or now - s.observed_at >= self.policy.max_age_s
                    or any(w.resets_at <= now for w in s.windows)):
                # A reset passing is not evidence that capacity replenished: ask for a new observation.
                return Verdict.STALE
            if s.limited or any(w.used >= self.policy.ceiling for w in s.windows):
                return Verdict.LIMITED
            return Verdict.ADMIT

    def retry_after(self, default_s: int) -> int:
        """Seconds until a `quota-limited` answer can change: the LATEST reset among the windows at
        or above the ceiling (every exhausted window must reset); `default_s` when only the
        explicit `limited` flag blocks, or for unknown / stale (a new observation is the cure)."""
        with self.lock:
            s, now = self.snapshot, self.clock()
            if s is None or self.verdict() != Verdict.LIMITED:
                return default_s
            over = [w.resets_at for w in s.windows if w.used >= self.policy.ceiling]
            if not over:
                return default_s
            return max(1, math.ceil(max(over) - now))
