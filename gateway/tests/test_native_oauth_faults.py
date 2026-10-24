"""Unlabelled transport/decoder fault guards, not additional spec evidence."""

import json
import traceback

import httpx
import pytest

from agent_gateway.native_oauth import NativeRefresh, Uncertain
from agent_gateway.oauth import Revoked

from ._codex_world import creds
from .conftest import Clock
from .test_codex_refresh import token


@pytest.mark.parametrize("body", [
    b"not JSON DUMMY-SECRET", b"[]", b"x" * 65537,
    json.dumps({"access_token": token({"exp": 999})}).encode(),
    json.dumps({"access_token": token({"exp": True})}).encode(),
    json.dumps({"access_token": token({"exp": float('inf')})}).encode(),
    json.dumps({"access_token": token({"exp": 4600}), "refresh_token": None}).encode(),
    json.dumps({"access_token": token({"exp": 4600}), "refresh_token": ""}).encode(),
    json.dumps({"access_token": token({"exp": 4600}), "refresh_token": "bad\r\n"}).encode(),
], ids=["not json", "a list", "oversize", "exp in the past", "exp a bool", "exp infinite",
        "refresh_token null", "refresh_token empty", "refresh_token with CRLF"])
def test_bad_responses_are_sanitized(body):
    clock = Clock(1000)
    old, _ = creds(clock)
    closed = []

    class Body(httpx.SyncByteStream):
        def __iter__(self):
            yield body

        def close(self):
            closed.append(True)

    exchange = NativeRefresh(clock, transport=httpx.MockTransport(lambda _: httpx.Response(200, stream=Body())))
    with pytest.raises(Uncertain) as raised:
        exchange(old)
    assert str(raised.value) == "native-refresh-uncertain"
    assert raised.value.__context__ is None
    assert "DUMMY-SECRET" not in "".join(traceback.format_exception(raised.value))
    assert closed == [True]


@pytest.mark.parametrize("fault", [httpx.ReadTimeout, httpx.ConnectError])
def test_network_fault_is_one_sanitized_attempt(fault):
    clock = Clock(1000)
    old, _ = creds(clock)
    calls = []

    def broken(request):
        calls.append(request)
        raise fault("DUMMY-SECRET failure", request=request)

    with pytest.raises(Uncertain) as raised:
        NativeRefresh(clock, transport=httpx.MockTransport(broken))(old)
    assert len(calls) == 1
    assert raised.value.__context__ is None
    assert "DUMMY-SECRET" not in "".join(traceback.format_exception(raised.value))


@pytest.mark.parametrize("code", ["REFRESH_TOKEN_EXPIRED", "refresh_token_invalidated"])
def test_terminal_native_codes(code):
    clock = Clock(1000)
    old, _ = creds(clock)
    transport = httpx.MockTransport(lambda _: httpx.Response(400, stream=httpx.ByteStream(
        json.dumps({"error": {"code": code, "message": "DUMMY-SECRET"}}).encode())))
    with pytest.raises(Revoked) as raised:
        NativeRefresh(clock, transport=transport)(old)
    assert str(raised.value) == "native-refresh-revoked"
    assert raised.value.__context__ is None
