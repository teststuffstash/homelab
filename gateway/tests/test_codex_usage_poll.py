"""GW-CODEX-HEADROOM §Poll — the gateway's own usage poll (specs/endpoints/openai-responses.md).

World `policy-codex`: rails.codex.headroom = max_age_s 120, ceiling 0.95, windows_minutes [300, 10080],
poll_interval_s 30. The fake usage endpoint answers the shape observed on 2026-10-22 (the spike §Live
usage payload shape) with synthetic values and DUMMY identity fields; the credential is the FAKE store's.

Poll (now T = the world clock; the stored credential expires at T+1, so the first acquire rotates it):

| description | the endpoint answers | outcome | verdict after |
|---|---|---|---|
| the observed shape is accepted, admits and renders the gauges | 200, 20 % / 64 % (5h / 7d), allowed | accepted | admit |
| the poll rides the lifecycle: one owner rotates once, the rotated bearer and the account header go out | 200 | accepted | admit |
| a missing window is refused whole — unknown, never zero | 200, secondary_window null | quota-invalid | quota-unknown |
| a window outside the profile is refused | 200, limit_window_seconds 86400 | quota-invalid | quota-unknown |
| the vendor's limit flags limit | 200, limit_reached true / allowed false | accepted | quota-limited |
| a non-bool flag or a non-integer window field is refused | 200, allowed 1 / used_percent 20.5 | quota-invalid | quota-unknown |
| an upstream 401 is counted and changes nothing | 401 after one accepted | upstream-auth | admit (unchanged) |
| a 429 or 500 is an http error, nothing accepted | 429 / 500 | upstream-http-error | quota-unknown |
| an unreachable endpoint and a timeout are told apart | connect error / read timeout | upstream-unreachable / upstream-timeout | quota-unknown |
| a non-JSON, wrong-type or oversize body is refused | text/html; application/json but not JSON; 70 KiB | upstream-content-type | quota-unknown |
| a store that does not answer is transient; a recovery marker is unresolved | (the store) | credential-transient / credential-unresolved | quota-unknown |
| identity never leaves the poll | 200 with DUMMY account/email/user ids | accepted | the report carries the schema's four keys; no log line carries an identity value |
| a dark rail has no poll | no CODEX_USAGE_URL, or no credential backend | — (not enabled) | quota-unknown |
| the schedule polls at start, before the first interval | run() | one poll before any sleep | admit |
| poll_interval_s is required and sits below max_age_s | policy 120 / absent | PolicyError | — |
| the counter's label set is the poll's outcome set | — | — | — |
| an undeclared rail renders no poll family; a declared one renders every outcome from 0 | policy-default vs policy-codex /metrics | — | the family absent / 11 series at 0 |
"""

from __future__ import annotations

import asyncio
import copy
import json
import logging
import re

import httpx
import pytest

from agent_gateway.codex import CodexBackend, CodexRail
from agent_gateway.codex_usage import OUTCOMES, UsagePoll, translate
from agent_gateway.config import Policy, PolicyError
from agent_gateway.headroom import Verdict
from agent_gateway.metrics import POLL_OUTCOMES, Metrics
from agent_gateway.oauth import Record

from ._codex_world import ACCOUNT, CODEX_BASE, CODEX_POLICY, MemoryStore, creds
from .conftest import HERE, attach_json, given, rule, then, then_eq, when, world

pytestmark = rule("GW-CODEX-HEADROOM")

USAGE_URL = "https://codex.test/backend-api/wham/usage"
OBSERVED = HERE / "fixtures" / "codex-usage-observed.json"


def usage_doc(clock, used=(20, 64), resets=(1000, 8000), allowed=True, reached=False) -> dict:
    """The observed payload shape with synthetic values (identity fields are DUMMY strings)."""
    with open(OBSERVED, encoding="utf-8") as fh:
        doc = json.load(fh)
    rl = doc["rate_limit"]
    rl["allowed"], rl["limit_reached"] = allowed, reached
    for key, u, r, span in (("primary_window", used[0], resets[0], 18000), ("secondary_window", used[1], resets[1], 604800)):
        rl[key] = {"used_percent": u, "limit_window_seconds": span, "reset_after_seconds": r, "reset_at": int(clock.t + r)}
    return doc


