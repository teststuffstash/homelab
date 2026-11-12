"""GW-SESSIONS-CAPACITY — the Go account headroom as admission rows (specs/endpoints/sessions.md
§Admission → GW-SESSIONS-CAPACITY → Go account headroom). The Go twin of GW-CODEX-HEADROOM: the gateway
polls the account usage endpoint with its own Go key and admits the opencode rail only on a fresh
reading under the ceiling. World `policy-go` (its `rails.opencode.headroom`) and a fake Go usage
endpoint the gateway polls; T0 = 1_800_000_000 = Fri 2027-01-15 08:00:00Z, and a poll before the ask
sets the clock back for that poll. Every cell is a parameter value verbatim; the maps below turn a
cell's text into what it means. Header == argnames, description == id (tests/_rows.py)."""

from __future__ import annotations

import dataclasses
import json
import logging
from datetime import UTC, datetime

import httpx
import pytest

from agent_gateway.app import create_app
from agent_gateway.config import Policy

from ._rows import DASH, POLICY, body_of, enter_world, expect, inputs
from .conftest import GO_KEY, HERE, ObservedAsyncClient, attach_json, given, rule, then, then_eq, when

pytestmark = rule("GW-SESSIONS-CAPACITY")

T0 = 1_800_000_000.0
TASK = "homelab-2650-r1"
GO_USAGE_URL = "https://opencode.test/zen/go/v1/usage"
FRESH = {"rolling": ("ok", 20, 18000), "weekly": ("ok", 46, 80000), "monthly": ("ok", 36, 2000000)}  # name: (status, percent, resetsAt − T0)
DUMMY_IDENTITY = {"account_id": "acct-DUMMY-0001", "email": "dummy@example.test"}  # never a log line, never a read field


