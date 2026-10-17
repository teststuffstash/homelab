"""The control plane's caller check: POST /sessions, GET and DELETE /sessions/{id} (GW-SESSIONS-AUTH).

The caller presents its PROJECTED ServiceAccount token (audience `agent-gateway`) as
`Authorization: Bearer`. The gateway reviews it with the SAME TokenReview path the env pull uses
(pull.py: `TokenReviewer` + `review_refusal`, one implementation) and reads the reviewed username
— `system:serviceaccount:<ns>:<sa>` — against the policy's `callers` map: the stacks and roles that
caller may admit, and the namespaces its `bind` may name. GET / DELETE belong to the caller that
admitted the session (`sessions.caller`).

`control_plane_auth` is the rollout knob. `enforce`: a missing or invalid token is 401
`caller-unauthenticated` (a TokenReview the API cannot answer is 503 `tokenreview-transient`).
`observe`: the same request is ADMITTED, logged on one line and counted on
`gateway_control_plane_unauthenticated_total{route,reason}` — the soak signal for the flip. A
VALID token is checked against `callers` in both modes (⚖): an identity the gateway can read is
never waved through on a rollout knob.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

from starlette.responses import JSONResponse

from .config import CallerPolicy, Policy
from .metrics import Metrics
from .pull import (
    GATEWAY_AUDIENCE,
    POD_NAME_EXTRA,
    POD_UID_EXTRA,
    ReviewTransient,
    TokenReviewer,
    review_refusal,
)

log = logging.getLogger("gateway.control")

ROUTES = ("admit", "lookup", "release", "outcome")  # POST /sessions · GET · DELETE · POST /sessions/{id}/outcome
REASONS = ("absent", "invalid", "review-transient")


def _error(status: int, code: str, message: str, headers: dict[str, str] | None = None) -> JSONResponse:
    return JSONResponse({"error": {"code": code, "message": message}}, status_code=status, headers=headers)


@dataclass(frozen=True)
class Caller:
    """The outcome of a successful check: the reviewed identity and its policy entry, or — under
    `observe` only — no identity at all (`identity is None`)."""

    identity: str | None
    policy: CallerPolicy | None
    pod: str | None = None  # GW-SESSIONS-LIVENESS: the caller's pod, when its projected token is pod-bound
    pod_uid: str | None = None


class ControlPlaneAuth:
    def __init__(self, policy: Policy, reviewer: TokenReviewer, metrics: Metrics):
        self.policy = policy
        self.reviewer = reviewer
        self.metrics = metrics

    async def check(self, route: str, presented: str | None) -> Caller | JSONResponse:
        """Authenticate the caller of `route` (one of ROUTES), then require it in `callers`."""
        reason = None
        identity = None
        caller_pod: tuple[str | None, str | None] = (None, None)
        if not presented:
            reason = "absent"
        else:
            try:
                review = await self.reviewer.review(presented, [GATEWAY_AUDIENCE])
            except ReviewTransient as e:
                reason = "review-transient"
                log.warning("control-plane: %s — TokenReview did not answer: %s", route, e)
            else:
                why = review_refusal(review)
                if why:
                    reason = "invalid"
                    log.info("control-plane: %s — the caller's token was refused: %s", route, why)
                else:
                    identity = review.username
                    caller_pod = ((review.extra.get(POD_NAME_EXTRA) or (None,))[0],
                                  (review.extra.get(POD_UID_EXTRA) or (None,))[0])
        if reason is not None:
            self.metrics.control_plane_unauthenticated(route, reason)
            if self.policy.control_plane_auth == "observe":
                log.warning("control-plane: %s unauthenticated (%s) — ADMITTED under control_plane_auth=observe", route, reason)
                return Caller(None, None)
            log.warning("control-plane: %s unauthenticated (%s) — refused (control_plane_auth=enforce)", route, reason)
            if reason == "review-transient":
                return _error(503, "tokenreview-transient", "the TokenReview API did not answer — retry", headers={"retry-after": "5"})
            return _error(401, "caller-unauthenticated",
                          f"present a projected ServiceAccount token, audience {GATEWAY_AUDIENCE}, as Authorization: Bearer")
        entry = self.policy.callers.get(identity or "")
        if entry is None:
            log.warning("control-plane: %s refused — caller-unknown: %s is not in policy callers", route, identity)
            return _error(403, "caller-unknown", f"{identity} is not a control-plane caller in policy")
        return Caller(identity, entry, *caller_pod)

    @staticmethod
    def authorize_admission(caller: Caller, stack: str, role: str, bind_namespace: str | None) -> JSONResponse | None:
        """A known caller's admission body against its entry: stack, then role, then the bind's
        namespace — each refusal its own code. No entry (observe, unauthenticated) = nothing to check."""
        cp = caller.policy
        if cp is None:
            return None
        if stack not in cp.stacks:
            return _deny(caller, "caller-stack-denied", f"{caller.identity} may not admit stack {stack!r}")
        if role not in cp.roles:
            return _deny(caller, "caller-role-denied", f"{caller.identity} may not admit role {role!r}")
        if bind_namespace is not None and bind_namespace not in cp.bind_namespaces:
            return _deny(caller, "caller-bind-denied", f"{caller.identity} may not bind a session to namespace {bind_namespace!r}")
        return None

    @staticmethod
    def authorize_owner(caller: Caller, route: str, sid: str, owner: str | None) -> JSONResponse | None:
        """GET / DELETE belong to the admitting caller. A row with no recorded caller (admitted
        unauthenticated under `observe`) has no owner to protect: any known caller may read or release
        it ⚖ — refusing would only pin its rail slot until the TTL."""
        if caller.identity is None or owner is None or owner == caller.identity:
            return None
        return _deny(caller, "caller-not-owner", f"session {sid} was admitted by another caller", route=route)


def authorize_outcome(caller: Caller, sid: str, owner: str | None, stack: str) -> tuple[JSONResponse | None, bool]:
    """POST /sessions/{id}/outcome: the DELETE rule (the admitting caller; a row with no recorded
    caller has no owner), plus a JUDGE — a caller whose entry says `outcome: any` — on any session of
    its stacks. Returns (refusal, reported-as-judge)."""
    if caller.identity is None or owner is None or owner == caller.identity:
        return None, bool(caller.policy and caller.policy.outcome == "any" and stack in caller.policy.stacks)
    if caller.policy is not None and caller.policy.outcome == "any" and stack in caller.policy.stacks:
        return None, True
    return _deny(caller, "caller-not-owner", f"session {sid} was admitted by another caller", route="outcome"), False


def _deny(caller: Caller, code: str, message: str, route: str = "admit") -> JSONResponse:
    log.warning("control-plane: %s refused — %s: %s", route, code, message)
    return _error(403, code, message)
