"""Policy loader + environment (GW-MODEL-RESOLVE, GW-SESSIONS-ADMIT).

`policy.json` is homelab config (a ConfigMap at `/etc/agent-gateway/policy.json`): per-stack
credential refs, per-role allowed rails in preference order, per-(rail,tier) model ids, per-rail
`max_sessions`, the session TTL. The gateway validates the file at load and refuses to start on
an inconsistent one — a typo in policy must never become a silent rail.
"""

from __future__ import annotations

import json
import math
import os
import re
from dataclasses import dataclass, field
from pathlib import Path

RAILS = ("anthropic", "openrouter", "opencode", "codex")
TIERS = ("light", "standard", "heavy")
HARNESSES = ("claude", "opencode", "goose", "codex")
ROLES = ("worker", "reviewer", "coordinator", "responder", "retro", "prober", "researcher")
DIALECTS = ("anthropic", "openai", "responses")

# Which dialect each harness speaks, and which dialects each rail serves (the brief's table).
# `responses` = OpenAI Responses (`/openai/v1/responses`); `openai` stays Chat Completions. Only the
# `codex` rail serves it, and only the `codex` harness speaks it (GW-RAIL-CODEX).
HARNESS_DIALECT = {"claude": "anthropic", "opencode": "openai", "goose": "openai", "codex": "responses"}
RAIL_DIALECTS = {
    "anthropic": ("anthropic",),
    "opencode": ("anthropic", "openai"),
    "openrouter": ("anthropic", "openai"),
    "codex": ("responses",),
}

SELF_URL_DEFAULT = "http://agent-gateway.agent-egress.svc.cluster.local:8080"
UPSTREAM_DEFAULTS = {
    "anthropic": "https://api.anthropic.com",
    "openrouter": "https://openrouter.ai/api",
    "opencode": "https://opencode.ai/zen/go",
    # codex: NO default — the upstream profile (the Codex backend vs the SIWC preview) is unselected
    # (⚑ gap, GW-RAIL-CODEX); an unset CODEX_UPSTREAM leaves the rail without a backend.
    "codex": "",
}


class PolicyError(ValueError):
    pass


RAIL_PREFIX = {"opencode": "opencode-go/", "anthropic": "claude/", "codex": "codex/"}


def wire_model(rail: str, policy_id: str) -> str:
    """The id the harness spells and the rail accepts: the policy id with its rail prefix removed
    (`opencode-go/<id>` → `<id>`, `claude/<alias>` → `<alias>`; openrouter ids are bare) — the same
    strip agents/agent-session.sh performs today (GW-MODEL-RESOLVE)."""
    prefix = RAIL_PREFIX.get(rail)
    if prefix and policy_id.startswith(prefix):
        return policy_id[len(prefix):]
    return policy_id


def model_matches(rail: str, policy_id: str, asked: str, side_models: tuple[str, ...] = ()) -> bool:
    """Does a body's `model` name the session's model? Exact on every rail but `anthropic`, where
    the policy names an alias the claude CLI resolves to a dated id before the request leaves the
    pod (`<alias>` ⊂ `claude-<alias>-<major>-<minor>`), so the check there is by family: the alias
    equals the body's model or is one of its hyphen-separated segments. The rail's `side_models`
    (policy, never code) are admitted the same way on every session of that rail — a harness's
    small side-calls (claude-code's `ANTHROPIC_SMALL_FAST_MODEL`) ride the session's token under
    another family (⚖ GW-MODEL-RESOLVE)."""
    for candidate in (policy_id, *side_models):
        wire = wire_model(rail, candidate)
        if asked == wire:
            return True
        if rail == "anthropic" and wire in asked.split("-"):
            return True
    return False


@dataclass(frozen=True)
class StackPolicy:
    name: str
    loop_ns: str
    openrouter_ref: str | None  # "ns/name"
    anthropic_ref: str | None  # "ns/name"


@dataclass(frozen=True)
class RolePolicy:
    name: str
    rails: tuple[str, ...]
    tier: str
    harness: str


@dataclass(frozen=True)
class PriceRow:
    """$/M tokens per class, the gometer GO_PRICES row shape (`None` cache rate = that class draws 0)."""
    tokens_in: float
    tokens_out: float
    cache_read: float | None = None
    cache_write: float | None = None


