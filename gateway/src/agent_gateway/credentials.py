"""The credential boundary (GW-CRED-BOUNDARY, GW-CRED-RESOLVE).

Pods never hold a real key: the gateway resolves one per request from a credential REF.
- `anthropic`  → k8s Secret `<loop_ns>/claude-session`, key `AUTH_TOKEN`
- `openrouter` → the Secret at `stacks.<stack>.openrouter_ref`, key `OPENROUTER_API_KEY`
- `opencode`   → the gateway's OWN mounted key (env `OPENCODE_GO_API_KEY`)
A Secret is honoured only when it carries `openrouter.teststuff.net/session-key=true` — the label
keeps the gateway's get-secret RBAC from becoming a generic secret oracle (old proxy precedent).

Verdicts: a readable+labelled Secret resolves (cached `cache_s`); a 404/403/unlabelled Secret is
DEFINITIVE (`CredentialUnresolved`, negative-cached `negative_cache_s`); a 5xx/unreachable kube
API is TRANSIENT (`CredentialTransient`, also negative-cached, but reported as retriable).
`CredentialSource` is the seam: `KubeSecrets` in the pod, `StaticSecrets` in tests.
"""

from __future__ import annotations

import base64
import logging
import ssl
import threading
import time
from dataclasses import dataclass
from typing import Protocol

import httpx

from .config import Policy, StackPolicy

log = logging.getLogger("gateway.credentials")

SESSION_KEY_LABEL = "openrouter.teststuff.net/session-key"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
KUBE_API = "https://kubernetes.default.svc"

RAIL_SECRET_KEY = {"anthropic": "AUTH_TOKEN", "openrouter": "OPENROUTER_API_KEY"}


class CredentialError(Exception):
    outcome = "definitive"


class CredentialUnresolved(CredentialError):
    """Definitive: the ref names nothing usable (missing / forbidden / unlabelled / empty)."""

    outcome = "definitive"


class CredentialTransient(CredentialError):
    """Transient: the kube API itself failed (5xx / unreachable) — not a verdict on the ref."""

    outcome = "transient"


class SecretNotFound(Exception):
    """The source's definitive miss (404/403)."""


class SecretTransient(Exception):
    """The source's transient failure (5xx / connection error / timeout)."""


class CredentialSource(Protocol):
    async def get_secret(self, ns: str, name: str) -> dict:
        """Return the Secret object (`metadata.labels`, `data` base64) or raise SecretNotFound / SecretTransient."""
        ...


class StaticSecrets:
    """Test seam: a dict of `ns/name` → Secret object; `transient` names refs that raise SecretTransient."""

    def __init__(self, secrets: dict[str, dict] | None = None, transient: set[str] | None = None):
        self.secrets = dict(secrets or {})
        self.transient = set(transient or ())
        self.calls: list[str] = []

    @staticmethod
    def secret(value: str, key: str, labelled: bool = True) -> dict:
        labels = {SESSION_KEY_LABEL: "true"} if labelled else {}
        return {"metadata": {"labels": labels}, "data": {key: base64.b64encode(value.encode()).decode()}}

    async def get_secret(self, ns: str, name: str) -> dict:
        ref = f"{ns}/{name}"
        self.calls.append(ref)
        if ref in self.transient:
            raise SecretTransient(f"{ref}: kube API unavailable (static)")
        if ref not in self.secrets:
            raise SecretNotFound(f"{ref}: not found (static)")
        return self.secrets[ref]


class KubeSecrets:
    """The in-pod source: the SA token + CA from the projected volume, one GET per resolve."""

    def __init__(self, sa_dir: str = SA_DIR, api: str = KUBE_API, timeout_s: float = 10.0):
        self.sa_dir = sa_dir
        self.api = api
        self.timeout_s = timeout_s
        self._client: httpx.AsyncClient | None = None

    def _token(self) -> str:
        with open(f"{self.sa_dir}/token", encoding="utf-8") as fh:
            return fh.read().strip()

    def client(self) -> httpx.AsyncClient:
        if self._client is None:
            ctx = ssl.create_default_context(cafile=f"{self.sa_dir}/ca.crt")
            self._client = httpx.AsyncClient(base_url=self.api, verify=ctx, timeout=self.timeout_s)
        return self._client

    async def get_secret(self, ns: str, name: str) -> dict:
        try:
            r = await self.client().get(
                f"/api/v1/namespaces/{ns}/secrets/{name}",
                headers={"Authorization": "Bearer " + self._token()},
            )
        except httpx.HTTPError as e:
            raise SecretTransient(f"{ns}/{name}: kube API unreachable: {type(e).__name__}") from e
        if r.status_code >= 500:
            raise SecretTransient(f"{ns}/{name}: kube API {r.status_code}")
        if r.status_code in (403, 404):
            raise SecretNotFound(f"{ns}/{name}: kube API {r.status_code}")
        if r.status_code != 200:
            raise SecretTransient(f"{ns}/{name}: kube API {r.status_code}")
        return r.json()


@dataclass
class _Entry:
    expires: float
    value: str | None
    transient: bool
    reason: str