class FakeUsage:
    """The account usage endpoint, offline: records the request, answers what the row configures."""

    def __init__(self, clock):
        self.clock = clock
        self.status, self.ctype, self.body = 200, "application/json", None
        self.raise_ = None
        self.calls: list[httpx.Request] = []

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.calls.append(request)
        if self.raise_ is not None:
            raise self.raise_
        body = self.body if self.body is not None else json.dumps(usage_doc(self.clock)).encode()
        attach_json(f"upstream usage GET → {self.status}",
                    {"request": {"headers": {k: ("<bearer>" if k == "authorization" else v) for k, v in request.headers.items()}},
                     "response": {"status": self.status, "content-type": self.ctype, "bytes": len(body)}})
        return httpx.Response(self.status, headers={"content-type": self.ctype}, content=body)


def _rail(clock, store=None, exchange=None):
    policy = Policy.load(CODEX_POLICY).rails["codex"]
    return CodexRail(policy, clock, CodexBackend(store, exchange) if store is not None else None, CODEX_BASE)


@pytest.fixture
def usage(clock) -> FakeUsage:
    return FakeUsage(clock)


@pytest.fixture
async def poll(clock, codex_store, exchange, usage):
    client = httpx.AsyncClient(transport=httpx.MockTransport(usage.handler))
    rail, metrics = _rail(clock, codex_store, exchange), Metrics(["platform"])
    metrics.bind_codex_rail(True)  # as app.py binds it for a declared rail
    rail.headroom.on_accept = lambda snapshot: metrics.subscription_report("codex", snapshot.windows)  # as app.py binds it
    p = UsagePoll(rail, client, USAGE_URL, metrics, clock)
    yield p
    await client.aclose()


async def test_observed_shape(poll, usage):
    """row: the observed shape is accepted, admits and renders the gauges"""
    world("policy-codex")
    with when("one poll of the fixture shaped like the 2026-10-22 observation"):
        outcome = await poll.poll()
    then_eq("outcome", outcome, "accepted")
    then_eq("verdict", poll.rail.headroom.verdict(), Verdict.ADMIT)
    with then("the gauges and the poll counter render"):
        text = poll.metrics.render()
        assert 'gateway_subscription_utilization{rail="codex",window="5h"} 0.2' in text
        assert 'gateway_subscription_utilization{rail="codex",window="7d"} 0.64' in text
        assert 'gateway_codex_usage_poll_total{outcome="accepted"} 1' in text


async def test_lifecycle_owner(poll, usage, exchange, codex_store):
    """row: the poll rides the lifecycle: one owner rotates once, the rotated bearer and the account header go out"""
    world("policy-codex")
    with given("the stored credential is inside the refresh margin (expires at T+1)"):
        rotated = creds(poll.clock)[1]
    with when("one poll"):
        outcome = await poll.poll()
    then_eq("outcome", outcome, "accepted")
    then_eq("exchanges", exchange.calls, 1)
    sent = usage.calls[0].headers
    then_eq("bearer", sent["authorization"], "Bearer " + rotated.access_token)
    then_eq("account header", sent["chatgpt-account-id"], ACCOUNT)
    then_eq("accept", sent["accept"], "application/json")
    then_eq("stored record state", codex_store.record.state, "ready")


async def test_missing_window(poll, usage, clock):
    """row: a missing window is refused whole — unknown, never zero"""
    world("policy-codex")
    doc = usage_doc(clock)
    doc["rate_limit"]["secondary_window"] = None
    usage.body = json.dumps(doc).encode()
    with when("one poll answered with a null secondary window"):
        outcome = await poll.poll()
    then_eq("outcome", outcome, "quota-invalid")
    then_eq("verdict", poll.rail.headroom.verdict(), Verdict.UNKNOWN)


async def test_window_outside_profile(poll, usage, clock):
    """row: a window outside the profile is refused"""
    world("policy-codex")
    doc = usage_doc(clock)
    doc["rate_limit"]["secondary_window"]["limit_window_seconds"] = 86400
    usage.body = json.dumps(doc).encode()
    with when("one poll answered with a 1-day secondary window"):
        outcome = await poll.poll()
    then_eq("outcome", outcome, "quota-invalid")
    then_eq("verdict", poll.rail.headroom.verdict(), Verdict.UNKNOWN)


@pytest.mark.parametrize("flags", [{"reached": True}, {"allowed": False}])
async def test_limit_flags(poll, usage, clock, flags):
    """row: the vendor's limit flags limit"""
    world("policy-codex")
    usage.body = json.dumps(usage_doc(clock, **flags)).encode()
    with when(f"one poll answered with {flags}"):
        outcome = await poll.poll()
    then_eq("outcome", outcome, "accepted")
    then_eq("verdict", poll.rail.headroom.verdict(), Verdict.LIMITED)