@dataclass(frozen=True)
class DrawWindow:
    """One Go subscription window (gometer `_GO_WINDOW_DEFAULTS` shape): a budget, a threshold
    and an anchor — `chain` (opens at the first request after the previous window expired),
    `weekly` (weekday HH:MM UTC) or `monthly` (day-of-month HH:MM UTC)."""
    name: str
    budget_usd: float
    threshold: float  # 0 disables the window
    anchor: str
    span_s: float = 0.0
    chain_lookback_s: float = 7 * 86400
    weekday: int = 0  # Mon = 0 (time.gmtime().tm_wday)
    month_day: int = 1
    hour: int = 0
    minute: int = 0


@dataclass(frozen=True)
class WindowDraw:
    """The Go rail's window draw (gometer `window_draw()` semantics): list rates per class, peak
    rows selected by the REQUEST timestamp, an unpriced model at the conservative fallback row."""
    prices: dict[str, PriceRow]  # policy model id -> off-peak (base) row
    peak_prices: dict[str, PriceRow]  # policy model id -> peak row
    peak_hours_utc: tuple[tuple[int, int], ...]  # half-open [lo, hi) UTC hours
    peak_weekdays: frozenset[int]
    fallback: PriceRow
    windows: tuple[DrawWindow, ...]


@dataclass(frozen=True)
class AdmissionPolicy:
    """`rails.<rail>.admission` — the ladder's capacity half (GW-SESSIONS-ADMIT). Every value is
    policy data with its ⚖ source in the spec row; an absent key = that check is off for the rail."""
    utilization_thresholds: dict[str, float] = field(default_factory=dict)  # subscription window -> fraction (0 = off)
    reading_stale_s: float | None = None  # a window reading older than this is no reading
    latch_429_hold_s: float | None = None  # None = an upstream 429 does not latch this rail
    window_draw: WindowDraw | None = None


@dataclass(frozen=True)
class HeadroomPolicy:
    """The codex rail's account-headroom admission (GW-CODEX-HEADROOM): an observation older than
    `max_age_s` is stale; a window at or above `ceiling` (0–1) is limited; `windows_minutes` is the
    window profile every observation must carry exactly (the fixture profile, not a discovered
    entitlement)."""
    max_age_s: float
    ceiling: float
    windows_minutes: tuple[int, ...]


@dataclass(frozen=True)
class RailPolicy:
    name: str
    max_sessions: int
    models: dict[str, str]  # tier -> the POLICY model id (model-classes.json spelling, rail-prefixed)
    side_models: tuple[str, ...] = ()  # policy ids a harness's side-calls name, admitted on every session of this rail
    admission: AdmissionPolicy = field(default_factory=AdmissionPolicy)
    headroom: HeadroomPolicy | None = None  # codex only (required there)
    refresh_margin_s: float | None = None  # codex only: refresh an OAuth access token this close to expiry


SUBSCRIPTION_WINDOWS = ("5h", "7d")  # the `anthropic-ratelimit-unified-<w>-*` header windows
WEEKDAYS = {"mon": 0, "tue": 1, "wed": 2, "thu": 3, "fri": 4, "sat": 5, "sun": 6}
ANCHORS = ("chain", "weekly", "monthly")


def _keys(where: str, d: dict, allowed: set[str]) -> None:
    """A typo in policy must never become a silently-ignored check: unknown keys refuse the load
    (`_`-prefixed keys are comments)."""
    extra = sorted(k for k in d if not k.startswith("_") and k not in allowed)
    if extra:
        raise PolicyError(f"policy: {where} has unknown key(s) {', '.join(extra)} (known: {', '.join(sorted(allowed))})")


def _num(where: str, v, *, lo: float = 0.0, hi: float | None = None, optional: bool = False) -> float | None:
    if v is None and optional:
        return None
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v < lo or (hi is not None and v > hi):
        rng = f"[{lo}, {hi}]" if hi is not None else f">= {lo}"
        raise PolicyError(f"policy: {where} must be a number {rng}")
    return float(v)


def _price_row(where: str, r) -> PriceRow:
    if not isinstance(r, dict):
        raise PolicyError(f"policy: {where} must be an object {{in, out, cache_read, cache_write}}")
    _keys(where, r, {"in", "out", "cache_read", "cache_write", "peak"})
    return PriceRow(_num(f"{where}.in", r.get("in")), _num(f"{where}.out", r.get("out")),
                    _num(f"{where}.cache_read", r.get("cache_read"), optional=True),
                    _num(f"{where}.cache_write", r.get("cache_write"), optional=True))


