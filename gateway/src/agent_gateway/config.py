"""Policy loader + environment (GW-MODEL-RESOLVE, GW-SESSIONS-ADMIT).

`policy.json` is homelab config (a ConfigMap at `/etc/agent-gateway/policy.json`): per-stack
credential refs, per-role allowed rails in preference order, per-(rail,tier) model ids, per-rail
`max_sessions`, the session TTL. The gateway validates the file at load and refuses to start on
an inconsistent one — a typo in policy must never become a silent rail.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

RAILS = ("anthropic", "openrouter", "opencode")
TIERS = ("light", "standard", "heavy")
HARNESSES = ("claude", "opencode", "goose", "codex")
ROLES = ("worker", "reviewer", "coordinator", "responder", "retro", "prober", "researcher")
DIALECTS = ("anthropic", "openai")

# Which dialect each harness speaks, and which dialects each rail serves (the brief's table).
HARNESS_DIALECT = {"claude": "anthropic", "opencode": "openai", "goose": "openai", "codex": "openai"}
RAIL_DIALECTS = {
    "anthropic": ("anthropic",),
    "opencode": ("anthropic", "openai"),
    "openrouter": ("anthropic", "openai"),
}

SELF_URL_DEFAULT = "http://agent-gateway.agent-egress.svc.cluster.local:8080"
UPSTREAM_DEFAULTS = {
    "anthropic": "https://api.anthropic.com",
    "openrouter": "https://openrouter.ai/api",
    "opencode": "https://opencode.ai/zen/go",
}


class PolicyError(ValueError):
    pass


RAIL_PREFIX = {"opencode": "opencode-go/", "anthropic": "claude/"}


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
class RailPolicy:
    name: str
    max_sessions: int
    models: dict[str, str]  # tier -> the POLICY model id (model-classes.json spelling, rail-prefixed)
    side_models: tuple[str, ...] = ()  # policy ids a harness's side-calls name, admitted on every session of this rail


@dataclass(frozen=True)
class Policy:
    stacks: dict[str, StackPolicy]
    roles: dict[str, RolePolicy]
    rails: dict[str, RailPolicy]
    session_ttl_s: int
    defer_retry_s: int
    context_tokens: dict[str, int]  # policy model id -> declared harness window; absent = null, never a guess
    raw: dict = field(repr=False, compare=False)

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
            rails[name] = RailPolicy(name, int(r.get("max_sessions", 0)), dict(models), tuple(side))
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
        return Policy(
            stacks=stacks,
            roles=roles,
            rails=rails,
            session_ttl_s=int(d.get("session_ttl_s", 14400)),
            defer_retry_s=int(d.get("defer_retry_s", 60)),
            context_tokens=context_tokens,
            raw=d,
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
            },
            opencode_go_api_key=e.get("OPENCODE_GO_API_KEY") or None,
            cred_cache_s=int(e.get("GATEWAY_CRED_CACHE_S", "300")),
            cred_negative_cache_s=int(e.get("GATEWAY_CRED_NEGATIVE_CACHE_S", "20")),
            connect_timeout_s=float(e.get("GATEWAY_CONNECT_TIMEOUT_S", "10")),
            read_timeout_s=float(e.get("GATEWAY_READ_TIMEOUT_S", "600")),
        )
