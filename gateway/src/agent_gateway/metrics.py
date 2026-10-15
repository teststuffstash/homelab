"""Hand-rolled Prometheus text exposition (GW-METRICS) — bounded label values only.

Families: `gateway_sessions_active{rail}`, `gateway_sessions_total{rail,role,stack,decision}`,
`gateway_requests_total{rail,dialect,status}`, `gateway_upstream_seconds{rail}` (histogram),
`gateway_tokens_total{rail,direction}`, `gateway_credential_resolve_total{rail,outcome}`.
A label value outside its declared set renders as `other` — a task key, a session id or a model
string can never become a series (cardinality is a policy decision, not a request's).
"""

from __future__ import annotations

import threading
from collections.abc import Callable, Iterable

from .config import DIALECTS, RAILS, ROLES

OTHER = "other"
DECISIONS = ("dispatch", "defer")
DIRECTIONS = ("in", "out")
CRED_OUTCOMES = ("resolved", "definitive", "transient")
BUCKETS = (0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600)


def _bounded(value: str, allowed: Iterable[str]) -> str:
    return value if value in allowed else OTHER


def _status_class(status: int) -> str:
    return str(status) if 100 <= status < 600 else OTHER


def _fmt_labels(labels: dict[str, str]) -> str:
    if not labels:
        return ""
    return "{" + ",".join(f'{k}="{v}"' for k, v in labels.items()) + "}"


class Metrics:
    def __init__(self, stacks: Iterable[str]):
        self.stacks = tuple(stacks)
        self._lock = threading.Lock()
        self.sessions_total: dict[tuple[str, str, str, str], int] = {}
        self.requests_total: dict[tuple[str, str, str], int] = {}
        self.tokens_total: dict[tuple[str, str], int] = {}
        self.cred_total: dict[tuple[str, str], int] = {}
        self.upstream_buckets: dict[str, list[int]] = {}
        self.upstream_sum: dict[str, float] = {}
        self.upstream_count: dict[str, int] = {}
        self._gauge_source: Callable[[], dict[str, int]] | None = None

    def bind_active_sessions(self, source: Callable[[], dict[str, int]]) -> None:
        self._gauge_source = source

    def session_decision(self, rail: str, role: str, stack: str, decision: str) -> None:
        key = (_bounded(rail, RAILS + ("none",)), _bounded(role, ROLES), _bounded(stack, self.stacks), _bounded(decision, DECISIONS))
        with self._lock:
            self.sessions_total[key] = self.sessions_total.get(key, 0) + 1

    def request(self, rail: str, dialect: str, status: int, upstream_s: float | None = None) -> None:
        r = _bounded(rail, RAILS + ("none",))  # `none`: refused before a session named a rail
        key = (r, _bounded(dialect, DIALECTS), _status_class(status))
        with self._lock:
            self.requests_total[key] = self.requests_total.get(key, 0) + 1
            if upstream_s is not None:
                b = self.upstream_buckets.setdefault(r, [0] * len(BUCKETS))
                for i, le in enumerate(BUCKETS):
                    if upstream_s <= le:
                        b[i] += 1
                self.upstream_sum[r] = self.upstream_sum.get(r, 0.0) + upstream_s
                self.upstream_count[r] = self.upstream_count.get(r, 0) + 1

    def tokens(self, rail: str, tokens_in: int, tokens_out: int) -> None:
        r = _bounded(rail, RAILS)
        with self._lock:
            if tokens_in:
                self.tokens_total[(r, "in")] = self.tokens_total.get((r, "in"), 0) + tokens_in
            if tokens_out:
                self.tokens_total[(r, "out")] = self.tokens_total.get((r, "out"), 0) + tokens_out

    def credential(self, rail: str, outcome: str) -> None:
        key = (_bounded(rail, RAILS), _bounded(outcome, CRED_OUTCOMES))
        with self._lock:
            self.cred_total[key] = self.cred_total.get(key, 0) + 1

    def render(self) -> str:
        lines: list[str] = []
        active = self._gauge_source() if self._gauge_source else {}
        lines += ["# HELP gateway_sessions_active Sessions admitted and neither released nor expired.", "# TYPE gateway_sessions_active gauge"]
        for rail in RAILS:
            lines.append(f"gateway_sessions_active{_fmt_labels({'rail': rail})} {active.get(rail, 0)}")
        with self._lock:
            lines += ["# HELP gateway_sessions_total POST /sessions decisions.", "# TYPE gateway_sessions_total counter"]
            for (rail, role, stack, decision), n in sorted(self.sessions_total.items()):
                lines.append(f"gateway_sessions_total{_fmt_labels({'rail': rail, 'role': role, 'stack': stack, 'decision': decision})} {n}")
            lines += ["# HELP gateway_requests_total Data-plane requests by rail, dialect and response status.", "# TYPE gateway_requests_total counter"]
            for (rail, dialect, status), n in sorted(self.requests_total.items()):
                lines.append(f"gateway_requests_total{_fmt_labels({'rail': rail, 'dialect': dialect, 'status': status})} {n}")
            lines += ["# HELP gateway_upstream_seconds Upstream round-trip (first byte to last byte) per rail.", "# TYPE gateway_upstream_seconds histogram"]
            for rail in sorted(self.upstream_buckets):
                b = self.upstream_buckets[rail]
                for i, le in enumerate(BUCKETS):
                    lines.append(f"gateway_upstream_seconds_bucket{_fmt_labels({'rail': rail, 'le': str(le)})} {b[i]}")
                lines.append(f"gateway_upstream_seconds_bucket{_fmt_labels({'rail': rail, 'le': '+Inf'})} {self.upstream_count[rail]}")
                lines.append(f"gateway_upstream_seconds_sum{_fmt_labels({'rail': rail})} {self.upstream_sum[rail]:.6f}")
                lines.append(f"gateway_upstream_seconds_count{_fmt_labels({'rail': rail})} {self.upstream_count[rail]}")
            lines += ["# HELP gateway_tokens_total Tokens reported by upstream usage, by rail and direction.", "# TYPE gateway_tokens_total counter"]
            for (rail, direction), n in sorted(self.tokens_total.items()):
                lines.append(f"gateway_tokens_total{_fmt_labels({'rail': rail, 'direction': direction})} {n}")
            lines += ["# HELP gateway_credential_resolve_total Credential resolves by rail and outcome.", "# TYPE gateway_credential_resolve_total counter"]
            for (rail, outcome), n in sorted(self.cred_total.items()):
                lines.append(f"gateway_credential_resolve_total{_fmt_labels({'rail': rail, 'outcome': outcome})} {n}")
        return "\n".join(lines) + "\n"
