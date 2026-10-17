"""Session liveness (GW-SESSIONS-LIVENESS, specs/endpoints/sessions.md): a session whose pod is gone
is reaped, so a SIGKILLed ride never pins its rail slot until the TTL (the 2026-10-17 experiment's
probe left one active for 25 minutes, its TTL).

The gateway already KNOWS the pod: a bound session's pod is the one whose projected token pulled its
env (GW-SESSIONS-PULL — the TokenReview names the pod and its uid); an unbound session's is the
CALLER's pod, when the caller's projected token is pod-bound (GW-SESSIONS-AUTH — the same extras).
`reap()` asks the kube API for each such pod (one namespaced `pods get`, ⚖ cheaper than a renewal
protocol every consumer would have to speak) and releases the session when the pod is gone, terminal,
or a different pod under the same name (another uid — a re-created retry pod). A session with no
known pod, or a pod the API cannot answer for, is left to its TTL.
"""

from __future__ import annotations

import logging
import ssl
from dataclasses import dataclass
from typing import Protocol

import httpx

from .credentials import KUBE_API, SA_DIR

log = logging.getLogger("gateway.liveness")



@dataclass(frozen=True)
class PodState:
    state: str  # running | gone | terminal | unknown
    uid: str | None = None


class PodSource(Protocol):
    async def pod(self, namespace: str, name: str) -> PodState: ...


class StaticPods:
    """Test seam: (namespace, name) -> PodState; an unlisted pod is running with any uid."""

    def __init__(self):
        self.pods: dict[tuple[str, str], PodState] = {}
        self.calls: list[tuple[str, str]] = []

    async def pod(self, namespace: str, name: str) -> PodState:
        self.calls.append((namespace, name))
        return self.pods.get((namespace, name), PodState("running", None))


class KubePods:
    """`GET /api/v1/namespaces/{ns}/pods/{name}` with the gateway's own SA token (RBAC: a namespaced
    `pods get` Role per bind / caller namespace — argocd/resources/agent-gateway/rbac.yaml)."""

    def __init__(self, sa_dir: str = SA_DIR, api: str = KUBE_API, timeout_s: float = 5.0):
        self.sa_dir, self.api, self.timeout_s = sa_dir, api, timeout_s
        self._client: httpx.AsyncClient | None = None

    def client(self) -> httpx.AsyncClient:
        if self._client is None:
            ctx = ssl.create_default_context(cafile=f"{self.sa_dir}/ca.crt")
            self._client = httpx.AsyncClient(base_url=self.api, verify=ctx, timeout=self.timeout_s)
        return self._client

    async def pod(self, namespace: str, name: str) -> PodState:
        try:
            with open(f"{self.sa_dir}/token", encoding="utf-8") as fh:
                tok = fh.read().strip()
            r = await self.client().get(f"/api/v1/namespaces/{namespace}/pods/{name}", headers={"Authorization": "Bearer " + tok})
        except (OSError, httpx.HTTPError) as e:
            log.warning("liveness: pod %s/%s — kube API unreachable: %s", namespace, name, type(e).__name__)
            return PodState("unknown")
        if r.status_code == 404:
            return PodState("gone")
        if r.status_code != 200:  # 403 (no Role in that namespace) / 5xx: nothing is known
            log.warning("liveness: pod %s/%s — kube API %d", namespace, name, r.status_code)
            return PodState("unknown")
        doc = r.json()
        uid = (doc.get("metadata") or {}).get("uid")
        phase = (doc.get("status") or {}).get("phase")
        return PodState("terminal" if phase in ("Succeeded", "Failed") else "running", uid)
