"""The control plane: POST/GET/DELETE /sessions (GW-SESSIONS-ADMIT, -ENV, -TOKEN, -RELEASE).

`POST /sessions` is the launcher's one question: may this unit run now, with which harness, and
what goes in the pod's env. `decision: defer` is a normal 200 answer (typed reason + retry_after_s),
never an HTTP error; the HTTP errors are 400 (malformed body, harness×rail mismatch) and 503
(the kube API away while resolving a credential). Shapes: specs/endpoints/sessions.schema.json.
"""

from __future__ import annotations

import hashlib
import json
import logging
import math
import secrets
import time
import uuid
from dataclasses import dataclass

from starlette.requests import Request
from starlette.responses import JSONResponse

from .capacity import Capacity
from .config import (
    HARNESS_DIALECT,
    HARNESSES,
    RAIL_DIALECTS,
    RAILS,
    TIERS,
    Policy,
    RolePolicy,
    StackPolicy,
    wire_model,
)
from .credentials import CredentialResolver, CredentialTransient, CredentialUnresolved
from .metrics import Metrics
from .store import Session, Store, iso

log = logging.getLogger("gateway.sessions")

TOKEN_PREFIX = "gws_"
TOKEN_CHARS = 32  # url-safe chars after the prefix


def new_token() -> str:
    tok = secrets.token_urlsafe(TOKEN_CHARS)[:TOKEN_CHARS]
    return TOKEN_PREFIX + tok


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def error(status: int, code: str, message: str, headers: dict[str, str] | None = None) -> JSONResponse:
    """The schemas' error envelope: {error: {code, message}} — one line, never a credential value."""
    return JSONResponse({"error": {"code": code, "message": message}}, status_code=status, headers=headers)