def _draw_window(where: str, name: str, w) -> DrawWindow:
    if not isinstance(w, dict):
        raise PolicyError(f"policy: {where} must be an object")
    anchor = w.get("anchor")
    allowed = {"budget_usd", "threshold", "anchor"} | {
        "chain": {"span_s", "chain_lookback_s"}, "weekly": {"weekday", "hour", "minute"},
        "monthly": {"month_day", "hour", "minute"}}.get(anchor, set())
    _keys(where, w, allowed)
    if anchor not in ANCHORS:
        raise PolicyError(f"policy: {where}.anchor must be one of {', '.join(ANCHORS)}")
    budget = _num(f"{where}.budget_usd", w.get("budget_usd"))
    if not budget:
        raise PolicyError(f"policy: {where}.budget_usd must be > 0")
    kw: dict = {}
    if anchor == "chain":
        kw["span_s"] = _num(f"{where}.span_s", w.get("span_s"), lo=1)
        kw["chain_lookback_s"] = _num(f"{where}.chain_lookback_s", w.get("chain_lookback_s", 7 * 86400), lo=1)
    if anchor == "weekly":
        if w.get("weekday") not in WEEKDAYS:
            raise PolicyError(f"policy: {where}.weekday must be one of {', '.join(WEEKDAYS)}")
        kw["weekday"] = WEEKDAYS[w["weekday"]]
    if anchor == "monthly":
        kw["month_day"] = int(_num(f"{where}.month_day", w.get("month_day"), lo=1, hi=31))
    if anchor in ("weekly", "monthly"):
        kw["hour"] = int(_num(f"{where}.hour", w.get("hour", 0), hi=23))
        kw["minute"] = int(_num(f"{where}.minute", w.get("minute", 0), hi=59))
    return DrawWindow(name, budget, _num(f"{where}.threshold", w.get("threshold"), hi=1), anchor, **kw)


def _window_draw(where: str, d) -> WindowDraw:
    if not isinstance(d, dict):
        raise PolicyError(f"policy: {where} must be an object")
    _keys(where, d, {"prices", "fallback", "peak_hours_utc", "peak_weekdays", "windows"})
    prices: dict[str, PriceRow] = {}
    peak: dict[str, PriceRow] = {}
    for model, row in (d.get("prices") or {}).items():
        if model.startswith("_"):
            continue
        prices[model] = _price_row(f"{where}.prices.{model}", row)
        if isinstance(row, dict) and row.get("peak") is not None:
            p = row["peak"]
            if isinstance(p, dict) and "peak" in p:
                raise PolicyError(f"policy: {where}.prices.{model}.peak cannot nest a peak")
            peak[model] = _price_row(f"{where}.prices.{model}.peak", p)
    if "fallback" not in d:
        raise PolicyError(f"policy: {where}.fallback is required (an unpriced model draws at it — fail conservative)")
    hours = d.get("peak_hours_utc") or []
    if not isinstance(hours, list) or any(
            not isinstance(h, list) or len(h) != 2 or not all(isinstance(x, int) and 0 <= x <= 24 for x in h) or h[0] >= h[1]
            for h in hours):
        raise PolicyError(f"policy: {where}.peak_hours_utc must be a list of [lo, hi) UTC hour pairs")
    days = d.get("peak_weekdays") or []
    if not isinstance(days, list) or any(x not in WEEKDAYS for x in days):
        raise PolicyError(f"policy: {where}.peak_weekdays must name weekdays ({', '.join(WEEKDAYS)})")
    if peak and not hours:
        raise PolicyError(f"policy: {where} has peak rows but no peak_hours_utc")
    windows = d.get("windows") or {}
    if not isinstance(windows, dict) or not [k for k in windows if not k.startswith("_")]:
        raise PolicyError(f"policy: {where}.windows must declare at least one window")
    return WindowDraw(
        prices=prices, peak_prices=peak,
        peak_hours_utc=tuple((h[0], h[1]) for h in hours), peak_weekdays=frozenset(WEEKDAYS[x] for x in days),
        fallback=_price_row(f"{where}.fallback", d["fallback"]),
        windows=tuple(_draw_window(f"{where}.windows.{n}", n, w) for n, w in windows.items() if not n.startswith("_")),
    )


