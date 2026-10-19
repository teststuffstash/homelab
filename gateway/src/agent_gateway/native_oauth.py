"""Native Codex refresh only (GW-CODEX-REFRESH); NOT the SIWC token-sharing profile.

Callable seam for oauth.Lifecycle, wired behind CODEX_UPSTREAM/CODEX_SEED_FILE. The lifecycle owns
locking and durable rotation. This transport makes one attempt, never follows redirects,
and exposes only fixed failures. JWT claims are scheduling/consistency hints from the token
endpoint, not signature-verified identity: this module cannot enrol an account.
"""

from __future__ import annotations

import base64
import json
from collections.abc import Callable

import httpx

from .oauth import Credential, Revoked, finite, valid

TOKEN_URL = "https://auth.openai.com/oauth/token"
CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"
MAX_RESPONSE_BYTES = 64 * 1024
TIMEOUT_S = 10.0
TERMINAL_CODES = {"refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"}


class Uncertain(Exception):
    """Fixed failure only; the lifecycle keeps its write-ahead marker for recovery."""


def _replacement(doc: dict, old: Credential, now: float) -> Credential:
    access = doc["access_token"]
    refresh = doc.get("refresh_token", old.refresh_token)
    # Native Codex uses the access JWT's exp for proactive refresh. No guessed TTL and no
    # fallback to the old access token: a success must yield a usable replacement.
    parts = access.split(".")
    if len(parts) != 3:
        raise ValueError
    claims = json.loads(base64.b64decode(parts[1] + "=" * (-len(parts[1]) % 4), altchars=b"-_", validate=True))
    expires = claims["exp"]
    auth = claims.get("https://api.openai.com/auth", {})
    account = auth.get("chatgpt_account_id", old.account_id)
    result = Credential(access, refresh, account, expires)
    if not finite(now) or not valid(result, now) or account != old.account_id:
        raise ValueError
    return result


class NativeRefresh:
    def __init__(self, clock: Callable[[], float], *, transport: httpx.BaseTransport | None = None):
        self.clock = clock
        # Injection is for offline tests; production uses TLS validation, no ambient proxy,
        # client cookies/auth, retries, configurable destination or environment overrides.
        self.transport = transport

    def __call__(self, old: Credential) -> Credential:
        revoked = False
        result = None
        try:
            with httpx.Client(transport=self.transport, trust_env=False, follow_redirects=False,
                              timeout=TIMEOUT_S, headers={"accept": "application/json",
                                                         "accept-encoding": "identity",
                                                         "user-agent": "agent-gateway"}) as client:
                with client.stream("POST", TOKEN_URL, json={"grant_type": "refresh_token",
                                   "client_id": CLIENT_ID, "refresh_token": old.refresh_token}) as response:
                    # iter_raw bounds encoded input too; compressed token responses are refused.
                    if response.headers.get("content-encoding", "identity").lower() != "identity":
                        raise ValueError
                    body = bytearray()
                    for chunk in response.iter_raw():
                        if len(body) + len(chunk) > MAX_RESPONSE_BYTES:
                            raise ValueError
                        body.extend(chunk)
                    doc = json.loads(body)
                    if not isinstance(doc, dict):
                        raise ValueError
                    if response.status_code == 200:
                        result = _replacement(doc, old, self.clock())
                    else:
                        error = doc.get("error")
                        code = error.get("code") if isinstance(error, dict) else error
                        code = code.lower() if isinstance(code, str) else None
                        revoked = (response.status_code == 401 or (response.status_code == 400 and code in TERMINAL_CODES)
                                   or (response.status_code == 400 and code == "invalid_grant"))
        except Exception:  # noqa: BLE001 — never propagate token-bearing HTTP/JSON exceptions
            result = None
        # Outside the except block: even direct callers get no secret-bearing exception context.
        if revoked:
            raise Revoked("native-refresh-revoked")
        if result is None:
            raise Uncertain("native-refresh-uncertain")
        return result