def _iso(t: float) -> str:
    return datetime.fromtimestamp(t, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _usage_doc(windows: dict) -> dict:
    """The vendor payload (`GET /zen/go/v1/usage`) for the windows: name → (status, percent, resetsAt − T0)."""
    usage = {name: {"status": status, "percent": pct, "resetsAt": _iso(T0 + off)} for name, (status, pct, off) in windows.items()}
    return {"usage": usage, **DUMMY_IDENTITY}


class _GoUsage(httpx.AsyncBaseTransport):
    """The Go account usage endpoint, offline: the usage URL is answered from `doc`; every other request
    goes to the rest of the world's transport (the rails' fakes and the Go catalog's vendor)."""

    def __init__(self, rest: httpx.AsyncBaseTransport):
        self.rest, self.doc, self.calls = rest, None, []

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        if str(request.url) != GO_USAGE_URL:
            return await self.rest.handle_async_request(request)
        self.calls.append(request)
        body = json.dumps(self.doc).encode()
        attach_json("upstream usage GET → 200", {
            "request": {"headers": {k: ("<bearer>" if k == "authorization" else v) for k, v in request.headers.items()}},
            "response": {"status": 200, "bytes": len(body)}})
        return httpx.Response(200, headers={"content-type": "application/json"}, content=body)


@pytest.fixture
def go_usage(mcp_transport) -> _GoUsage:
    return _GoUsage(mcp_transport)


def _go_app(settings, secrets, store, clock, reviews, pods, usage: _GoUsage, policy: str, usage_url: str):
    """The gateway composed over the world's policy document and the `usage_url` cell (`set` = the fake
    usage endpoint's URL, `unset` = none); its client reaches the usage fake."""
    client = httpx.AsyncClient(transport=usage)
    cfg = dataclasses.replace(settings, opencode_usage_url={"set": GO_USAGE_URL, "unset": ""}[usage_url])
    app = create_app(cfg, policy=Policy.load(HERE / "fixtures" / f"{policy}.json"), source=secrets, store=store, client=client,
                     clock=clock, reviewer=reviews, pods=pods)
    return app, client


# polls cell → [(at, the windows of that reading, the poll's outcome)]; "others fresh" = FRESH for the windows not named
GO_POLLS = {
    "none": [],
    "fresh @ T0 − 10 → accepted": [(-10, FRESH, "accepted")],
    "rolling 95 % resets T0 + 1000, others fresh @ T0 − 10 → accepted":
        [(-10, {**FRESH, "rolling": ("ok", 95, 1000)}, "accepted")],
    "rolling 96 % resets T0 + 1000, weekly 97 % resets T0 + 8000, others fresh @ T0 − 10 → accepted":
        [(-10, {**FRESH, "rolling": ("ok", 96, 1000), "weekly": ("ok", 97, 8000)}, "accepted")],
    "rolling limited at 20 %, others fresh @ T0 − 10 → accepted":
        [(-10, {**FRESH, "rolling": ("limited", 20, 18000)}, "accepted")],
    "rolling 96 % resets T0 + 1000, others fresh @ T0 − 10 → accepted":
        [(-10, {**FRESH, "rolling": ("ok", 96, 1000)}, "accepted")],
    "fresh @ T0 − 20 → accepted; monthly absent @ T0 − 10 → quota-invalid":
        [(-20, FRESH, "accepted"), (-10, {"rolling": FRESH["rolling"], "weekly": FRESH["weekly"]}, "quota-invalid")],
    "fresh @ T0 − 20 → accepted; rolling resets T0 − 15, others fresh @ T0 − 10 → quota-invalid":
        [(-20, FRESH, "accepted"), (-10, {**FRESH, "rolling": ("ok", 20, -15)}, "quota-invalid")],
}

GO_ROWS = [
    pytest.param("policy-go · upstream-ok", "set", "fresh @ T0 − 10 → accepted", 0, "opencode", "dispatch", "opencode", DASH, DASH,
                 id="a fresh Go reading under the ceiling admits the opencode rail"),
    pytest.param("policy-go · upstream-ok", "set", "rolling 95 % resets T0 + 1000, others fresh @ T0 − 10 → accepted", 0, "opencode",
                 "defer", DASH, "quota-limited", 1000, id="the rolling block at the ceiling defers until its reset ⚖"),
    pytest.param("policy-go · upstream-ok", "set", "rolling 96 % resets T0 + 1000, weekly 97 % resets T0 + 8000, others fresh @ T0 − 10 → accepted", 0,
                 "opencode", "defer", DASH, "quota-limited", 8000, id="two exhausted windows wait for the later reset ⚖"),
    pytest.param("policy-go · upstream-ok", "set", "rolling limited at 20 %, others fresh @ T0 − 10 → accepted", 0, "opencode",
                 "defer", DASH, "quota-limited", 60, id="a window whose status is not ok limits ⚖"),
    pytest.param("policy-go · upstream-ok", "set", "none", 0, "opencode", "defer", DASH, "quota-unknown", 60,
                 id="no reading yet is unknown — fail closed"),
    pytest.param("policy-go · upstream-ok", "set", "fresh @ T0 − 10 → accepted", 115, "opencode", "defer", DASH, "quota-stale", 60,
                 id="a stale reading is stale"),
    pytest.param("policy-go · upstream-ok", "set", "fresh @ T0 − 20 → accepted; monthly absent @ T0 − 10 → quota-invalid", 0, "opencode",
                 "dispatch", "opencode", DASH, DASH, id="a missing window refuses the whole report, the last accepted reading stands"),
    pytest.param("policy-go · upstream-ok", "set", "fresh @ T0 − 20 → accepted; rolling resets T0 − 15, others fresh @ T0 − 10 → quota-invalid", 0,
                 "opencode", "dispatch", "opencode", DASH, DASH, id="a passed resetsAt refuses the report, the last accepted reading stands"),
    pytest.param("policy-go · upstream-ok", "set", "rolling 96 % resets T0 + 1000, others fresh @ T0 − 10 → accepted", 0, POLICY,
                 "dispatch", "openrouter", DASH, DASH, id="a limited Go rail is skipped, the walk continues"),
    pytest.param("policy-default · upstream-ok", "set", "none", 0, "opencode", "dispatch", "opencode", DASH, DASH,
                 id="no headroom block keeps today's admission ⚖"),
    pytest.param("policy-go · upstream-ok", "unset", "none", 0, "opencode", "defer", DASH, "quota-unknown", 60,
                 id="a headroom block with no usage URL sends no poll: the Go rail answers quota-unknown ⚖"),
]


@pytest.mark.parametrize(("world", "usage_url", "polls", "ask", "rail", "expected_decision", "expected_rail", "expected_reason", "expected_retry_after_s"), GO_ROWS)
async def test_go_account_headroom(settings, secrets, store, clock, reviews, pods, go_usage, caplog, world, usage_url, polls, ask, rail,
                                   expected_decision, expected_rail, expected_reason, expected_retry_after_s):
    policy = enter_world_policy(world)
    inputs(usage_url=usage_url, polls=polls, ask=ask, rail=rail)
    app, client = _go_app(settings, secrets, store, clock, reviews, pods, go_usage, policy, usage_url)
    caplog.set_level(logging.INFO)
    try:
        outcomes = []
        with given(f"polls = {polls}: each usage poll is answered at its time, then the clock stands at T0{ask:+d} s"):  # one grouped arrange step
            for at, windows, _ in GO_POLLS[polls]:
                clock.t = T0 + at
                go_usage.doc = _usage_doc(windows)
                outcomes.append(await app.state.go_usage.poll())
            clock.t = T0 + ask
        req = {"stack": "platform", "role": "worker", "task": TASK, **body_of(rail=rail)}
        async with ObservedAsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://gw") as gw:
            with when(f"POST /sessions {req}"):
                r = await gw.post("/sessions", json=req)
        assert r.status_code == 200, r.text
        doc = r.json()
        expect(doc, decision=expected_decision, rail=expected_rail, reason=expected_reason, retry_after_s=expected_retry_after_s)
        if doc.get("decision") == "defer":
            with then("a defer carries exactly decision, reason, retry_after_s",
                      keys={"expected": ["decision", "reason", "retry_after_s"], "actual": sorted(doc)}):
                assert set(doc) == {"decision", "reason", "retry_after_s"}
        then_eq("poll outcomes", outcomes, [o for _, _, o in GO_POLLS[polls]])
        then_eq("usage requests sent", len(go_usage.calls), len(GO_POLLS[polls]))
    finally:
        await client.aclose()


def enter_world_policy(world: str) -> str:
    """`enter_world` for a module that composes its own gateway: the cell's policy document name."""
    enter_world(world)
    return world.partition(" · ")[0]


POLL_ROWS = [
    pytest.param("policy-go · upstream-ok", "poll authorization", "Bearer <the Go key>", id="the poll carries the Go key"),
    pytest.param("policy-go · upstream-ok", "identity in log lines", "none", id="no identity reaches a log"),
]


@pytest.mark.parametrize(("world", "observable", "expected_value"), POLL_ROWS)
async def test_the_go_usage_poll(settings, secrets, store, clock, reviews, pods, go_usage, caplog, world, observable, expected_value):
    policy = enter_world_policy(world)
    inputs(observable=observable)
    app, client = _go_app(settings, secrets, store, clock, reviews, pods, go_usage, policy, "set")
    caplog.set_level(logging.INFO)
    try:
        clock.t = T0 - 10
        go_usage.doc = _usage_doc(FRESH)
        with given("the usage endpoint answers a fresh reading that carries a dummy identity"):
            pass
        with when("the gateway polls the Go usage endpoint once"):
            await app.state.go_usage.poll()
    finally:
        await client.aclose()
    if observable == "poll authorization":
        value = go_usage.calls[-1].headers["authorization"].replace(GO_KEY, "<the Go key>")
    else:
        assert caplog.text, "the poll logged nothing — the leak check would be vacuous"
        value = ",".join(k for k, v in DUMMY_IDENTITY.items() if v in caplog.text) or "none"
    expect({"value": value}, value=expected_value)
