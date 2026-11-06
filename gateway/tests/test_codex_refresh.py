"""GW-CODEX-REFRESH — the native refresh HTTP boundary, policy-codex · native-refresh (offline MockTransport;
specs/endpoints/openai-responses.md §GW-CODEX-REFRESH). The action crosses Lifecycle → NativeRefresh →
the fake OAuth HTTP endpoint; the fake captures the actual request and its response. All credentials are
fabricated, including JWT signatures. Argnames = each table's header, ids = its description cells.
"""

from __future__ import annotations

import base64
import json
import traceback

import httpx
import pytest

from agent_gateway.native_oauth import NativeRefresh
from agent_gateway.oauth import Failure, Lifecycle

from ._codex_rows import row, verdicts
from ._codex_world import MemoryStore, creds
from .conftest import Clock, attach_json, rule, then, then_eq, when, world

pytestmark = rule("GW-CODEX-REFRESH")

TOKEN_URL = "https://auth.openai.com/oauth/token"


def token(claims):
    payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return "DUMMY-SECRET." + payload + ".fake-signature"


def _fresh_jwt(account_id: str = "dummy-account") -> str:
    return token({"exp": 4600, "https://api.openai.com/auth": {"chatgpt_account_id": account_id}})


# -- a successful exchange ------------------------------------------------------------------------

RESPONSES_OK = {  # the `response` cell → the 200 body
    "fresh access JWT and a replacement refresh token": lambda: {"access_token": _fresh_jwt(), "refresh_token": "DUMMY-SECRET-rotated"},
    "fresh access JWT only": lambda: {"access_token": _fresh_jwt()},
}


@pytest.mark.parametrize(("response", "expected_saved", "expected_expiry"), [
    pytest.param("fresh access JWT and a replacement refresh token", "both replacements, ready", 4600, id="rotation is saved before use"),
    pytest.param("fresh access JWT only", "the replacement access token and the stored refresh token, ready", 4600,
                 id="omitted refresh token retains the stored token"),
])
def test_success(response, expected_saved, expected_expiry):
    world("policy-codex", "native-refresh")
    row(response=response, expected_saved=expected_saved, expected_expiry=expected_expiry)
    clock = Clock(1000)
    old, _ = creds(clock)
    store = MemoryStore(old)
    received = []
    body = RESPONSES_OK[response]()

    def upstream(request):
        received.append((str(request.url), request.method, dict(request.headers), json.loads(request.content),
                         store.record.state, request.extensions["timeout"]))
        attach_json("native refresh HTTP (fabricated credentials only)", {"request": received[-1], "response": body})
        return httpx.Response(200, stream=httpx.ByteStream(json.dumps(body).encode()))

    owner = Lifecycle(store, NativeRefresh(clock, transport=httpx.MockTransport(upstream)), clock, 30)
    with when(f"acquire the near-expiry credential through native refresh HTTP; the response {response}"):
        got = owner.acquire()
    rotated = "refresh_token" in body
    saved_ok = store.record.state == "ready" and store.record.credential == got and got.access_token == body["access_token"] \
        and got.refresh_token == (body["refresh_token"] if rotated else old.refresh_token)
    verdicts(
        saved=(("both replacements, ready" if rotated else "the replacement access token and the stored refresh token, ready") if saved_ok
           else f"state {store.record.state}, refresh token {'replaced' if got.refresh_token != old.refresh_token else 'stored'}", expected_saved),
        expiry=(int(got.expires_at), expected_expiry),
    )
    url, method, headers, sent, marker, timeouts = received[0]
    with then("one POST to the token URL: grant_type, client_id and the stored refresh_token as JSON; no bearer or cookie; "
              "every timeout 10 s; the marker refreshing while the request was out",
              request={"url": url, "method": method, "json_keys": sorted(sent), "marker": marker, "timeouts": timeouts}):
        assert (url, method) == (TOKEN_URL, "POST")
        assert sent == {"grant_type": "refresh_token", "client_id": "app_EMoamEEZ73f0CkXaXp7hrann", "refresh_token": old.refresh_token}
        assert marker == "refreshing"
        assert timeouts == {"connect": 10.0, "read": 10.0, "write": 10.0, "pool": 10.0}
        assert headers["content-type"] == "application/json"
        assert not {"authorization", "cookie"} & headers.keys()


# -- a rejected or uncertain exchange -------------------------------------------------------------

RESPONSES = {  # the `response` cell → (status, body)
    "400 invalid_grant": (400, {"error": "invalid_grant"}),
    "400 nested refresh_token_reused": (400, {"error": {"code": "refresh_token_reused"}}),
    "401 JSON": (401, {"error": "unknown"}),
    "429": (429, {"error": "busy"}),
    "302 with Location": (302, {"error": "invalid_grant"}),
    "200 opaque access token": (200, {"access_token": "DUMMY-SECRET-opaque"}),
    "200 other account claim": (200, {"access_token": _fresh_jwt("other")}),
}


@pytest.mark.parametrize(("response", "expected_first_acquire", "expected_state", "expected_attempts"), [
    pytest.param("400 invalid_grant", "credential-revoked", "revoked", 1, id="invalid grant stops refresh permanently"),
    pytest.param("400 nested refresh_token_reused", "credential-revoked", "revoked", 1, id="reused rotation stops refresh permanently"),
    pytest.param("401 JSON", "credential-revoked", "revoked", 1, id="unauthorized refresh stops permanently"),
    pytest.param("429", "credential-refresh-uncertain", "refreshing", 1, id="rate limit is uncertain and never retried ⚖"),
    pytest.param("302 with Location", "credential-refresh-uncertain", "refreshing", 1, id="redirect never sends the refresh token elsewhere"),
    pytest.param("200 opaque access token", "credential-refresh-uncertain", "refreshing", 1, id="unknown expiry never gets a guessed lifetime ⚖"),
    pytest.param("200 other account claim", "credential-refresh-uncertain", "refreshing", 1, id="different account cannot replace the enrolled account"),
])
def test_refusal(response, expected_first_acquire, expected_state, expected_attempts):
    world("policy-codex", "native-refresh")
    row(response=response, expected_first_acquire=expected_first_acquire, expected_state=expected_state, expected_attempts=expected_attempts)
    clock = Clock(1000)
    old, _ = creds(clock)
    store = MemoryStore(old)
    status, body = RESPONSES[response]
    calls = []

    def upstream(request):
        calls.append(str(request.url))
        attach_json("native refresh HTTP refusal (fabricated credentials only)",
                    {"url": str(request.url), "request": json.loads(request.content), "status": status, "response": body})
        return httpx.Response(status, stream=httpx.ByteStream(json.dumps(body).encode()),
                              headers={"location": "https://elsewhere.invalid/steal"})

    owner = Lifecycle(store, NativeRefresh(clock, transport=httpx.MockTransport(upstream)), clock, 30)
    with when(f"acquire twice across the token endpoint's response {response}"):
        failures = []
        for _ in range(2):
            with pytest.raises(Failure) as raised:
                owner.acquire()
            failures.append(raised.value)
    verdicts(
        first_acquire=(str(failures[0].code), expected_first_acquire),
        state=(store.record.state, expected_state),
        attempts=(len(calls), expected_attempts),
    )
    then_eq("the second acquire", str(failures[1].code), "credential-revoked" if expected_state == "revoked" else "credential-recovery-required",
            claim="the second acquire repeats the revocation or demands recovery — never a retry")
    with then("no credential in exception text or chain"):
        for failure in failures:
            assert "DUMMY-SECRET" not in "".join(traceback.format_exception(failure))
            assert failure.__context__ is None
