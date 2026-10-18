"""Hand-rolled Prometheus text exposition (GW-METRICS) — bounded label values only.

Families: `gateway_sessions_active{rail}`, `gateway_sessions_total{rail,role,stack,decision}`,
`gateway_requests_total{rail,dialect,status}`, `gateway_upstream_seconds{rail}` (histogram),
`gateway_tokens_total{rail,class}`, `gateway_credential_resolve_total{rail,outcome}`,
`gateway_upstream_auth_rejected_total{rail}` (every upstream 401/403 credential verdict, answered 424 `upstream-auth` —
the rail's credential is bad; every rail renders from 0),
`gateway_control_plane_unauthenticated_total{route,reason}` (GW-SESSIONS-AUTH — every control-plane
request without a valid caller token, admitted under `observe` or refused under `enforce`),
`gateway_subscription_utilization{rail,window}` + `gateway_subscription_reset_seconds{rail,window}`
(gauges, last seen on the subscription rail's `anthropic-ratelimit-unified-*` response headers).
`gateway_cells_cooled{rail}` + `gateway_credentials_rejected{rail}` (gauges — the admission's transport
facts, sessions.md §Capacity) and `gateway_requests_incomplete_total{rail,dialect,reason}` (a 2xx whose
body stopped before its end, GW-RAIL-*).
A label value outside its declared set renders as `other` — a task key, a session id or a model
string can never become a series (cardinality is a policy decision, not a request's).
"""

from __future__ import annotations

import threading
from collections.abc import Callable, Iterable

from .capacity import subscription_windows  # one parser for the gauges and the admission reading
from .config import DIALECTS, RAILS, ROLES
from .outcomes import OUTCOME_CLASSES  # the one vocabulary (GW-SESSIONS-OUTCOME)

