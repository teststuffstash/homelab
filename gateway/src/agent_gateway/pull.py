"""The pod's env pull: POST /sessions/{id}/env (GW-SESSIONS-PULL) — and the ONE TokenReview path
the control plane's caller check reuses (GW-SESSIONS-AUTH, control.py).

A `POST /sessions` body that carries `bind: {namespace, serviceaccount, pod?}` is answered with
the session's id, rail, harness, model, `env_keys` and `pull_url` — no token, no env values. The
pod then presents its PROJECTED ServiceAccount token (audience `agent-gateway`) to the pull URL;
the gateway TokenReviews it, requires the reviewed identity to BE the bind, mints the `gws_`
token NOW (storing only its sha256) and answers the env GW-SESSIONS-ENV would have — at most once.

The identity check is the git broker's (openrouter-proxy `_token_review`, FU-080/FU-089): a
TokenReview that cannot be performed is a refusal of the pull, never a pass-through. Unlike the
broker, a review the API cannot answer is a typed 503 (`tokenreview-transient`) — the caller may
retry — and a review that answers "no" is the 403.

`TokenReviewer` is the seam: `KubeTokenReviews` in the pod, `StaticTokenReviews` in tests.
"""

from __future__ import annotations

import logging
import ssl
from dataclasses import dataclass, field
from typing import Protocol

import httpx

from .credentials import KUBE_API, SA_DIR

log = logging.getLogger("gateway.pull")

PULL_AUDIENCE = "agent-gateway"
GATEWAY_AUDIENCE = PULL_AUDIENCE  # one audience for every projected token this gateway reviews (pull + control plane)
POD_NAME_EXTRA = "authentication.kubernetes.io/pod-name"
POD_UID_EXTRA = "authentication.kubernetes.io/pod-uid"  # GW-SESSIONS-LIVENESS: tells a re-created same-name pod apart


class ReviewTransient(Exception):
    """The TokenReview API failed or could not be reached — nothing is known about the caller."""


@dataclass(frozen=True)
class Review:
    """A TokenReview's `status`, reduced to what the pull compares."""

    authenticated: bool
    username: str | None = None
    audiences: tuple[str, ...] = ()
    extra: dict[str, tuple[str, ...]] = field(default_factory=dict)

    @staticmethod
    def from_status(status: dict) -> Review:
        user = status.get("user") or {}
        extra = {k: tuple(v or ()) for k, v in (user.get("extra") or {}).items()}
        return Review(bool(status.get("authenticated")), user.get("username") or None,
                      tuple(status.get("audiences") or ()), extra)


class TokenReviewer(Protocol):
    async def review(self, token: str, audiences: list[str]) -> Review:
        """TokenReview `token` for `audiences`, or raise ReviewTransient."""
        ...


class StaticTokenReviews:
    """Test seam (the fake TokenReview): `tokens` maps a presented token to the Review the API
    would answer; any other token reviews as unauthenticated. `transient` makes every review raise."""

    def __init__(self, tokens: dict[str, Review] | None = None, transient: bool = False):
        self.tokens = dict(tokens or {})
        self.transient = transient
        self.calls: list[list[str]] = []  # the audiences of each review (never the token)

    async def review(self, token: str, audiences: list[str]) -> Review:
        self.calls.append(list(audiences))
        if self.transient:
            raise ReviewTransient("TokenReview API unavailable (static)")
        return self.tokens.get(token, Review(False))


class KubeTokenReviews:
    """The in-pod reviewer: `POST /apis/authentication.k8s.io/v1/tokenreviews` with the gateway's
    own SA token (RBAC: `tokenreviews.create`, argocd/resources/agent-gateway/rbac.yaml)."""

    def __init__(self, sa_dir: str = SA_DIR, api: str = KUBE_API, timeout_s: float = 10.0):
        self.sa_dir = sa_dir
        self.api = api
        self.timeout_s = timeout_s
        self._client: httpx.AsyncClient | None = None

    def client(self) -> httpx.AsyncClient:
        if self._client is None:
            ctx = ssl.create_default_context(cafile=f"{self.sa_dir}/ca.crt")
            self._client = httpx.AsyncClient(base_url=self.api, verify=ctx, timeout=self.timeout_s)
        return self._client

    async def review(self, token: str, audiences: list[str]) -> Review:
        body = {"apiVersion": "authentication.k8s.io/v1", "kind": "TokenReview",
                "spec": {"token": token, "audiences": audiences}}
        try:
            with open(f"{self.sa_dir}/token", encoding="utf-8") as fh:
                own = fh.read().strip()
            r = await self.client().post("/apis/authentication.k8s.io/v1/tokenreviews", json=body,
                                         headers={"Authorization": "Bearer " + own})
        except (OSError, httpx.HTTPError) as e:
            raise ReviewTransient(f"TokenReview API unreachable: {type(e).__name__}") from e
        if r.status_code not in (200, 201):
            # 5xx = the API is away; 401/403 = the gateway cannot review (its RBAC) — either way
            # nothing is known about the CALLER, so it is not a verdict on the caller.
            raise ReviewTransient(f"TokenReview API {r.status_code}")
        return Review.from_status(r.json().get("status") or {})


def review_refusal(review: Review) -> str | None:
    """None when the review authenticates a username for this gateway's audience; else a one-line
    reason (never a token). The shared half of the pull's and the control plane's identity check."""
    if not review.authenticated or not review.username:
        return "the token does not authenticate"
    if GATEWAY_AUDIENCE not in review.audiences:
        return f"the token is not valid for audience {GATEWAY_AUDIENCE}"
    return None


def identity_mismatch(review: Review, namespace: str, serviceaccount: str, pod: str | None) -> str | None:
    """None when `review` is the bind's identity; else a one-line reason (never a token)."""
    why = review_refusal(review)
    if why:
        return why
    want = f"system:serviceaccount:{namespace}:{serviceaccount}"
    if review.username != want:
        return f"the token is {review.username}, the bind is {want}"
    if pod is not None and review.extra.get(POD_NAME_EXTRA) != (pod,):
        got = ",".join(review.extra.get(POD_NAME_EXTRA, ())) or "no pod"
        return f"the token is bound to {got}, the bind names pod {pod}"
    return None
