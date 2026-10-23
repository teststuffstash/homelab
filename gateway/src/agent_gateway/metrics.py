"""Hand-rolled Prometheus text exposition (GW-METRICS) — bounded label values only.

Families: `gateway_sessions_active{rail}`, `gateway_sessions_total{rail,role,stack,decision}`,
`gateway_requests_total{rail,dialect,status}`, `gateway_upstream_seconds{rail}` (histogram),
`gateway_tokens_total{rail,class}`, `gateway_credential_resolve_total{rail,outcome}`,
`gateway_upstream_auth_rejected_total{rail}` (every upstream 401/403 credential verdict, answered 424 `upstream-auth` —
the rail's credential is bad; every rail renders from 0),
`gateway_control_plane_unauthenticated_total{route,reason}` (GW-SESSIONS-AUTH — every control-plane
request without a valid caller token, admitted under `observe` or refused under `enforce`),
`gateway_subscription_utilization{rail,window}` + `gateway_subscription_reset_seconds{rail,window}`
(gauges, last seen on the subscription rail's `anthropic-ratelimit-unified-*` response headers; on the
codex rail the last ACCEPTED headroom report's windows — GW-CODEX-HEADROOM §Gauges).
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
from .config import DIALECTS, RAILS, ROLES, SUBSCRIPTION_WINDOWS
from .outcomes import OUTCOME_CLASSES  # the one vocabulary (GW-SESSIONS-OUTCOME)

OTHER = "other"
DECISIONS = ("dispatch", "defer")
TOKEN_CLASSES = ("in", "cache_read", "cache_write", "out")
CRED_OUTCOMES = ("resolved", "definitive", "transient")
CP_ROUTES = ("admit", "lookup", "release", "outcome", "list")  # control.ROUTES (not imported: control imports this module)
CP_REASONS = ("absent", "invalid", "review-transient")
INCOMPLETE_REASONS = ("no-terminal", "timeout", "transport-error", "client-closed")
STRIKE_SOURCES = ("outcome", "gateway")
PROBE_OUTCOMES = ("cleared", "rejected", "inconclusive")
# GW-CODEX-HEADROOM §Poll — codex_usage.OUTCOMES (not imported: codex_usage imports nothing from here, but the
# label set is the schema's, spelled once per side like the others)
POLL_OUTCOMES = ("accepted", "quota-invalid", "quota-time-invalid", "quota-out-of-order", "credential-unresolved",
                 "credential-transient", "upstream-auth", "upstream-http-error", "upstream-content-type",
                 "upstream-unreachable", "upstream-timeout")
# GW-CODEX-HEADROOM §Upstream headers — codex_headers.OUTCOMES, spelled once per side like the poll's
HEADROOM_HEADER_OUTCOMES = ("accepted", "absent", "quota-invalid", "quota-time-invalid", "quota-out-of-order")
# GW-RAIL-OPENROUTER: how one attempt on a (rail, model, provider) cell ended — `ok` (a complete 2xx),
# `incomplete` (a 2xx whose body stopped early), the pre-byte failures the gateway fails over on
# (`5xx`, `429`, `unreachable`, `timeout`, `content-type`, `provider-error`), and the request-scoped
# answers it never fails over on (`refused`, `auth`, `edge`).
PROVIDER_OUTCOMES = ("ok", "incomplete", "5xx", "429", "unreachable", "timeout", "content-type", "provider-error",
                     "refused", "auth", "edge")
# GW-MODEL-TIERS §The rail choice: why one rail's twin cell went first — `price` (cheaper per clean ride,
# and by price alone), `clean-rate` (the measured clean rate flipped the price order), `headroom` (the Go
# twin's window holds it), `not-in-catalog` (the Go twin is not priced by the catalog), `no-eligible-endpoint`
# (the openrouter twin has no eligible endpoint to price), `order` (equal costs: the role's rail order).
RAIL_CHOICE_REASONS = ("price", "clean-rate", "headroom", "not-in-catalog", "no-eligible-endpoint", "order")
BUCKETS = (0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600)


def _bounded(value: str, allowed: Iterable[str]) -> str:
    return value if value in allowed else OTHER


def _status_class(status: int) -> str:
    return str(status) if 100 <= status < 600 else OTHER


def window_label(minutes: int) -> str:
    """A headroom window's profile minutes in the `window` vocabulary: a whole number of days renders
    `<n>d`, of hours `<n>h`, else `<n>m` (300 → `5h`, 10080 → `7d`). The policy profile, never a code
    literal, decides which labels exist; one outside the schema's set is bounded to `other` like any
    other label value (GW-CODEX-HEADROOM §Gauges ⚖)."""
    if minutes % 1440 == 0:
        return f"{minutes // 1440}d"
    if minutes % 60 == 0:
        return f"{minutes // 60}h"
    return f"{minutes}m"


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
        self.poll_total: dict[str, int] = {}  # GW-CODEX-HEADROOM §Poll
        self.headroom_header_total: dict[str, int] = {}  # GW-CODEX-HEADROOM §Upstream headers
        self.codex_declared = False  # the family renders only for a declared codex rail (bind_codex_rail)
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
        self.provider_total: dict[tuple[str, str, str, str], int] = {}
        self.failover_total: dict[tuple[str, str, str], int] = {}
        # The two provider families' bounded sets are the POLICY's openrouter models and the endpoint
        # SNAPSHOT's providers (plus `unattributed`) — never a value a response invented.
        self._provider_models: Callable[[], set[str]] = lambda: set()
        self._provider_slugs: Callable[[], set[str]] = lambda: set()
        self._gauge_source: Callable[[], dict[str, int]] | None = None
        self._cooled_source: Callable[[], dict[str, int]] | None = None
        self._rejected_source: Callable[[], dict[str, int]] | None = None
        self._extra: list[Callable[[], list[str]]] = []
        # GW-MODEL-TIERS: the rail choice's counter (model bounded like the provider families) and the
        # mounted tier-evidence snapshot's age (None = none mounted — no series).
        self._rail_choices: dict[tuple[str, str, str], int] = {}
        self._tier_evidence_age: Callable[[], float | None] = lambda: None

    def bind_active_sessions(self, source: Callable[[], dict[str, int]]) -> None:
        self._gauge_source = source

    def bind_transport_facts(self, cooled: Callable[[], dict[str, int]], rejected: Callable[[], dict[str, int]]) -> None:
        """The capacity state's two gauges (sessions.md §Capacity): cooled cells, rejected credentials."""
        self._cooled_source, self._rejected_source = cooled, rejected

    def bind_provider_bounds(self, models: Callable[[], set[str]], providers: Callable[[], set[str]]) -> None:
        self._provider_models, self._provider_slugs = models, providers

    def provider_request(self, rail: str, model: str, provider: str, outcome: str) -> None:
        """One attempt on a cell (GW-RAIL-OPENROUTER): `model` is the wire id (bounded to the policy's
        openrouter models), `provider` the snapshot's slug (or `unattributed`)."""
        key = (_bounded(rail, RAILS), _bounded(model, self._provider_models()),
               _bounded(provider, self._provider_slugs() | {"unattributed"}), _bounded(outcome, PROVIDER_OUTCOMES))
        with self._lock:
            self.provider_total[key] = self.provider_total.get(key, 0) + 1

    def rail_choice(self, model: str, rail: str, reason: str) -> None:
        """GW-MODEL-TIERS §The rail choice: one admission chose `rail` for the twin `model` (its
        openrouter spelling — the same bound as the provider families) for `reason`."""
        key = (_bounded(model, self._provider_models()), _bounded(rail, RAILS), _bounded(reason, RAIL_CHOICE_REASONS))
        with self._lock:
            self._rail_choices[key] = self._rail_choices.get(key, 0) + 1

    def bind_tier_evidence(self, age: Callable[[], float | None]) -> None:
        """GW-MODEL-TIERS: seconds since the mounted tier-evidence snapshot's `snapshot_at` (None = none mounted)."""
        self._tier_evidence_age = age

    def failover(self, model: str, frm: str, to: str) -> None:
        slugs = self._provider_slugs()
        key = (_bounded(model, self._provider_models()), _bounded(frm, slugs), _bounded(to, slugs))
        with self._lock:
            self.failover_total[key] = self.failover_total.get(key, 0) + 1

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

    def subscription_report(self, rail: str, windows: Iterable) -> None:
        """GW-CODEX-HEADROOM §Gauges: an ACCEPTED headroom report's normalised windows (`minutes`,
        `used` 0–1, `resets_at`) set the same two gauges the subscription rail renders from headers;
        the caller (headroom's `on_accept`) never fires for a refused report, so a refusal changes
        nothing here."""
        r = _bounded(rail, RAILS)
        with self._lock:
            for w in windows:
                label = _bounded(window_label(w.minutes), SUBSCRIPTION_WINDOWS)
                self.sub_util[(r, label)] = w.used
                self.sub_reset[(r, label)] = w.resets_at

    def credential(self, rail: str, outcome: str) -> None:
        key = (_bounded(rail, RAILS), _bounded(outcome, CRED_OUTCOMES))
        with self._lock:
            self.cred_total[key] = self.cred_total.get(key, 0) + 1

    def bind_codex_rail(self, declared: bool) -> None:
        """GW-CODEX-HEADROOM §Poll: `gateway_codex_usage_poll_total` exists only while the policy declares the
        codex rail — an undeclared rail renders no series, so CodexUsagePollSilent cannot fire on it."""
        self.codex_declared = declared

    def codex_poll(self, outcome: str) -> None:
        """GW-CODEX-HEADROOM §Poll: one usage poll's bounded outcome (`accepted` = a report the headroom took)."""
        o = _bounded(outcome, POLL_OUTCOMES)
        with self._lock:
            self.poll_total[o] = self.poll_total.get(o, 0) + 1

    def codex_upstream_headroom(self, outcome: str) -> None:
        """GW-CODEX-HEADROOM §Upstream headers: one relayed answer's headroom-header read (`accepted` = a
        report the headroom took, `absent` = no window header on the answer)."""
        o = _bounded(outcome, HEADROOM_HEADER_OUTCOMES)
        with self._lock:
            self.headroom_header_total[o] = self.headroom_header_total.get(o, 0) + 1

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
            # Only for a DECLARED codex rail (bind_codex_rail): an undeclared rail renders no series at all, so the
            # silent-poll alert cannot fire on it. Once declared, every outcome renders from 0 (the alerts read
            # increase(): a fresh pod's first `accepted` must count).
            if self.codex_declared:
                lines += ["# HELP gateway_codex_usage_poll_total The codex rail's usage polls by outcome (GW-CODEX-HEADROOM §Poll); accepted = the headroom took the report.",
                          "# TYPE gateway_codex_usage_poll_total counter"]
                for outcome in POLL_OUTCOMES:
                    lines.append(f"gateway_codex_usage_poll_total{_fmt_labels({'outcome': outcome})} {self.poll_total.get(outcome, 0)}")
                lines += ["# HELP gateway_codex_upstream_headroom_total The codex rail's relayed answers read for their x-codex-* headroom headers, by outcome (GW-CODEX-HEADROOM §Upstream headers); accepted = the headroom took the report, absent = no window header.",
                          "# TYPE gateway_codex_upstream_headroom_total counter"]
                for outcome in HEADROOM_HEADER_OUTCOMES:
                    lines.append(f"gateway_codex_upstream_headroom_total{_fmt_labels({'outcome': outcome})} {self.headroom_header_total.get(outcome, 0)}")
            lines += ["# HELP gateway_requests_incomplete_total 2xx answers whose body stopped before its end, by reason.",
                      "# TYPE gateway_requests_incomplete_total counter"]
            for (rail, dialect, reason), n in sorted(self.incomplete_total.items()):
                lines.append(f"gateway_requests_incomplete_total{_fmt_labels({'rail': rail, 'dialect': dialect, 'reason': reason})} {n}")
            lines += ["# HELP gateway_strikes_total Strikes written to the store, by class and source (outcome = the consumer, gateway = a transport fact).",
                      "# TYPE gateway_strikes_total counter"]
            for (klass, source), n in sorted(self.strikes_total.items()):
                lines.append(f"gateway_strikes_total{_fmt_labels({'class': klass, 'source': source})} {n}")
            lines += ["# HELP gateway_provider_requests_total Attempts on a (rail, model, provider) cell by how they ended (GW-RAIL-OPENROUTER).",
                      "# TYPE gateway_provider_requests_total counter"]
            for (rail, model, provider, outcome), n in sorted(self.provider_total.items()):
                lines.append(f"gateway_provider_requests_total{_fmt_labels({'rail': rail, 'model': model, 'provider': provider, 'outcome': outcome})} {n}")
            lines += ["# HELP gateway_provider_failovers_total Requests reissued to the next provider before the first byte (GW-RAIL-OPENROUTER).",
                      "# TYPE gateway_provider_failovers_total counter"]
            for (model, frm, to), n in sorted(self.failover_total.items()):
                lines.append(f"gateway_provider_failovers_total{_fmt_labels({'model': model, 'from': frm, 'to': to})} {n}")
            lines += ["# HELP gateway_rail_choice_total Admissions where the tier named one model on two allowed rails, by the rail chosen and why (GW-MODEL-TIERS).",
                      "# TYPE gateway_rail_choice_total counter"]
            for (model, rail, reason), n in sorted(self._rail_choices.items()):
                lines.append(f"gateway_rail_choice_total{_fmt_labels({'model': model, 'rail': rail, 'reason': reason})} {n}")
            lines += ["# HELP gateway_tier_evidence_age_seconds Seconds since the mounted tier-evidence snapshot's snapshot_at (absent: none mounted) (GW-MODEL-TIERS).",
                      "# TYPE gateway_tier_evidence_age_seconds gauge"]
            age = self._tier_evidence_age()
            if age is not None:
                lines.append(f"gateway_tier_evidence_age_seconds {age:.0f}")
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