OTHER = "other"
DECISIONS = ("dispatch", "defer")
TOKEN_CLASSES = ("in", "cache_read", "cache_write", "out")
CRED_OUTCOMES = ("resolved", "definitive", "transient")
CP_ROUTES = ("admit", "lookup", "release", "outcome")  # control.ROUTES (not imported: control imports this module)
CP_REASONS = ("absent", "invalid", "review-transient")
INCOMPLETE_REASONS = ("no-terminal", "timeout", "transport-error", "client-closed")
STRIKE_SOURCES = ("outcome", "gateway")
PROBE_OUTCOMES = ("cleared", "rejected", "inconclusive")
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
        self.upstream_auth_total: dict[str, int] = {}
        self.cp_unauth_total: dict[tuple[str, str], int] = {}
        self.sub_util: dict[tuple[str, str], float] = {}
        self.sub_reset: dict[tuple[str, str], float] = {}
        self.upstream_buckets: dict[str, list[int]] = {}
        self.upstream_sum: dict[str, float] = {}
        self.upstream_count: dict[str, int] = {}
        self.incomplete_total: dict[tuple[str, str, str], int] = {}
        self.strikes_total: dict[tuple[str, str], int] = {}
        self.probe_total: dict[tuple[str, str], int] = {}
        self.reaped_total: dict[str, int] = {}
        self._gauge_source: Callable[[], dict[str, int]] | None = None
        self._cooled_source: Callable[[], dict[str, int]] | None = None
        self._rejected_source: Callable[[], dict[str, int]] | None = None
        self._extra: list[Callable[[], list[str]]] = []

    def bind_active_sessions(self, source: Callable[[], dict[str, int]]) -> None:
        self._gauge_source = source

    def bind_transport_facts(self, cooled: Callable[[], dict[str, int]], rejected: Callable[[], dict[str, int]]) -> None:
        """The capacity state's two gauges (sessions.md §Capacity): cooled cells, rejected credentials."""
        self._cooled_source, self._rejected_source = cooled, rejected

    def strike(self, klass: str, source: str) -> None:
        key = (_bounded(klass, tuple(OUTCOME_CLASSES)), _bounded(source, STRIKE_SOURCES))
        with self._lock:
            self.strikes_total[key] = self.strikes_total.get(key, 0) + 1
    def session_reaped(self, rail: str) -> None:
        r = _bounded(rail, RAILS)
        with self._lock:
            self.reaped_total[r] = self.reaped_total.get(r, 0) + 1

    def credential_probe(self, rail: str, outcome: str) -> None:
        key = (_bounded(rail, RAILS), _bounded(outcome, PROBE_OUTCOMES))
        with self._lock:
            self.probe_total[key] = self.probe_total.get(key, 0) + 1

    def request_incomplete(self, rail: str, dialect: str, reason: str) -> None:
        key = (_bounded(rail, RAILS), _bounded(dialect, DIALECTS), _bounded(reason, INCOMPLETE_REASONS))
        with self._lock:
            self.incomplete_total[key] = self.incomplete_total.get(key, 0) + 1

    def bind_extra(self, render: Callable[[], list[str]]) -> None:
        """A module that owns its own families renders them here (the Go catalog — GW-CATALOG-GO)."""
        self._extra.append(render)

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

    def tokens(self, rail: str, usage) -> None:
        r = _bounded(rail, RAILS)
        counts = {"in": usage.tokens_in, "cache_read": usage.tokens_cache_read,
                  "cache_write": usage.tokens_cache_write, "out": usage.tokens_out}
        with self._lock:
            for cls, n in counts.items():
                if n:
                    self.tokens_total[(r, cls)] = self.tokens_total.get((r, cls), 0) + n

    def subscription_windows(self, rail: str, headers) -> None:
        """Last-seen 5h/7d utilization (0–1) + reset epoch from `anthropic-ratelimit-unified-<w>-*`;
        a window with an absent or malformed field is left as it was (no guessing)."""
        r = _bounded(rail, RAILS)
        for w, (util, reset) in subscription_windows(headers).items():
            with self._lock:
                self.sub_util[(r, w)] = util
                self.sub_reset[(r, w)] = reset

    def credential(self, rail: str, outcome: str) -> None:
        key = (_bounded(rail, RAILS), _bounded(outcome, CRED_OUTCOMES))
        with self._lock:
            self.cred_total[key] = self.cred_total.get(key, 0) + 1

    def upstream_auth_rejected(self, rail: str) -> None:
        """The upstream answered 401/403 to the gateway's own credential (502 `upstream-auth`)."""
        r = _bounded(rail, RAILS)
        with self._lock:
            self.upstream_auth_total[r] = self.upstream_auth_total.get(r, 0) + 1

    def control_plane_unauthenticated(self, route: str, reason: str) -> None:
        key = (_bounded(route, CP_ROUTES), _bounded(reason, CP_REASONS))
        with self._lock:
            self.cp_unauth_total[key] = self.cp_unauth_total.get(key, 0) + 1

    def render(self) -> str:
        lines: list[str] = []
        active = self._gauge_source() if self._gauge_source else {}
        cooled = self._cooled_source() if self._cooled_source else {}
        rejected = self._rejected_source() if self._rejected_source else {}
        # Every rail renders, zeros included (an absent series reads as "never scraped", not "none").
        lines += ["# HELP gateway_cells_cooled (rail, model) cells an upstream 429 cooled, until their reset — admission skips them.",
                  "# TYPE gateway_cells_cooled gauge"]
        lines += [f"gateway_cells_cooled{_fmt_labels({'rail': rail})} {cooled.get(rail, 0)}" for rail in RAILS]
        lines += ["# HELP gateway_credentials_rejected Rail credentials an upstream 401/403 rejected, until a 2xx on them or a new credential.",
                  "# TYPE gateway_credentials_rejected gauge"]
        lines += [f"gateway_credentials_rejected{_fmt_labels({'rail': rail})} {rejected.get(rail, 0)}" for rail in RAILS]
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
            lines += ["# HELP gateway_tokens_total Tokens reported by upstream usage, by rail and class (in = uncached input).", "# TYPE gateway_tokens_total counter"]
            for (rail, cls), n in sorted(self.tokens_total.items()):
                lines.append(f"gateway_tokens_total{_fmt_labels({'rail': rail, 'class': cls})} {n}")
            lines += ["# HELP gateway_subscription_utilization Last-seen subscription window utilization (0-1) per rail and window.", "# TYPE gateway_subscription_utilization gauge"]
            for (rail, w), v in sorted(self.sub_util.items()):
                lines.append(f"gateway_subscription_utilization{_fmt_labels({'rail': rail, 'window': w})} {v:g}")
            lines += ["# HELP gateway_subscription_reset_seconds Last-seen subscription window reset time (unix seconds).", "# TYPE gateway_subscription_reset_seconds gauge"]
            for (rail, w), v in sorted(self.sub_reset.items()):
                lines.append(f"gateway_subscription_reset_seconds{_fmt_labels({'rail': rail, 'window': w})} {v:.0f}")
            lines += ["# HELP gateway_credential_resolve_total Credential resolves by rail and outcome.", "# TYPE gateway_credential_resolve_total counter"]
            for (rail, outcome), n in sorted(self.cred_total.items()):
                lines.append(f"gateway_credential_resolve_total{_fmt_labels({'rail': rail, 'outcome': outcome})} {n}")
            # Every rail renders, zeros included: the alert reads increase(), and a series born at 1 on
            # a fresh pod would hide its first rejection from it.
            lines += ["# HELP gateway_upstream_auth_rejected_total Upstream 401/403 credential verdicts on the gateway's rail credential (answered 424 upstream-auth), per rail.",
                      "# TYPE gateway_upstream_auth_rejected_total counter"]
            for rail in RAILS:
                lines.append(f"gateway_upstream_auth_rejected_total{_fmt_labels({'rail': rail})} {self.upstream_auth_total.get(rail, 0)}")
            lines += ["# HELP gateway_requests_incomplete_total 2xx answers whose body stopped before its end, by reason.",
                      "# TYPE gateway_requests_incomplete_total counter"]
            for (rail, dialect, reason), n in sorted(self.incomplete_total.items()):
                lines.append(f"gateway_requests_incomplete_total{_fmt_labels({'rail': rail, 'dialect': dialect, 'reason': reason})} {n}")
            lines += ["# HELP gateway_strikes_total Strikes written to the store, by class and source (outcome = the consumer, gateway = a transport fact).",
                      "# TYPE gateway_strikes_total counter"]
            for (klass, source), n in sorted(self.strikes_total.items()):
                lines.append(f"gateway_strikes_total{_fmt_labels({'class': klass, 'source': source})} {n}")
            lines += ["# HELP gateway_sessions_reaped_total Sessions released because their pod was gone (GW-SESSIONS-LIVENESS).",
                      "# TYPE gateway_sessions_reaped_total counter"]
            lines += [f"gateway_sessions_reaped_total{_fmt_labels({'rail': rail})} {self.reaped_total.get(rail, 0)}" for rail in RAILS]
            lines += ["# HELP gateway_credential_probes_total Re-verifications of a rejected rail credential, by outcome.",
                      "# TYPE gateway_credential_probes_total counter"]
            for (rail, outcome), n in sorted(self.probe_total.items()):
                lines.append(f"gateway_credential_probes_total{_fmt_labels({'rail': rail, 'outcome': outcome})} {n}")
            # Every (route, reason) renders, zeros included: the flip's soak reads a flat series, and
            # an absent series cannot be told apart from a scrape that never saw the family.
            lines += ["# HELP gateway_control_plane_unauthenticated_total Control-plane requests without a valid caller token (admitted under observe, refused under enforce).",
                      "# TYPE gateway_control_plane_unauthenticated_total counter"]
            for route in CP_ROUTES:
                for reason in CP_REASONS:
                    n = self.cp_unauth_total.get((route, reason), 0)
                    lines.append(f"gateway_control_plane_unauthenticated_total{_fmt_labels({'route': route, 'reason': reason})} {n}")
        for render in self._extra:
            lines += render()
        return "\n".join(lines) + "\n"