def _admission(rail: str, a) -> AdmissionPolicy:
    where = f"rails.{rail}.admission"
    if a is None:
        return AdmissionPolicy()
    if not isinstance(a, dict):
        raise PolicyError(f"policy: {where} must be an object")
    _keys(where, a, {"utilization_thresholds", "reading_stale_s", "latch_429_hold_s", "window_draw"})
    thr = a.get("utilization_thresholds") or {}
    if not isinstance(thr, dict):
        raise PolicyError(f"policy: {where}.utilization_thresholds must be an object {{window: fraction}}")
    _keys(f"{where}.utilization_thresholds", thr, set(SUBSCRIPTION_WINDOWS))
    thresholds = {w: _num(f"{where}.utilization_thresholds.{w}", v, hi=1)
                  for w, v in thr.items() if not w.startswith("_")}
    if thresholds and a.get("reading_stale_s") is None:
        raise PolicyError(f"policy: {where}.reading_stale_s is required with utilization_thresholds "
                          "(a reading must age out — an unavailable reading is no reading)")
    return AdmissionPolicy(
        utilization_thresholds=thresholds,
        reading_stale_s=_num(f"{where}.reading_stale_s", a.get("reading_stale_s"), lo=1, optional=True),
        latch_429_hold_s=_num(f"{where}.latch_429_hold_s", a.get("latch_429_hold_s"), lo=1, optional=True),
        window_draw=_window_draw(f"{where}.window_draw", a["window_draw"]) if a.get("window_draw") is not None else None,
    )


def _finite(v) -> bool:
    return type(v) in (int, float) and math.isfinite(v)


def _codex_policy(r: dict) -> tuple[HeadroomPolicy, float]:
    """The codex rail's two policy blocks; both required — a missing knob never becomes a code default."""
    h = r.get("headroom")
    if not isinstance(h, dict):
        raise PolicyError("policy: rails.codex.headroom {max_age_s, ceiling, windows_minutes} is required")
    max_age, ceiling, windows = h.get("max_age_s"), h.get("ceiling"), h.get("windows_minutes")
    if not _finite(max_age) or max_age <= 0:
        raise PolicyError("policy: rails.codex.headroom.max_age_s must be a positive number")
    if not _finite(ceiling) or not 0 < ceiling <= 1:
        raise PolicyError("policy: rails.codex.headroom.ceiling must be in (0, 1]")
    if (not isinstance(windows, list) or not windows or len(set(windows)) != len(windows)
            or any(type(w) is not int or w <= 0 for w in windows)):
        raise PolicyError("policy: rails.codex.headroom.windows_minutes must be distinct positive integers")
    oauth = r.get("oauth")
    margin = oauth.get("refresh_margin_s") if isinstance(oauth, dict) else None
    if not _finite(margin) or margin < 0:
        raise PolicyError("policy: rails.codex.oauth.refresh_margin_s must be a non-negative number")
    return HeadroomPolicy(float(max_age), float(ceiling), tuple(sorted(windows))), float(margin)


