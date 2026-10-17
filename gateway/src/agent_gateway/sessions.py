"""The control plane: POST/GET/DELETE /sessions (GW-SESSIONS-ADMIT, -ENV, -TOKEN, -RELEASE) and
the pod's env pull, POST /sessions/{id}/env (GW-SESSIONS-PULL — the identity half lives in pull.py).
Every POST/GET/DELETE is caller-checked first (GW-SESSIONS-AUTH, control.py); the pull is not — its
caller is the bound pod, checked against the bind.

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
import re
import secrets
import time
import uuid
from dataclasses import dataclass, replace

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
from .control import ControlPlaneAuth, authorize_outcome
from .credentials import CredentialResolver, CredentialTransient, CredentialUnresolved
from .liveness import PodSource
from .metrics import Metrics
from .outcomes import OutcomeRefused, Outcomes, parse_outcome, public_outcome
from .pull import (
    POD_NAME_EXTRA,
    POD_UID_EXTRA,
    PULL_AUDIENCE,
    ReviewTransient,
    StaticTokenReviews,
    TokenReviewer,
    identity_mismatch,
)
from .store import UNMINTED_PREFIX, Session, Store, iso

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


# Kubernetes object-name shapes: a namespace is a DNS-1123 label, a ServiceAccount and a Pod name
# a DNS-1123 subdomain (the bind is compared verbatim with a TokenReview's username / pod extra).
_DNS_LABEL = re.compile(r"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$")
_DNS_SUBDOMAIN = re.compile(r"^(?=.{1,253}$)[a-z0-9]([-a-z0-9.]*[a-z0-9])?$")


@dataclass(frozen=True)
class Bind:
    """GW-SESSIONS-PULL: the pod identity a bound session's env may be pulled by."""

    namespace: str
    serviceaccount: str
    pod: str | None


def parse_bind(raw: object) -> Bind:
    if not isinstance(raw, dict):
        raise BadRequest("malformed-body", "bind must be an object {namespace, serviceaccount, pod?}")
    extra = set(raw) - {"namespace", "serviceaccount", "pod"}
    if extra:
        raise BadRequest("malformed-body", f"bind carries unknown keys: {', '.join(sorted(extra))}")
    ns, sa, pod = raw.get("namespace"), raw.get("serviceaccount"), raw.get("pod")
    if not isinstance(ns, str) or not _DNS_LABEL.match(ns):
        raise BadRequest("malformed-body", "bind.namespace is required (a DNS-1123 label)")
    if not isinstance(sa, str) or not _DNS_SUBDOMAIN.match(sa):
        raise BadRequest("malformed-body", "bind.serviceaccount is required (a DNS-1123 subdomain)")
    if pod is not None and (not isinstance(pod, str) or not _DNS_SUBDOMAIN.match(pod)):
        raise BadRequest("malformed-body", "bind.pod, when present, is a DNS-1123 subdomain")
    return Bind(ns, sa, pod)


