"""Account-scoped quota observations and conservative local admission; no Prometheus."""
from dataclasses import dataclass
from enum import Enum
from threading import RLock
from lifecycle import finite


class Verdict(str, Enum):
    ADMIT = "admit"
    UNKNOWN = "quota-unknown"
    STALE = "quota-stale"
    LIMITED = "quota-limited"


class ReportError(Exception):
    """Fixed reason only; never echo report content."""


@dataclass(frozen=True)
class Window:
    used: float
    resets_at: float
    minutes: int


@dataclass(frozen=True)
class Snapshot:
    observed_at: float
    source: str
    limited: bool
    windows: tuple[Window, ...]


def normalize(report, now, max_age):
    """Explicit normalized ingress, not a claim about a vendor's wire schema.

    Trusted caller binds account and source authentication before calling this.
    Both configured quota windows are required; zero usage alone is not capacity.
    """
    if not isinstance(report, dict):
        raise ReportError("quota-invalid")
    at = report.get("observed_at")
    if not finite(at) or at > now or now - at >= max_age:
        raise ReportError("quota-time-invalid")
    source = report.get("source")
    if source not in ("upstream", "poll", "jail") or type(report.get("limited")) is not bool:
        raise ReportError("quota-invalid")
    raw = report.get("windows")
    if not isinstance(raw, list) or len(raw) != 2:
        raise ReportError("quota-invalid")
    windows = []
    for item in raw:
        if not isinstance(item, dict):
            raise ReportError("quota-invalid")
        used, reset, minutes = item.get("used_percent"), item.get("resets_at"), item.get("window_minutes")
        if (not finite(used) or not 0 <= used <= 100 or not finite(reset) or reset <= now
                or type(minutes) is not int or minutes not in (300, 10080)):
            raise ReportError("quota-invalid")
        windows.append(Window(used / 100, reset, minutes))
    if {w.minutes for w in windows} != {300, 10080}:
        raise ReportError("quota-invalid")
    return Snapshot(at, source, report["limited"], tuple(sorted(windows, key=lambda w: w.minutes)))


class Headroom:
    def __init__(self, clock, max_age=120, ceiling=0.95):
        if not finite(max_age) or max_age <= 0 or not finite(ceiling) or not 0 < ceiling <= 1:
            raise ValueError("invalid quota policy")
        self.clock, self.max_age, self.ceiling = clock, max_age, ceiling
        self.snapshot = None
        self.lock = RLock()

    def observe(self, report):
        with self.lock:
            now = self.clock()
            if not finite(now):
                raise ReportError("quota-time-invalid")
            snapshot = normalize(report, now, self.max_age)
            if self.snapshot and snapshot.observed_at <= self.snapshot.observed_at:
                raise ReportError("quota-out-of-order")
            self.snapshot = snapshot
            return snapshot

    def verdict(self):
        with self.lock:
            s, now = self.snapshot, self.clock()
            if s is None:
                return Verdict.UNKNOWN
            if (not finite(now) or now < s.observed_at or now - s.observed_at >= self.max_age
                    or any(w.resets_at <= now for w in s.windows)):
                # Reset passing is not evidence that capacity actually replenished.
                return Verdict.STALE
            if s.limited or any(w.used >= self.ceiling for w in s.windows):
                return Verdict.LIMITED
            return Verdict.ADMIT
