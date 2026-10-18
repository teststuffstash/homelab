"""Native refresh HTTP boundary, policy-codex · native-refresh (offline MockTransport).

The action crosses Lifecycle → NativeRefresh → fake OAuth HTTP endpoint; the fake captures
the actual request and its response. All credentials are fabricated, including JWT signatures.
"""

import base64
import json
import traceback

import httpx
import pytest

from agent_gateway.native_oauth import NativeRefresh
from agent_gateway.oauth import Code, Failure, Lifecycle

from ._codex_world import MemoryStore, creds
from .conftest import Clock, attach_json, rule, then, then_eq, when, world

pytestmark = rule("GW-CODEX-REFRESH")


def token(claims):
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return "DUMMY-SECRET." + payload + ".fake-signature"


@pytest.mark.parametrize("rotate", [pytest.param(True, id="rotation is saved before use"),
                                  pytest.param(False, id="omitted refresh token retains the stored token")])
def test_success(rotate):
    world("policy-codex", "native-refresh")
    clock = Clock(1000)
    old, _ = creds(clock)
    store = MemoryStore(old)
    received = []
    access = token({"exp": 4600, "https://api.openai.com/auth": {"chatgpt_account_id": old.account_id}})
    body = {"access_token": access}
    if rotate:
        body["refresh_token"] = "DUMMY-SECRET-rotated"

    def upstream(request):
        received.append((str(request.url), request.method, dict(request.headers), json.loads(request.content),
                         store.record.state, request.extensions["timeout"]))
        attach_json("native refresh HTTP (fabricated credentials only)", {"request": received[-1], "response": body})
        return httpx.Response(200, stream=httpx.ByteStream(json.dumps(body).encode()))

    owner = Lifecycle(store, NativeRefresh(clock, transport=httpx.MockTransport(upstream)), clock, 30)
    with when(f"acquire the near-expiry credential through native refresh HTTP; rotate = {rotate}: "
              f"the answer {'carries a rotated refresh_token' if rotate else 'omits refresh_token'}"):
        got = owner.acquire()
    then_eq("URL and method", received[0][:2], ("https://auth.openai.com/oauth/token", "POST"))
    then_eq("request JSON", received[0][3], {"grant_type": "refresh_token",
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann", "refresh_token": old.refresh_token})
    then_eq("marker before HTTP and durable result", (received[0][4], store.record.state, store.record.credential == got),
            ("refreshing", "ready", True))
    then_eq("replacement access, refresh and expiry", (got.access_token == access, got.refresh_token, got.expires_at),
            (True, "DUMMY-SECRET-rotated" if rotate else old.refresh_token, 4600))
    then_eq("all HTTP timeouts", received[0][5], {"connect": 10.0, "read": 10.0, "write": 10.0, "pool": 10.0})
    with then("JSON content type; no bearer, cookie, resource or scope"):
        assert received[0][2]["content-type"] == "application/json"
        assert not {"authorization", "cookie"} & received[0][2].keys()


@pytest.mark.parametrize("status,body,expected", [
    pytest.param(400, {"error": "invalid_grant"}, Code.REVOKED, id="invalid grant stops refresh permanently"),
    pytest.param(400, {"error": {"code": "refresh_token_reused"}}, Code.REVOKED, id="reused rotation stops refresh permanently"),
    pytest.param(401, {"error": "unknown"}, Code.REVOKED, id="unauthorized refresh stops permanently"),
    pytest.param(429, {"error": "busy"}, Code.REFRESH, id="rate limit is uncertain and never retried"),
    pytest.param(302, {"error": "invalid_grant"}, Code.REFRESH, id="redirect never sends the refresh token elsewhere"),
    pytest.param(200, {"access_token": "DUMMY-SECRET-opaque"}, Code.REFRESH, id="unknown expiry never gets a guessed lifetime"),
    pytest.param(200, {"access_token": token({"exp": 4600, "https://api.openai.com/auth": {"chatgpt_account_id": "other"}})},
                 Code.REFRESH, id="different account cannot replace the enrolled account"),
])
def test_refusal(status, body, expected):
    world("policy-codex", "native-refresh")
    clock = Clock(1000)
    old, _ = creds(clock)
    store = MemoryStore(old)
    calls = []

    def upstream(request):
        calls.append(str(request.url))
        attach_json("native refresh HTTP refusal (fabricated credentials only)",
                    {"url": str(request.url), "request": json.loads(request.content), "status": status, "response": body})
        return httpx.Response(status, stream=httpx.ByteStream(json.dumps(body).encode()),
                              headers={"location": "https://elsewhere.invalid/steal"})

    owner = Lifecycle(store, NativeRefresh(clock, transport=httpx.MockTransport(upstream)), clock, 30)
    with when(f"acquire twice across a rejected or uncertain HTTP refresh: status = {status}, body = {body}"):
        failures = []
        for _ in range(2):
            with pytest.raises(Failure) as raised:
                owner.acquire()
            failures.append(raised.value)
    then_eq("failure codes", [f.code for f in failures],
            [expected, Code.REVOKED if expected == Code.REVOKED else Code.RECOVERY])
    then_eq("HTTP attempts", len(calls), 1)
    then_eq("durable state", store.record.state, "revoked" if expected == Code.REVOKED else "refreshing")
    with then("no credential in exception text or chain"):
        for failure in failures:
            assert "DUMMY-SECRET" not in "".join(traceback.format_exception(failure))
            assert failure.__context__ is None