@pytest.mark.parametrize("mutate", [
    lambda d: d["rate_limit"].__setitem__("allowed", 1),
    lambda d: d["rate_limit"]["primary_window"].__setitem__("used_percent", 20.5),
    lambda d: d["rate_limit"]["primary_window"].__setitem__("reset_at", "soon"),
    lambda d: d.__setitem__("rate_limit", []),
])
async def test_malformed_fields(poll, usage, clock, mutate):
    """row: a non-bool flag or a non-integer window field is refused"""
    world("policy-codex")
    doc = usage_doc(clock)
    mutate(doc)
    usage.body = json.dumps(doc).encode()
    with when("one poll answered with a malformed field"):
        outcome = await poll.poll()
    then_eq("outcome", outcome, "quota-invalid")
    then_eq("verdict", poll.rail.headroom.verdict(), Verdict.UNKNOWN)


async def test_upstream_auth_unchanged(poll, usage):
    """row: an upstream 401 is counted and changes nothing"""
    world("policy-codex")
    with given("one accepted poll"):
        assert await poll.poll() == "accepted"
        poll.clock.t += 5
    usage.status = 401
    usage.body = b'{"detail":"DUMMY-SECRET-LEAK"}'
    with when("the next poll is answered 401"):
        outcome = await poll.poll()
    then_eq("outcome", outcome, "upstream-auth")
    then_eq("verdict", poll.rail.headroom.verdict(), Verdict.ADMIT, "the last accepted report stands")
    with then("the counter saw both"):
        text = poll.metrics.render()
        assert 'gateway_codex_usage_poll_total{outcome="accepted"} 1' in text
        assert 'gateway_codex_usage_poll_total{outcome="upstream-auth"} 1' in text


@pytest.mark.parametrize("status", [429, 500])
async def test_http_error(poll, usage, status):
    """row: a 429 or 500 is an http error, nothing accepted"""
    world("policy-codex")
    usage.status, usage.body = status, b'{"error":"DUMMY"}'
    with when(f"one poll answered {status}"):
        outcome = await poll.poll()
    then_eq("outcome", outcome, "upstream-http-error")
    then_eq("verdict", poll.rail.headroom.verdict(), Verdict.UNKNOWN)


@pytest.mark.parametrize("fault,expected", [(httpx.ConnectError("refused"), "upstream-unreachable"),
                                            (httpx.ReadTimeout("slow"), "upstream-timeout")])
async def test_transport(poll, usage, fault, expected):
    """row: an unreachable endpoint and a timeout are told apart"""
    world("policy-codex")
    usage.raise_ = fault
    with when(f"one poll meets {type(fault).__name__}"):
        outcome = await poll.poll()
    then_eq("outcome", outcome, expected)
    then_eq("verdict", poll.rail.headroom.verdict(), Verdict.UNKNOWN)


@pytest.mark.parametrize("ctype,body", [("text/html", b"<html>DUMMY</html>"), ("application/json", b"{not json"),
                                        ("application/json", b"[" + b"1," * 40000 + b"1]")],
                         ids=["html body", "not json", "oversize json"])
async def test_body_refused(poll, usage, ctype, body):
    """row: a non-JSON, wrong-type or oversize body is refused"""
    world("policy-codex")
    usage.ctype, usage.body = ctype, body
    with when(f"one poll answered {ctype}, {len(body)} bytes"):
        outcome = await poll.poll()
    then_eq("outcome", outcome, "upstream-content-type")
    then_eq("verdict", poll.rail.headroom.verdict(), Verdict.UNKNOWN)


class _DeadStore(MemoryStore):
    def lock(self):
        raise RuntimeError("DUMMY-SECRET storage detail")


async def test_credential_failures(clock, usage, exchange):
    """row: a store that does not answer is transient; a recovery marker is unresolved"""
    world("policy-codex")
    client = httpx.AsyncClient(transport=httpx.MockTransport(usage.handler))
    try:
        dead = UsagePoll(_rail(clock, _DeadStore(creds(clock)[0]), exchange), client, USAGE_URL, Metrics(["platform"]), clock)
        marked = MemoryStore(creds(clock)[0])
        marked.record = Record(marked.record.credential, "refreshing")
        stuck = UsagePoll(_rail(clock, marked, exchange), client, USAGE_URL, Metrics(["platform"]), clock)
        with when("a poll on a store that does not answer, and one on a persisted refreshing marker"):
            a, b = await dead.poll(), await stuck.poll()
    finally:
        await client.aclose()
    then_eq("dead store", a, "credential-transient")
    then_eq("recovery marker", b, "credential-unresolved")
    then_eq("upstream contacted", len(usage.calls), 0)
    then_eq("verdict", stuck.rail.headroom.verdict(), Verdict.UNKNOWN)