@dataclass(frozen=True)
class Admission:
    stack: StackPolicy
    role: RolePolicy
    task: str
    round: int
    tier: str
    harness: str
    rail_override: str | None
    bind: Bind | None = None
    caller: str | None = None  # GW-SESSIONS-AUTH: the reviewed caller identity, stored on the row
    caller_pod: str | None = None  # GW-SESSIONS-LIVENESS: the caller's pod (a pod-bound caller token)
    caller_pod_uid: str | None = None
    attempt: int = 1  # GW-SESSIONS-ADMIT: the consumer's automatic re-admission counter at this round


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
    attempt = body.get("attempt", 1)
    if not isinstance(attempt, int) or isinstance(attempt, bool) or attempt < 1:
        raise BadRequest("malformed-body", "attempt must be a positive integer (default 1)")
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
    bind = parse_bind(body["bind"]) if "bind" in body else None
    stack = policy.stacks.get(body["stack"]) or StackPolicy(body["stack"], "", None, None)
    return Admission(stack, role, body["task"], rnd, tier, harness, rail, bind, attempt=attempt)


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
        capacity: Capacity | None = None, reviewer: TokenReviewer | None = None,
    ):
        self.policy = policy
        self.store = store
        self.capacity = capacity or Capacity(policy, store)
        self.resolver = resolver
        self.metrics = metrics
        self.self_url = self_url
        self.clock = clock
        self.reviewer: TokenReviewer = reviewer or StaticTokenReviews()  # app.py hands the kube one in
        self.pods: PodSource | None = None  # GW-SESSIONS-LIVENESS: app.py hands the kube one in
        self.auth = ControlPlaneAuth(policy, self, metrics)  # reviews through self.reviewer (one TokenReview path)
        self.codex = None  # a codex.CodexRail when the policy declares the rail (GW-CODEX-HEADROOM)
        self.outcomes = Outcomes(store, metrics, policy.outcome_window_s, clock)  # GW-SESSIONS-OUTCOME

    async def review(self, token: str, audiences: list[str]):
        """The TokenReviewer seam ControlPlaneAuth calls — delegated, so swapping `self.reviewer`
        (tests: the kube reviewer on a mock API) swaps it for the pull and the control plane alike."""
        return await self.reviewer.review(token, audiences)

    async def admit(self, adm: Admission) -> JSONResponse:
        """The rail pick: first allowed rail that (a) the harness can speak, (b) names a model for the
        tier, (c) has a free slot, (d) is not capacity-blocked (window utilization / 429 latch /
        window draw / the tier model's cell cooled by a 429 — capacity.py), (e) has a resolvable
        credential for the stack that no upstream has rejected (credential-rejected). A TRANSIENT
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
        # ⚖ The same (stack, task, round, attempt) from the same caller, for the same pod (or both
        # unbound), while the earlier session is still active = a re-run of THAT admission (a killed
        # pod's re-run, a leaked slot): the earlier session is SUPERSEDED — released now, its token
        # refused — and this one admitted. Never two live sessions for one attempt.
        for dup in self.store.active_duplicates(adm.stack.name, adm.task, adm.round, adm.attempt, adm.caller,
                                                adm.bind.pod if adm.bind else None, self.clock()):
            self.store.release(dup, self.clock(), reason="superseded")
            log.warning("session: superseded id=%s — the same caller re-admitted %s/%s round %d attempt %d",
                        dup, adm.stack.name, adm.task, adm.round, adm.attempt)
        struck_models, struck_cells = self._struck(adm)
        capacity_blocked: list[tuple[str, str, float, str]] = []  # (rail, reason, free_at, detail)
        cred_blocked: list[str] = []
        cred_rejected: list[str] = []
        exhausted: list[str] = []  # "rail model" cells this task's strikes excluded
        now = self.clock()
        for rail in candidates:
            rp = self.policy.rails[rail]
            models = rp.models.get(adm.tier)
            if not models:
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
            # The tier's ordered list: the first model this task has not struck and whose cell is not cooled.
            model = None
            cooled: list[tuple[float, str]] = []
            for m in models:
                if m in struck_models or (rail, m) in struck_cells:
                    exhausted.append(f"{rail} {m}")
                    continue
                until = self.capacity.cooled(rail, m, now)
                if until is not None:
                    cooled.append((until, m))
                    continue
                model = m
                break
            if model is None:
                if cooled:
                    until, m = min(cooled)
                    capacity_blocked.append((rail, "cell-cooled", until, f"{rail} cell {m} cooled (429)"))
                log.info("session: rail %s — no admissible model for tier %s (struck: %s; cooled: %s)", rail, adm.tier,
                         ", ".join(e for e in exhausted if e.startswith(rail + " ")) or "-", ", ".join(m for _, m in cooled) or "-")
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
                credential = await self.resolver.resolve(rail, adm.stack)
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
            due = self.capacity.credential_rejected(rail, credential, now)
            if due is not None:
                log.info("session: rail %s skipped — its credential for stack %s was rejected upstream (re-verified at %s)",
                         rail, adm.stack.name, iso(due))
                cred_rejected.append((rail, due))
                continue
            return self._dispatch(adm, rail, model, now)
        if capacity_blocked:
            rail, reason, free_at, _ = min(capacity_blocked, key=lambda b: b[2])  # ties: walk order (min is stable)
            return self._defer(adm, reason, "every allowed rail is blocked: " + "; ".join(b[3] for b in capacity_blocked),
                               retry_after_s=max(1, math.ceil(free_at - now)))
        if cred_rejected:  # ⚖ a rejected credential outranks an unresolved one: it names the operator act
            first = min(d for _, d in cred_rejected)  # the earliest re-verification is when asking again helps
            return self._defer(adm, "credential-rejected",
                               f"the upstream rejected the credential of rail(s) {', '.join(r for r, _ in cred_rejected)} for stack {adm.stack.name}",
                               retry_after_s=max(1, math.ceil(first - now)))
        if cred_blocked:
            return self._defer(adm, "credential-unresolved",
                               f"no allowed rail has a resolvable credential for stack {adm.stack.name}: {', '.join(cred_blocked)}")
        if exhausted:  # every candidate cell is struck for this task: no wait helps — the caller escalates
            return self._defer(adm, "cells-exhausted", "this task's strikes exclude every cell: " + ", ".join(exhausted),
                               retry_after_s=None, escalate=True)
        return self._defer(adm, "role-rail-denied", f"no allowed rail of role {adm.role.name} names a model for tier {adm.tier}")

    def _defer(self, adm: Admission, reason: str, detail: str, retry_after_s: int | None = None,
               escalate: bool = False) -> JSONResponse:
        self.metrics.session_decision("none", adm.role.name, adm.stack.name, "defer")
        if escalate:  # cells-exhausted: no retry_after_s — waiting does not help, a human / the coordinator decides
            log.info("session: defer %s (escalate) stack=%s role=%s task=%s attempt=%d — %s",
                     reason, adm.stack.name, adm.role.name, adm.task, adm.attempt, detail)
            return JSONResponse({"decision": "defer", "reason": reason})
        retry = retry_after_s if retry_after_s is not None else self.policy.defer_retry_s
        log.info("session: defer %s retry_after_s=%d stack=%s role=%s task=%s — %s",
                 reason, retry, adm.stack.name, adm.role.name, adm.task, detail)
        return JSONResponse({"decision": "defer", "reason": reason, "retry_after_s": retry})

    def _struck(self, adm: Admission) -> tuple[set[str], set[tuple[str, str]]]:
        """This task's counted strikes (GW-SESSIONS-OUTCOME): model-scoped → the model id on every rail;
        cell-scoped → that (rail, model)."""
        models: set[str] = set()
        cells: set[tuple[str, str]] = set()
        for st in self.store.strikes_for(adm.stack.name, adm.task):
            if st["scope"] == "model":
                models.add(st["model"])
            else:
                cells.add((st["rail"], st["model"]))
        return models, cells

    def _dispatch(self, adm: Admission, rail: str, model: str, now: float) -> JSONResponse:
        sid = uuid.uuid4().hex
        common = dict(id=sid, stack=adm.stack.name, role=adm.role.name, task=adm.task, round=adm.round, attempt=adm.attempt, rail=rail,
                      harness=adm.harness, model=model, created_at=now, expires_at=now + self.policy.session_ttl_s,
                      caller=adm.caller)
        who = adm.caller or "(unauthenticated)"
        if adm.bind is not None:
            # GW-SESSIONS-PULL: nothing credential-shaped leaves in this answer — the token is minted
            # at the pull, so the row holds the unminted placeholder no token hashes to.
            row = self.store.create_session(
                **common, token_hash=UNMINTED_PREFIX + sid, bind_namespace=adm.bind.namespace,
                bind_serviceaccount=adm.bind.serviceaccount, bind_pod=adm.bind.pod,
            )
            self.metrics.session_decision(rail, adm.role.name, adm.stack.name, "dispatch")
            log.info("session: dispatch id=%s stack=%s role=%s task=%s attempt=%d rail=%s harness=%s model=%s bind=%s/%s pod=%s caller=%s",
                     sid, adm.stack.name, adm.role.name, adm.task, adm.attempt, rail, adm.harness, model,
                     adm.bind.namespace, adm.bind.serviceaccount, adm.bind.pod or "(any)", who)
            return JSONResponse({
                "decision": "dispatch",
                "session": {"id": row.id, "expires_at": iso(row.expires_at)},
                "rail": rail,
                "harness": adm.harness,
                "model": model,
                "env_keys": list(assemble_env(self.self_url, adm.harness, "", wire_model(rail, model))),
                "pull_url": f"{self.self_url}/sessions/{row.id}/env",
                "context_tokens": self.policy.context_tokens_for(model),
            })
        token = new_token()
        row = self.store.create_session(**common, token_hash=token_hash(token))
        if adm.caller_pod and adm.caller:  # an unbound session lives in its caller's pod (GW-SESSIONS-LIVENESS)
            self.store.set_live_pod(row.id, adm.caller.split(":")[2], adm.caller_pod, adm.caller_pod_uid)
        self.metrics.session_decision(rail, adm.role.name, adm.stack.name, "dispatch")
        log.info("session: dispatch id=%s stack=%s role=%s task=%s attempt=%d rail=%s harness=%s model=%s caller=%s",
                 sid, adm.stack.name, adm.role.name, adm.task, adm.attempt, rail, adm.harness, model, who)
        return JSONResponse({
            "decision": "dispatch",
            "session": {"id": row.id, "token": token, "expires_at": iso(row.expires_at)},
            "rail": rail,
            "harness": adm.harness,
            "model": model,
            "env": assemble_env(self.self_url, adm.harness, token, wire_model(rail, model)),
            "context_tokens": self.policy.context_tokens_for(model),
        })

    async def pull_env(self, sid: str, presented: str | None) -> JSONResponse:
        """GW-SESSIONS-PULL, in order: the id (404) → the identity (403; a TokenReview the API
        cannot answer is 503) → the session's state (401 released / expired, as the data plane
        refuses it) → at most once (409). Identity precedes state, so a stranger learns nothing
        about a session but that its id exists. Success mints the token now; only its sha256 is
        stored, and the answer is the env GW-SESSIONS-ENV would have handed the launcher."""
        row = self.store.get_session(sid)
        if row is None:
            return error(404, "session-not-found", "no session carries that id")
        if not row.bound:
            return self._refuse_pull(row, "the session has no bind — its env went out in the dispatch answer")
        if not presented:
            return self._refuse_pull(row, "no bearer ServiceAccount token presented")
        try:
            review = await self.reviewer.review(presented, [PULL_AUDIENCE])
        except ReviewTransient as e:
            log.warning("session: env pull id=%s — tokenreview-transient: %s", row.id, e)
            return error(503, "tokenreview-transient", "the TokenReview API did not answer — retry",
                         headers={"retry-after": "5"})
        why = identity_mismatch(review, row.bind_namespace or "", row.bind_serviceaccount or "", row.bind_pod)
        if why:
            return self._refuse_pull(row, why)
        now = self.clock()
        state = row.state(now)
        if state != "active":
            code = "session-released" if state == "released" else "session-expired"
            log.info("session: env pull id=%s refused — %s", row.id, code)
            return error(401, code, f"the session is {state}")
        if row.env_delivered_at is not None:
            log.warning("session: env pull id=%s refused — env-already-delivered (at %s)", row.id, iso(row.env_delivered_at))
            return error(409, "env-already-delivered", "this session's env was already pulled")
        token = new_token()
        if not self.store.deliver_env(row.id, token_hash(token), now):
            log.warning("session: env pull id=%s refused — env-already-delivered (a racing pull won)", row.id)
            return error(409, "env-already-delivered", "this session's env was already pulled")
        pulled = review.extra.get(POD_NAME_EXTRA) or ()
        if pulled:  # a bound session lives in the pod that pulled its env (GW-SESSIONS-LIVENESS)
            self.store.set_live_pod(row.id, row.bind_namespace, pulled[0], (review.extra.get(POD_UID_EXTRA) or (None,))[0])
        env = assemble_env(self.self_url, row.harness, token, wire_model(row.rail, row.model))
        log.info("session: env pulled id=%s by %s pod=%s keys=%s", row.id, review.username,
                 ",".join(review.extra.get(POD_NAME_EXTRA, ())) or "?", ",".join(env))
        return JSONResponse({"id": row.id, "expires_at": iso(row.expires_at), "env": env})

    def _refuse_pull(self, row: Session, why: str) -> JSONResponse:
        log.warning("session: env pull id=%s refused — pull-identity-refused: %s", row.id, why)
        return error(403, "pull-identity-refused", why)

    async def reap(self) -> int:
        """GW-SESSIONS-LIVENESS: release every active session whose pod is gone, terminal, or another
        pod under the same name (a different uid). Unknown (the API away, no Role) = left to the TTL."""
        if self.pods is None:
            return 0
        now = self.clock()
        reaped = 0
        for row in self.store.live_sessions(now):
            st = await self.pods.pod(row.live_namespace or "", row.live_pod or "")
            gone = st.state in ("gone", "terminal") or (
                st.state == "running" and st.uid is not None and row.live_pod_uid is not None and st.uid != row.live_pod_uid)
            if gone:
                self.store.release(row.id, now, reason="pod-gone")
                self.metrics.session_reaped(row.rail)
                reaped += 1
                log.warning("session: reaped id=%s rail=%s — pod %s/%s is %s", row.id, row.rail, row.live_namespace,
                            row.live_pod, st.state if st.state != "running" else "a different pod (uid)")
        return reaped

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
    """GW-SESSIONS-AUTH first (401 / 403 / 503 before the body is read), then the body (400), then
    the caller's entry against the body's stack, role and bind (403), then the admission walk."""
    svc: SessionService = request.app.state.sessions
    caller = await svc.auth.check("admit", _bearer(request))
    if isinstance(caller, JSONResponse):
        return caller
    try:
        body = await request.json()
    except Exception:  # noqa: BLE001 — any undecodable body is the same 400
        return error(400, "malformed-body", "body is not JSON")
    try:
        adm = parse_admission(svc.policy, body)
    except BadRequest as e:
        return error(400, e.code, e.message)
    denied = ControlPlaneAuth.authorize_admission(caller, adm.stack.name, adm.role.name, adm.bind.namespace if adm.bind else None)
    if denied is not None:
        return denied
    return await svc.admit(replace(adm, caller=caller.identity, caller_pod=caller.pod, caller_pod_uid=caller.pod_uid))


def _bearer(request: Request) -> str | None:
    auth = request.headers.get("authorization") or ""
    scheme, _, value = auth.partition(" ")
    if scheme.lower() != "bearer":
        return None
    return value.strip() or None


async def post_session_env(request: Request) -> JSONResponse:
    svc: SessionService = request.app.state.sessions
    return await svc.pull_env(request.path_params["id"], _bearer(request))


async def _owned_row(request: Request, route: str) -> tuple[SessionService, Session | None, JSONResponse | None]:
    """GET / DELETE: the caller check (401 / 403 / 503), the id (404), then ownership (403)."""
    svc: SessionService = request.app.state.sessions
    caller = await svc.auth.check(route, _bearer(request))
    if isinstance(caller, JSONResponse):
        return svc, None, caller
    row = svc.store.get_session(request.path_params["id"])
    if row is None:
        return svc, None, error(404, "session-not-found", "no session carries that id")
    denied = ControlPlaneAuth.authorize_owner(caller, route, row.id, row.caller)
    return svc, row, denied


async def get_session(request: Request) -> JSONResponse:
    svc, row, refused = await _owned_row(request, "lookup")
    if refused is not None:
        return refused
    return JSONResponse({**row.public(svc.clock()), "outcome": public_outcome(svc.store.latest_outcome(row.id))})


async def post_session_outcome(request: Request) -> JSONResponse:
    """GW-SESSIONS-OUTCOME, in order: the caller (401 / 403 / 503) → the id (404) → owner or judge
    (403) → the body (400) → judge-only class (403) → the window (409) → one class per reporter (409)."""
    svc: SessionService = request.app.state.sessions
    caller = await svc.auth.check("outcome", _bearer(request))
    if isinstance(caller, JSONResponse):
        return caller
    row = svc.store.get_session(request.path_params["id"])
    if row is None:
        return error(404, "session-not-found", "no session carries that id")
    denied, judge = authorize_outcome(caller, row.id, row.caller, row.stack)
    if denied is not None:
        return denied
    try:
        body = await request.json()
    except Exception:  # noqa: BLE001
        return error(400, "malformed-body", "body is not JSON")
    try:
        klass, sub, evidence = parse_outcome(body)
        answer = svc.outcomes.report(row, klass, sub, evidence, caller.identity, judge)
    except OutcomeRefused as e:
        log.info("session: outcome id=%s refused — %s", row.id, e.code)
        return error(e.status, e.code, e.message)
    return JSONResponse(answer)


async def delete_session(request: Request) -> JSONResponse:
    svc, row, refused = await _owned_row(request, "release")
    if refused is not None:
        return refused
    row = svc.store.release(row.id, svc.clock(), reason="released")
    log.info("session: released id=%s rail=%s requests=%d caller=%s", row.id, row.rail, row.requests, row.caller or "(unauthenticated)")
    return JSONResponse({"id": row.id, "released_at": iso(row.released_at)})