class CredentialResolver:
    def __init__(
        self,
        policy: Policy,
        source: CredentialSource,
        opencode_go_api_key: str | None,
        cache_s: int = 300,
        negative_cache_s: int = 20,
        clock=time.time,
    ):
        self.policy = policy
        self.source = source
        self.opencode_go_api_key = opencode_go_api_key
        self.cache_s = cache_s
        self.negative_cache_s = negative_cache_s
        self.clock = clock
        self._cache: dict[str, _Entry] = {}
        self._lock = threading.Lock()
        # The verdict class of the last resolve (the metrics label): resolved | definitive | transient.
        self.last_outcome = "definitive"
        # Finer grain for logs/tests: ok | ok-cached | unlabeled | missing | transient | cached-miss.
        self.last_reason = "none"

    def ref_for(self, rail: str, stack: StackPolicy) -> str | None:
        if rail == "anthropic":
            return stack.anthropic_ref or f"{stack.loop_ns}/claude-session"
        if rail == "openrouter":
            return stack.openrouter_ref
        return None

    async def resolve(self, rail: str, stack: StackPolicy) -> str:
        """The upstream credential for (rail, stack) — never logged, never stored."""
        if rail == "opencode":
            if not self.opencode_go_api_key:
                self.last_reason = "missing"
                self.last_outcome = "definitive"
                raise CredentialUnresolved("opencode: OPENCODE_GO_API_KEY is not mounted")
            self.last_reason = "ok"
            self.last_outcome = "resolved"
            return self.opencode_go_api_key
        ref = self.ref_for(rail, stack)
        if not ref:
            self.last_reason = "missing"
            self.last_outcome = "definitive"
            raise CredentialUnresolved(f"{rail}: stack {stack.name} declares no credential ref")
        now = self.clock()
        with self._lock:
            hit = self._cache.get(ref)
        if hit and hit.expires > now:
            if hit.value is not None:
                self.last_reason = "ok-cached"
                self.last_outcome = "resolved"
                return hit.value
            self.last_reason = "cached-miss"
            self.last_outcome = "transient" if hit.transient else "definitive"
            if hit.transient:
                raise CredentialTransient(f"{ref}: {hit.reason} (cached)")
            raise CredentialUnresolved(f"{ref}: {hit.reason} (cached)")
        ns, name = ref.split("/", 1)
        value: str | None = None
        transient = False
        reason = ""
        try:
            secret = await self.source.get_secret(ns, name)
        except SecretTransient as e:
            transient, reason = True, f"transient: {e}"
            self.last_reason = "transient"
            self.last_outcome = "transient"
        except SecretNotFound as e:
            reason = f"missing: {e}"
            self.last_reason = "missing"
            self.last_outcome = "definitive"
        else:
            labels = (secret.get("metadata") or {}).get("labels") or {}
            if labels.get(SESSION_KEY_LABEL) != "true":
                reason = f"exists but lacks {SESSION_KEY_LABEL}=true — refusing (not a session key)"
                self.last_reason = "unlabeled"
                self.last_outcome = "definitive"
            else:
                b64 = (secret.get("data") or {}).get(RAIL_SECRET_KEY[rail]) or ""
                if not b64:
                    reason = f"labelled but has no {RAIL_SECRET_KEY[rail]} key"
                    self.last_reason = "missing"
                    self.last_outcome = "definitive"
                else:
                    value = base64.b64decode(b64).decode().strip()
                    self.last_reason = "ok"
                    self.last_outcome = "resolved"
        with self._lock:
            ttl = self.cache_s if value is not None else self.negative_cache_s
            self._cache[ref] = _Entry(now + ttl, value, transient, reason)
        if value is None:
            log.warning("credential %s for rail %s: %s", ref, rail, reason)
            if transient:
                raise CredentialTransient(f"{ref}: {reason}")
            raise CredentialUnresolved(f"{ref}: {reason}")
        return value

    async def resolve_ref(self, ref: str, key: str) -> str:
        """A labelled Secret's `key` by ref (GW-CRED-RESOLVE's verdicts, the same label rule, no cache)
        — the OpenRouter catalog leg's account key (`rails.openrouter.catalog.account_ref`)."""
        if ref.count("/") != 1:
            raise CredentialUnresolved(f"{ref}: not a ns/name ref")
        ns, name = ref.split("/", 1)
        try:
            secret = await self.source.get_secret(ns, name)
        except SecretTransient as e:
            raise CredentialTransient(f"{ref}: transient: {e}") from e
        except SecretNotFound as e:
            raise CredentialUnresolved(f"{ref}: missing: {e}") from e
        labels = (secret.get("metadata") or {}).get("labels") or {}
        if labels.get(SESSION_KEY_LABEL) != "true":
            raise CredentialUnresolved(f"{ref}: exists but lacks {SESSION_KEY_LABEL}=true — refusing")
        b64 = (secret.get("data") or {}).get(key) or ""
        if not b64:
            raise CredentialUnresolved(f"{ref}: labelled but has no {key} key")
        return base64.b64decode(b64).decode().strip()

    def forget(self, ref: str | None = None) -> None:
        with self._lock:
            if ref is None:
                self._cache.clear()
            else:
                self._cache.pop(ref, None)