async def test_identity_never_leaves(poll, usage, clock, caplog):
    """row: identity never leaves the poll"""
    world("policy-codex")
    doc = usage_doc(clock)
    identity = {doc["account_id"], doc["email"], doc["user_id"]}
    assert all(v.startswith("DUMMY") for v in identity)
    usage.body = json.dumps(doc).encode()
    with when("one poll, at DEBUG logging"), caplog.at_level(logging.DEBUG, logger="gateway"):
        outcome = await poll.poll()
    then_eq("outcome", outcome, "accepted")
    then_eq("report keys", sorted(translate(copy.deepcopy(doc), clock.t)), ["limited", "observed_at", "source", "windows"])
    with then("no log line carries an identity value"):
        for record in caplog.records:
            assert not any(v in record.getMessage() for v in identity), record.getMessage()


async def test_dark(clock, codex_store, exchange, usage):
    """row: a dark rail has no poll"""
    world("policy-codex")
    client = httpx.AsyncClient(transport=httpx.MockTransport(usage.handler))
    try:
        no_url = UsagePoll(_rail(clock, codex_store, exchange), client, "", Metrics(["platform"]), clock)
        no_backend = UsagePoll(_rail(clock), client, USAGE_URL, Metrics(["platform"]), clock)
        with when("neither has what a poll needs"):
            enabled = (no_url.enabled, no_backend.enabled)
        then_eq("enabled", enabled, (False, False))
        with then("a forced poll contacts nothing"):
            for p in (no_url, no_backend):
                with pytest.raises(RuntimeError):
                    await p.poll()
            assert usage.calls == []
        then_eq("verdict", no_backend.rail.headroom.verdict(), Verdict.UNKNOWN)
    finally:
        await client.aclose()


async def test_schedule_polls_at_start(poll, usage):
    """row: the schedule polls at start, before the first interval"""
    world("policy-codex")
    with when("run() is started"):
        task = asyncio.create_task(poll.run())
        for _ in range(100):
            if poll.polls:
                break
            await asyncio.sleep(0.01)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
    then_eq("polls before the first interval elapsed", poll.polls, 1)
    then_eq("verdict", poll.rail.headroom.verdict(), Verdict.ADMIT)


@pytest.mark.parametrize("interval", [120, 0, None, True])
def test_policy_interval(interval):
    """row: poll_interval_s is required and sits below max_age_s"""
    world("policy-codex")
    with open(CODEX_POLICY, encoding="utf-8") as fh:
        doc = json.load(fh)
    h = doc["rails"]["codex"]["headroom"]
    if interval is None:
        del h["poll_interval_s"]
    else:
        h["poll_interval_s"] = interval
    with when(f"the policy loads with poll_interval_s = {interval!r} (max_age_s 120)"), pytest.raises(PolicyError) as e:
        Policy.from_dict(doc)
    then_eq("error", "poll_interval_s" in str(e.value), True)


async def test_family_only_when_declared(settings, policy, codex_policy, secrets, store, clock, codex_store, exchange):
    """row: an undeclared rail renders no poll family; a declared one renders every outcome from 0"""
    world("policy-default")
    from agent_gateway.app import create_app
    with when("GET /metrics on an app under policy-default (no codex rail) and one under policy-codex (declared, nothing polled)"):
        texts = {}
        for name, pol, backend in (("policy-default", policy, None), ("policy-codex", codex_policy, CodexBackend(codex_store, exchange))):
            app = create_app(settings, policy=pol, source=secrets, store=store, clock=clock, codex_backend=backend)
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://gw") as c:
                texts[name] = (await c.get("/metrics")).text
    then_eq("series under policy-default", texts["policy-default"].count("gateway_codex_usage_poll_total{"), 0,
            claim="an undeclared rail renders no gateway_codex_usage_poll_total series — CodexUsagePollSilent cannot fire on it")
    then_eq("series under policy-codex", sorted(re.findall(r'gateway_codex_usage_poll_total\{outcome="([^"]+)"\} 0', texts["policy-codex"])),
            sorted(OUTCOMES), claim="a declared rail renders every outcome from 0")


def test_outcome_sets_agree():
    """row: the counter's label set is the poll's outcome set"""
    world("policy-codex")
    then_eq("outcomes", tuple(POLL_OUTCOMES), tuple(OUTCOMES))