CONTROL_PLANE_AUTH_MODES = ("observe", "enforce")
OUTCOME_GRANTS = ("own", "any")
# A caller key is a ServiceAccount username exactly as a TokenReview names it: a DNS-1123 label
# namespace, a DNS-1123 subdomain name (GW-SESSIONS-AUTH). No wildcard can match this shape.
_CALLER_RE = re.compile(r"^system:serviceaccount:([a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?):([a-z0-9]([-a-z0-9.]*[a-z0-9])?)$")
_NS_RE = re.compile(r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")


@dataclass(frozen=True)
class CallerPolicy:
    """`callers.<system:serviceaccount:ns:sa>` (GW-SESSIONS-AUTH): what that control-plane caller
    may ask for — the stacks and roles of its admissions, and the namespaces a `bind` may name."""
    identity: str
    stacks: frozenset[str]
    roles: frozenset[str]
    bind_namespaces: frozenset[str]
    # GW-SESSIONS-OUTCOME: `own` = report outcomes on the sessions it admitted (the DELETE rule);
    # `any` = a JUDGE — also on any session of its stacks. Optional, default `own` (⚖: absent grants nothing extra).
    outcome: str = "own"


def _callers(d, stacks: dict, roles: dict) -> dict[str, CallerPolicy]:
    """Every entry names exact values the policy knows — no wildcard, no unknown stack or role: a
    typo must never become a silent grant (or a silent denial nobody can read off the policy)."""
    if not isinstance(d, dict):
        raise PolicyError("policy: callers must be an object {system:serviceaccount:<ns>:<sa>: {stacks, roles, bind_namespaces}}")
    out: dict[str, CallerPolicy] = {}
    for ident, c in d.items():
        if ident.startswith("_"):
            continue
        where = f"callers.{ident}"
        if not _CALLER_RE.match(ident):
            raise PolicyError(f"policy: {where} is not a ServiceAccount username system:serviceaccount:<namespace>:<name>")
        if not isinstance(c, dict):
            raise PolicyError(f"policy: {where} must be an object {{stacks, roles, bind_namespaces}}")
        _keys(where, c, {"stacks", "roles", "bind_namespaces", "outcome"})
        outcome = c.get("outcome", "own")
        if outcome not in OUTCOME_GRANTS:
            raise PolicyError(f"policy: {where}.outcome must be one of {', '.join(OUTCOME_GRANTS)}")
        lists = {}
        for key in ("stacks", "roles", "bind_namespaces"):
            v = c.get(key)
            if not isinstance(v, list) or any(not isinstance(x, str) for x in v):
                raise PolicyError(f"policy: {where}.{key} must be a list of strings ([] = none)")
            lists[key] = v
        for st in lists["stacks"]:
            if st not in stacks:
                raise PolicyError(f"policy: {where}.stacks names {st!r}, which is not a policy stack")
        for ro in lists["roles"]:
            if ro not in roles:
                raise PolicyError(f"policy: {where}.roles names {ro!r}, which is not a policy role")
        for ns in lists["bind_namespaces"]:
            if not _NS_RE.match(ns):
                raise PolicyError(f"policy: {where}.bind_namespaces names {ns!r}, which is not a namespace (a DNS-1123 label)")
        out[ident] = CallerPolicy(ident, frozenset(lists["stacks"]), frozenset(lists["roles"]), frozenset(lists["bind_namespaces"]),
                                  outcome)
    return out


@dataclass(frozen=True)
class Policy:
    stacks: dict[str, StackPolicy]
    roles: dict[str, RolePolicy]
    rails: dict[str, RailPolicy]
    session_ttl_s: int
    defer_retry_s: int
    context_tokens: dict[str, int]  # policy model id -> declared harness window; absent = null, never a guess
    raw: dict = field(repr=False, compare=False)
    # GW-SESSIONS-AUTH: who may call the control plane, and whether a caller without a valid token
    # is refused (`enforce`) or admitted, logged and counted (`observe`, the rollout mode).
    control_plane_auth: str = "enforce"
    callers: dict[str, CallerPolicy] = field(default_factory=dict)
    outcome_window_s: int = 86400  # GW-SESSIONS-OUTCOME: how long after a session ends an outcome is accepted

    def context_tokens_for(self, model: str) -> int | None:
        return self.context_tokens.get(model)

    @staticmethod
    def from_dict(d: dict) -> Policy:
        if not isinstance(d, dict):
            raise PolicyError("policy: top level must be an object")
        stacks: dict[str, StackPolicy] = {}
        for name, s in (d.get("stacks") or {}).items():
            if not isinstance(s, dict) or not s.get("loop_ns"):
                raise PolicyError(f"policy: stacks.{name} needs loop_ns")
            for ref_key in ("openrouter_ref", "anthropic_ref"):
                ref = s.get(ref_key)
                if ref is not None and (not isinstance(ref, str) or ref.count("/") != 1):
                    raise PolicyError(f"policy: stacks.{name}.{ref_key} must be 'ns/name'")
            stacks[name] = StackPolicy(name, s["loop_ns"], s.get("openrouter_ref"), s.get("anthropic_ref"))
        ctx_raw = d.get("context_tokens") or {}
        if not isinstance(ctx_raw, dict):
            raise PolicyError("policy: context_tokens must be an object {model id: window}")
        context_tokens = {k: int(v) for k, v in ctx_raw.items() if not k.startswith("_")}
        rails: dict[str, RailPolicy] = {}
        for name, r in (d.get("rails") or {}).items():
            if name not in RAILS:
                raise PolicyError(f"policy: unknown rail {name!r} (known: {', '.join(RAILS)})")
            models = r.get("models") or {}
            for tier, model in models.items():
                if tier not in TIERS or not isinstance(model, str) or not model:
                    raise PolicyError(f"policy: rails.{name}.models.{tier} must name a model for a known tier")
            side = r.get("side_models") or []
            if not isinstance(side, list) or any(not isinstance(m, str) or not m for m in side):
                raise PolicyError(f"policy: rails.{name}.side_models must be a list of model ids")
            headroom, margin = (_codex_policy(r) if name == "codex" else (None, None))
            rails[name] = RailPolicy(name, int(r.get("max_sessions", 0)), dict(models), tuple(side),
                                     _admission(name, r.get("admission")), headroom, margin)
        roles: dict[str, RolePolicy] = {}
        for name, ro in (d.get("roles") or {}).items():
            if name not in ROLES:
                raise PolicyError(f"policy: unknown role {name!r}")
            rl = tuple(ro.get("rails") or ())
            for rail in rl:
                if rail not in rails:
                    raise PolicyError(f"policy: roles.{name}.rails names undeclared rail {rail!r}")
            tier = ro.get("tier", "standard")
            harness = ro.get("harness", "claude")
            if tier not in TIERS:
                raise PolicyError(f"policy: roles.{name}.tier {tier!r} unknown")
            if harness not in HARNESSES:
                raise PolicyError(f"policy: roles.{name}.harness {harness!r} unknown")
            roles[name] = RolePolicy(name, rl, tier, harness)
        # Both control-plane keys are REQUIRED: a policy that says nothing about its callers must
        # not quietly mean "anyone" (or "no one").
        mode = d.get("control_plane_auth")
        if mode not in CONTROL_PLANE_AUTH_MODES:
            raise PolicyError(f"policy: control_plane_auth is required, one of {', '.join(CONTROL_PLANE_AUTH_MODES)}")
        if "callers" not in d:
            raise PolicyError("policy: callers is required ({} = no caller is authorized)")
        callers = _callers(d["callers"], stacks, roles)
        return Policy(
            stacks=stacks,
            roles=roles,
            rails=rails,
            session_ttl_s=int(d.get("session_ttl_s", 14400)),
            defer_retry_s=int(d.get("defer_retry_s", 60)),
            context_tokens=context_tokens,
            raw=d,
            control_plane_auth=mode,
            callers=callers,
            outcome_window_s=int(d.get("outcome_window_s", 86400)),
        )

    @staticmethod
    def load(path: str | Path) -> Policy:
        with open(path, encoding="utf-8") as fh:
            return Policy.from_dict(json.load(fh))


@dataclass(frozen=True)
class Settings:
    policy_path: str
    db_path: str
    self_url: str
    upstreams: dict[str, str]
    opencode_go_api_key: str | None
    cred_cache_s: int
    cred_negative_cache_s: int
    connect_timeout_s: float
    read_timeout_s: float

    @staticmethod
    def from_env(env: dict[str, str] | None = None) -> Settings:
        e = os.environ if env is None else env
        return Settings(
            policy_path=e.get("GATEWAY_POLICY", "/etc/agent-gateway/policy.json"),
            db_path=e.get("GATEWAY_DB", "/data/gateway.db"),
            self_url=e.get("GATEWAY_SELF_URL", SELF_URL_DEFAULT).rstrip("/"),
            upstreams={
                "anthropic": e.get("ANTHROPIC_UPSTREAM", UPSTREAM_DEFAULTS["anthropic"]).rstrip("/"),
                "openrouter": e.get("OPENROUTER_UPSTREAM", UPSTREAM_DEFAULTS["openrouter"]).rstrip("/"),
                "opencode": e.get("OPENCODE_GO_UPSTREAM", UPSTREAM_DEFAULTS["opencode"]).rstrip("/"),
                "codex": e.get("CODEX_UPSTREAM", UPSTREAM_DEFAULTS["codex"]).rstrip("/"),
            },
            opencode_go_api_key=e.get("OPENCODE_GO_API_KEY") or None,
            cred_cache_s=int(e.get("GATEWAY_CRED_CACHE_S", "300")),
            cred_negative_cache_s=int(e.get("GATEWAY_CRED_NEGATIVE_CACHE_S", "20")),
            connect_timeout_s=float(e.get("GATEWAY_CONNECT_TIMEOUT_S", "10")),
            read_timeout_s=float(e.get("GATEWAY_READ_TIMEOUT_S", "600")),
        )