class BadRequest(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(frozen=True)
class Admission:
    stack: StackPolicy
    role: RolePolicy
    task: str
    round: int
    tier: str
    harness: str
    rail_override: str | None


def parse_admission(policy: Policy, body: object) -> Admission:
    """Validate the body against `post.input`; every shape miss is 400 `malformed-body` (the
    message says which), an explicit harness×rail whose dialects do not meet is 400
    `harness-rail-mismatch` (`codex` speaks `responses`, which only the `codex` rail serves)."""
    if not isinstance(body, dict):
        raise BadRequest("malformed-body", "body must be a JSON object")
    for key in ("stack", "role", "task"):
        v = body.get(key)
        if not isinstance(v, str) or not v:
            raise BadRequest("malformed-body", f"{key} is required (non-empty string)")
    role_name = body["role"]
    if role_name not in policy.roles:
        raise BadRequest("malformed-body", f"role {role_name!r} is not in the role enum / policy")
    role = policy.roles[role_name]
    rnd = body.get("round", 0)
    if not isinstance(rnd, int) or isinstance(rnd, bool) or rnd < 0:
        raise BadRequest("malformed-body", "round must be a non-negative integer")
    tier = body.get("tier", role.tier)
    if tier not in TIERS:
        raise BadRequest("malformed-body", f"tier {tier!r} is not one of {', '.join(TIERS)}")
    harness = body.get("harness", role.harness)
    if harness not in HARNESSES:
        raise BadRequest("malformed-body", f"harness {harness!r} is not one of {', '.join(HARNESSES)}")
    rail = body.get("rail")
    if rail is not None and rail not in RAILS:
        raise BadRequest("malformed-body", f"rail {rail!r} is not one of {', '.join(RAILS)}")
    if rail is not None and HARNESS_DIALECT[harness] not in RAIL_DIALECTS[rail]:
        raise BadRequest(
            "harness-rail-mismatch",
            f"harness {harness} speaks {HARNESS_DIALECT[harness]}; rail {rail} serves {', '.join(RAIL_DIALECTS[rail])}",
        )
    # stack-unknown is a DEFER (typed), not a 400 — the body is well-formed, the policy just does
    # not know the stack. Carry the name through for the defer answer.
    stack = policy.stacks.get(body["stack"]) or StackPolicy(body["stack"], "", None, None)
    return Admission(stack, role, body["task"], rnd, tier, harness, rail)


def assemble_env(self_url: str, harness: str, token: str, wire: str) -> dict[str, str]:
    """The pod's complete LLM env for `harness`, pointing at THIS gateway (GW-SESSIONS-ENV).

    `claude` gets exactly ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN / ANTHROPIC_MODEL (the names
    agents/agent-session.sh renders today). The openai-dialect harnesses get what their PINNED CLI
    was observed to read (agent-base 2026.10.15, in-cluster probe 2026-10-17 — the specs rows):
    goose 1.49.0 reads OPENAI_BASE_URL / OPENAI_API_KEY / GOOSE_MODEL only once GOOSE_PROVIDER
    names the openai provider; opencode 1.18.35 ignores OPENCODE_MODEL and its built-in openai
    provider speaks /responses, so it gets ONE var — OPENCODE_CONFIG_CONTENT, an
    openai-compatible provider block carrying the base url, the token and the model.
    """
    if harness == "claude":
        return {
            "ANTHROPIC_BASE_URL": f"{self_url}/anthropic",
            "ANTHROPIC_AUTH_TOKEN": token,
            "ANTHROPIC_MODEL": wire,
        }
    if harness == "opencode":
        return {"OPENCODE_CONFIG_CONTENT": json.dumps(opencode_config(f"{self_url}/openai/v1", token, wire), separators=(",", ":"))}
    env = {"OPENAI_BASE_URL": f"{self_url}/openai/v1", "OPENAI_API_KEY": token}
    if harness == "codex":
        # The CLI reads neither the base URL nor the model from env (observed 0.161.0, compat.py):
        # its `[model_providers.<id>]` block does — base_url, wire_api = "responses",
        # env_key = "OPENAI_API_KEY" — rendered by the harness wrapper FROM these values (⚖).
        env["CODEX_MODEL"] = wire
    elif harness == "goose":
        env["GOOSE_PROVIDER"] = "openai"
        env["GOOSE_MODEL"] = wire
    return env


OPENCODE_PROVIDER_ID = "gateway"


def opencode_config(base_url: str, token: str, wire: str) -> dict:
    """The opencode session config (GW-SESSIONS-ENV): one openai-compatible provider pointing at
    this gateway, the session token as its key, the wire id as BOTH the main and the small
    (title) model — every request is resolved to the session's model anyway (GW-MODEL-RESOLVE)."""
    model = f"{OPENCODE_PROVIDER_ID}/{wire}"
    return {
        "$schema": "https://opencode.ai/config.json",
        "model": model,
        "small_model": model,
        "provider": {
            OPENCODE_PROVIDER_ID: {
                "npm": "@ai-sdk/openai-compatible",
                "options": {"baseURL": base_url, "apiKey": token},
                "models": {wire: {}},
            }
        },
    }


class SessionService:
    def __init__(
        self, policy: Policy, store: Store, resolver: CredentialResolver, metrics: Metrics, self_url: str, clock=time.time,
        capacity: Capacity | None = None,
    ):
        self.policy = policy
        self.store = store
        self.capacity = capacity or Capacity(policy, store)
        self.resolver = resolver
        self.metrics = metrics
        self.self_url = self_url
        self.clock = clock
        self.codex = None  # a codex.CodexRail when the policy declares the rail (GW-CODEX-HEADROOM)

    async def admit(self, adm: Admission) -> JSONResponse:
        """The rail pick: first allowed rail that (a) the harness can speak, (b) names a model for the
        tier, (c) has a free slot, (d) is not capacity-blocked (window utilization / 429 latch /
        window draw — capacity.py), (e) has a resolvable credential for the stack. A TRANSIENT
        credential fault stops the walk with 503 — the kube API being away is not a verdict. A walk
        that finds no rail defers with the reason and `retry_after_s` of the blocked rail that frees
        FIRST (a full rail frees after the policy's `defer_retry_s`)."""
        if adm.stack.name not in self.policy.stacks:
            return self._defer(adm, "stack-unknown", f"stack {adm.stack.name!r} is not in policy")
        if adm.rail_override:
            log.info("session: explicit rail override %s for %s/%s (operator)", adm.rail_override, adm.stack.name, adm.task)
            if adm.rail_override not in adm.role.rails:
                return self._defer(adm, "role-rail-denied", f"role {adm.role.name} may not ride rail {adm.rail_override}")
            candidates = [adm.rail_override]
        else:
            candidates = [r for r in adm.role.rails if HARNESS_DIALECT[adm.harness] in RAIL_DIALECTS[r]]
            if not candidates:
                return self._defer(adm, "role-rail-denied", f"no rail allowed for role {adm.role.name} serves harness {adm.harness}")
        capacity_blocked: list[tuple[str, str, float, str]] = []  # (rail, reason, free_at, detail)
        cred_blocked: list[str] = []
        now = self.clock()
        for rail in candidates:
            rp = self.policy.rails[rail]
            model = rp.models.get(adm.tier)
            if not model:
                log.info("session: rail %s has no model for tier %s — skipped", rail, adm.tier)
                continue
            if self.store.active_count(rail, now) >= rp.max_sessions:
                capacity_blocked.append((rail, "rail-capacity", now + self.policy.defer_retry_s, f"{rail} at max_sessions"))
                continue
            block = self.capacity.blocked(rail, now)
            if block is not None:
                log.info("session: rail %s capacity-blocked (%s) until %s — skipped", rail, block.detail, iso(block.free_at))
                capacity_blocked.append((rail, block.reason, block.free_at, block.detail))
                continue
            if rail == "codex":  # the codex rail's own gate (GW-CODEX-HEADROOM) — no Secret ref to resolve
                blocked = self.codex.admission(self.policy.defer_retry_s) if self.codex else ("credential-unresolved", 0)
                if blocked is None:
                    self.metrics.credential(rail, "resolved")
                    return self._dispatch(adm, rail, model, now)
                if blocked[0] == "credential-transient":
                    self.metrics.credential(rail, "transient")
                    return error(503, "credential-transient", "the codex credential store does not answer — retry",
                                 headers={"retry-after": str(self.policy.defer_retry_s)})
                if blocked[0] == "credential-unresolved":
                    self.metrics.credential(rail, "definitive")
                    cred_blocked.append(rail)
                else:  # a quota-* headroom verdict joins the "frees first" race like any capacity block
                    capacity_blocked.append((rail, blocked[0], now + blocked[1], f"codex headroom {blocked[0]}"))
                continue
            try:
                await self.resolver.resolve(rail, adm.stack)
            except CredentialTransient as e:
                self.metrics.credential(rail, "transient")
                log.warning("session: credential-transient on rail %s for stack %s: %s", rail, adm.stack.name, e)
                return error(503, "credential-transient", f"kube API failed resolving the {rail} credential — retry",
                             headers={"retry-after": str(self.resolver.negative_cache_s)})
            except CredentialUnresolved:
                cred_blocked.append(rail)
                self.metrics.credential(rail, "definitive")
                continue
            self.metrics.credential(rail, "resolved")
            return self._dispatch(adm, rail, model, now)
        if capacity_blocked:
            rail, reason, free_at, _ = min(capacity_blocked, key=lambda b: b[2])  # ties: walk order (min is stable)
            return self._defer(adm, reason, "every allowed rail is blocked: " + "; ".join(b[3] for b in capacity_blocked),
                               retry_after_s=max(1, math.ceil(free_at - now)))
        if cred_blocked:
            return self._defer(adm, "credential-unresolved",
                               f"no allowed rail has a resolvable credential for stack {adm.stack.name}: {', '.join(cred_blocked)}")
        return self._defer(adm, "role-rail-denied", f"no allowed rail of role {adm.role.name} names a model for tier {adm.tier}")

    def _defer(self, adm: Admission, reason: str, detail: str, retry_after_s: int | None = None) -> JSONResponse:
        self.metrics.session_decision("none", adm.role.name, adm.stack.name, "defer")
        retry = retry_after_s if retry_after_s is not None else self.policy.defer_retry_s
        log.info("session: defer %s retry_after_s=%d stack=%s role=%s task=%s — %s",
                 reason, retry, adm.stack.name, adm.role.name, adm.task, detail)
        return JSONResponse({"decision": "defer", "reason": reason, "retry_after_s": retry})

    def _dispatch(self, adm: Admission, rail: str, model: str, now: float) -> JSONResponse:
        token = new_token()
        sid = uuid.uuid4().hex
        row = self.store.create_session(
            id=sid, token_hash=token_hash(token), stack=adm.stack.name, role=adm.role.name, task=adm.task,
            round=adm.round, rail=rail, harness=adm.harness, model=model,
            created_at=now, expires_at=now + self.policy.session_ttl_s,
        )
        self.metrics.session_decision(rail, adm.role.name, adm.stack.name, "dispatch")
        log.info("session: dispatch id=%s stack=%s role=%s task=%s rail=%s harness=%s model=%s",
                 sid, adm.stack.name, adm.role.name, adm.task, rail, adm.harness, model)
        return JSONResponse({
            "decision": "dispatch",
            "session": {"id": row.id, "token": token, "expires_at": iso(row.expires_at)},
            "rail": rail,
            "harness": adm.harness,
            "model": model,
            "env": assemble_env(self.self_url, adm.harness, token, wire_model(rail, model)),
            "context_tokens": self.policy.context_tokens_for(model),
        })

    def authenticate(self, token: str | None) -> tuple[Session | None, str | None]:
        """Data-plane auth: (session, None) or (None, typed 401 code)."""
        if not token or not token.startswith(TOKEN_PREFIX):
            return None, "session-unknown"
        row = self.store.get_by_token_hash(token_hash(token))
        if row is None:
            return None, "session-unknown"
        state = row.state(self.clock())
        if state == "released":
            return row, "session-released"
        if state == "expired":
            return row, "session-expired"
        return row, None


# -- Starlette endpoints ------------------------------------------------------------------------

async def post_sessions(request: Request) -> JSONResponse:
    svc: SessionService = request.app.state.sessions
    try:
        body = await request.json()
    except Exception:  # noqa: BLE001 — any undecodable body is the same 400
        return error(400, "malformed-body", "body is not JSON")
    try:
        adm = parse_admission(svc.policy, body)
    except BadRequest as e:
        return error(400, e.code, e.message)
    return await svc.admit(adm)


async def get_session(request: Request) -> JSONResponse:
    svc: SessionService = request.app.state.sessions
    row = svc.store.get_session(request.path_params["id"])
    if row is None:
        return error(404, "session-not-found", "no session carries that id")
    return JSONResponse(row.public())


async def delete_session(request: Request) -> JSONResponse:
    svc: SessionService = request.app.state.sessions
    row = svc.store.get_session(request.path_params["id"])
    if row is None:
        return error(404, "session-not-found", "no session carries that id")
    row = svc.store.release(row.id, svc.clock())
    log.info("session: released id=%s rail=%s requests=%d", row.id, row.rail, row.requests)
    return JSONResponse({"id": row.id, "released_at": iso(row.released_at)})
