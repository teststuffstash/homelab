"""GW-CODEX-USAGE-POLL — the gateway's own usage poll (specs/endpoints/openai-responses.md
§GW-CODEX-USAGE-POLL: the answer becomes a report, a failed poll leaves the last report standing, the
poll's owner and schedule, the poll counter).

World `policy-codex`: rails.codex.headroom = max_age_s 120, ceiling 0.95, windows_minutes [300, 10080],
poll_interval_s 30. The fake usage endpoint answers the shape observed on 2026-10-22 (the spike §Live
usage payload shape) with synthetic values and DUMMY identity fields; the credential is the FAKE store's,
expiring at T+1 so the first acquire rotates it. Argnames = each table's header, ids = its description
cells.
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
from agent_gateway.metrics import POLL_OUTCOMES, Metrics
from agent_gateway.oauth import Record

from ._codex_rows import expect, joined, row, verdicts
from ._codex_world import ACCOUNT, CODEX_BASE, CODEX_POLICY, MemoryStore, creds
from .conftest import HERE, attach_json, given, rule, then, then_eq, when, world

pytestmark = rule("GW-CODEX-USAGE-POLL")

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


def _verdict(p: UsagePoll) -> str:
    return str(p.rail.headroom.verdict())


# -- the answer becomes a report ------------------------------------------------------------------

def _mutations(clock) -> list[callable]:
    def allowed_int(d):
        d["rate_limit"]["allowed"] = 1

    def used_float(d):
        d["rate_limit"]["primary_window"]["used_percent"] = 20.5

    def reset_str(d):
        d["rate_limit"]["primary_window"]["reset_at"] = "soon"

    def rl_list(d):
        d["rate_limit"] = []
    return [allowed_int, used_float, reset_str, rl_list]


ANSWERS = {  # the `answer` cell → the usage documents the endpoint answers, in turn
    "200, 20 % / 64 % (5h / 7d), allowed": lambda c: [usage_doc(c)],
    "200, limit_reached: true": lambda c: [usage_doc(c, reached=True)],
    "200, allowed: false": lambda c: [usage_doc(c, allowed=False)],
    "200, secondary_window: null": lambda c: [dict(usage_doc(c), rate_limit={**usage_doc(c)["rate_limit"], "secondary_window": None})],
    "200, limit_window_seconds: 86400": lambda c: [_with(usage_doc(c), lambda d: d["rate_limit"]["secondary_window"].__setitem__("limit_window_seconds", 86400))],
    '200, allowed: 1 / used_percent: 20.5 / reset_at: "soon" / rate_limit: []': lambda c: [_with(usage_doc(c), m) for m in _mutations(c)],
    "200 with DUMMY account / email / user ids": lambda c: [usage_doc(c)],
}


def _with(doc: dict, mutate) -> dict:
    mutate(doc)
    return doc


@pytest.mark.parametrize(("answer", "expected_outcome", "expected_verdict"), [
    pytest.param("200, 20 % / 64 % (5h / 7d), allowed", "accepted", "admit", id="the observed shape is accepted, admits and renders the gauges"),
    pytest.param("200, limit_reached: true", "accepted", "quota-limited", id="the vendor's limit_reached flag limits"),
    pytest.param("200, allowed: false", "accepted", "quota-limited", id="a not-allowed answer limits"),
    pytest.param("200, secondary_window: null", "quota-invalid", "quota-unknown", id="a missing window is refused whole — unknown, never zero ⚖"),
    pytest.param("200, limit_window_seconds: 86400", "quota-invalid", "quota-unknown", id="a window outside the profile is refused"),
    pytest.param('200, allowed: 1 / used_percent: 20.5 / reset_at: "soon" / rate_limit: []', "quota-invalid", "quota-unknown",
                 id="a non-bool flag or a non-integer window field is refused"),
    pytest.param("200 with DUMMY account / email / user ids", "accepted", "admit", id="identity never leaves the poll"),
])
async def test_answer_becomes_report(poll, usage, clock, caplog, answer, expected_outcome, expected_verdict):
    world("policy-codex")
    row(answer=answer, expected_outcome=expected_outcome, expected_verdict=expected_verdict)
    docs = ANSWERS[answer](clock)
    identity = {docs[0]["account_id"], docs[0]["email"], docs[0]["user_id"]}
    assert all(v.startswith("DUMMY") for v in identity)
    outcomes = []
    with when(f"the endpoint answers {answer} ({len(docs)} variant{'s' if len(docs) > 1 else ''}), one poll each"), \
         caplog.at_level(logging.DEBUG, logger="gateway"):
        for doc in docs:
            usage.body = json.dumps(doc).encode()
            outcomes.append(await poll.poll())
    verdicts(
        outcome=(joined(outcomes), expected_outcome),
        verdict=(_verdict(poll), expected_verdict),
    )
    text = poll.metrics.render()
    if answer.startswith("200, 20 %"):
        with then("the gauges and the poll counter render: utilization 5h 0.2, 7d 0.64; accepted 1"):
            assert 'gateway_subscription_utilization{rail="codex",window="5h"} 0.2' in text
            assert 'gateway_subscription_utilization{rail="codex",window="7d"} 0.64' in text
            assert 'gateway_codex_usage_poll_total{outcome="accepted"} 1' in text
    if answer.startswith("200 with DUMMY"):
        then_eq("report keys", sorted(translate(copy.deepcopy(docs[0]), clock.t)), ["limited", "observed_at", "source", "windows"])
        with then("no log line at DEBUG carries an identity value"):
            for record in caplog.records:
                assert not any(v in record.getMessage() for v in identity), record.getMessage()


# -- a failed poll leaves the last report standing ------------------------------------------------

class _DeadStore(MemoryStore):
    def lock(self):
        raise RuntimeError("DUMMY-SECRET storage detail")


@pytest.mark.parametrize(("last_report", "answer", "expected_outcome", "expected_verdict"), [
    pytest.param("accepted", "401", "upstream-auth", "admit", id="an upstream 401 is counted and changes nothing ⚖"),
    pytest.param("none", "429 / 500", "upstream-http-error", "quota-unknown", id="a 429 or 500 is an http error, nothing accepted"),
    pytest.param("none", "connect error / read timeout", "upstream-unreachable / upstream-timeout", "quota-unknown",
                 id="an unreachable endpoint and a timeout are told apart"),
    pytest.param("none", "text/html / application/json that is not JSON / 70 KiB (bound 64 KiB)", "upstream-content-type", "quota-unknown",
                 id="a non-JSON, wrong-type or oversize body is refused ⚖"),
    pytest.param("none", "(the store)", "credential-transient / credential-unresolved", "quota-unknown",
                 id="a store that does not answer is transient; a recovery marker is unresolved"),
])
async def test_failed_poll(poll, usage, clock, exchange, last_report, answer, expected_outcome, expected_verdict):
    world("policy-codex")
    row(last_report=last_report, answer=answer, expected_outcome=expected_outcome, expected_verdict=expected_verdict)
    with given(f"last_report {last_report}"):
        if last_report == "accepted":
            assert await poll.poll() == "accepted"
            clock.t += 5
    outcomes: list[str] = []
    if answer == "(the store)":
        client = httpx.AsyncClient(transport=httpx.MockTransport(usage.handler))
        try:
            dead = UsagePoll(_rail(clock, _DeadStore(creds(clock)[0]), exchange), client, USAGE_URL, Metrics(["platform"]), clock)
            marked = MemoryStore(creds(clock)[0])
            marked.record = Record(marked.record.credential, "refreshing")
            stuck = UsagePoll(_rail(clock, marked, exchange), client, USAGE_URL, Metrics(["platform"]), clock)
            with when(f"the endpoint answers {answer}: a poll on a store that does not answer, one on a persisted refreshing marker"):
                outcomes = [await dead.poll(), await stuck.poll()]
        finally:
            await client.aclose()
        then_eq("upstream contacted", len(usage.calls), 0, claim="the endpoint is never contacted")
        poll = stuck
    else:
        variants: list[tuple] = []
        if answer == "401":
            variants = [(401, "application/json", b'{"detail":"DUMMY-SECRET-LEAK"}', None)]
        elif answer == "429 / 500":
            variants = [(429, "application/json", b'{"error":"DUMMY"}', None), (500, "application/json", b'{"error":"DUMMY"}', None)]
        elif answer.startswith("connect error"):
            variants = [(200, "application/json", None, httpx.ConnectError("refused")), (200, "application/json", None, httpx.ReadTimeout("slow"))]
        else:
            variants = [(200, "text/html", b"<html>DUMMY</html>", None), (200, "application/json", b"{not json", None),
                        (200, "application/json", b"[" + b"1," * 40000 + b"1]", None)]
        with when(f"the endpoint answers {answer} ({len(variants)} variant{'s' if len(variants) > 1 else ''}), one poll each"):
            for status, ctype, body, fault in variants:
                usage.status, usage.ctype, usage.body, usage.raise_ = status, ctype, body, fault
                outcomes.append(await poll.poll())
    verdicts(
        outcome=(joined(outcomes), expected_outcome),
        verdict=(_verdict(poll), expected_verdict),
    )
    if answer == "401":
        with then("the counter saw both: accepted 1, upstream-auth 1"):
            text = poll.metrics.render()
            assert 'gateway_codex_usage_poll_total{outcome="accepted"} 1' in text
            assert 'gateway_codex_usage_poll_total{outcome="upstream-auth"} 1' in text


# -- the poll's owner and schedule ----------------------------------------------------------------

LIFECYCLE_CELL = "accepted; one exchange; the rotated bearer, chatgpt-account-id and accept: application/json sent; the store ready"


@pytest.mark.parametrize(("arranged", "expected_result"), [
    pytest.param("the stored credential 1 s from expiry", LIFECYCLE_CELL,
                 id="the poll rides the lifecycle: one owner rotates once, the rotated bearer and the account header go out ⚖"),
    pytest.param("no CODEX_USAGE_URL, or no credential backend", "not enabled; a forced poll contacts nothing; quota-unknown", id="a dark rail has no poll"),
    pytest.param("run() started", "one poll before any sleep; admit", id="the schedule polls at start, before the first interval ⚖"),
    pytest.param("poll_interval_s 120 / 0 / absent / true, max_age_s 120", "PolicyError naming poll_interval_s",
                 id="poll_interval_s is required and sits below max_age_s"),
])
async def test_owner_and_schedule(poll, usage, exchange, codex_store, clock, arranged, expected_result):
    world("policy-codex")
    row(arranged=arranged, expected_result=expected_result)
    if arranged.startswith("the stored credential"):
        with given(f"arranged {arranged} (inside the refresh margin)"):
            rotated = creds(clock)[1]
        with when("one poll"):
            outcome = await poll.poll()
        sent = usage.calls[0].headers
        headers_ok = (sent["authorization"] == "Bearer " + rotated.access_token and sent["chatgpt-account-id"] == ACCOUNT
                      and sent["accept"] == "application/json")
        result = (f"{outcome}; {'one exchange' if exchange.calls == 1 else f'{exchange.calls} exchanges'}; "
                  + ("the rotated bearer, chatgpt-account-id and accept: application/json sent" if headers_ok else f"sent {dict(sent)}")
                  + f"; the store {codex_store.record.state}")
    elif arranged.startswith("no CODEX_USAGE_URL"):
        client = httpx.AsyncClient(transport=httpx.MockTransport(usage.handler))
        try:
            no_url = UsagePoll(_rail(clock, codex_store, exchange), client, "", Metrics(["platform"]), clock)
            no_backend = UsagePoll(_rail(clock), client, USAGE_URL, Metrics(["platform"]), clock)
            with when(f"arranged {arranged}: a forced poll on each"):
                enabled = (no_url.enabled, no_backend.enabled)
                refused = 0
                for p in (no_url, no_backend):
                    try:
                        await p.poll()
                    except RuntimeError:
                        refused += 1
            result = (f"{'not enabled' if enabled == (False, False) else f'enabled {enabled}'}; a forced poll contacts "
                      f"{'nothing' if not usage.calls and refused == 2 else f'{len(usage.calls)} time(s)'}; {_verdict(no_backend)}")
        finally:
            await client.aclose()
    elif arranged.startswith("run()"):
        with when(f"arranged {arranged}"):
            task = asyncio.create_task(poll.run())
            for _ in range(100):
                if poll.polls:
                    break
                await asyncio.sleep(0.01)
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task
        result = f"{'one poll' if poll.polls == 1 else f'{poll.polls} polls'} before any sleep; {_verdict(poll)}"
    else:
        with open(CODEX_POLICY, encoding="utf-8") as fh:
            base = json.load(fh)
        errors = []
        with when(f"the policy loads with {arranged}"):
            for interval in (120, 0, None, True):
                doc = copy.deepcopy(base)
                h = doc["rails"]["codex"]["headroom"]
                if interval is None:
                    del h["poll_interval_s"]
                else:
                    h["poll_interval_s"] = interval
                try:
                    Policy.from_dict(doc)
                    errors.append("loaded")
                except PolicyError as e:
                    errors.append("PolicyError naming poll_interval_s" if "poll_interval_s" in str(e) else f"PolicyError: {e}")
        result = joined(errors, " / ")
    expect("result", result, expected_result)


# -- the poll counter -----------------------------------------------------------------------------

@pytest.mark.parametrize(("policies", "expected_series"), [
    pytest.param("policy-default / policy-codex", "none / the 11 outcomes, each 0",
                 id="an undeclared rail renders no poll family; a declared one renders every outcome from 0 ⚖"),
    pytest.param("—", "outcome values = the poll's outcomes", id="the counter's label set is the poll's outcome set"),
])
async def test_poll_counter(settings, policy, codex_policy, secrets, store, clock, codex_store, exchange, policies, expected_series):
    world("policy-default" if policies.startswith("policy-default") else "policy-codex")
    row(policies=policies, expected_series=expected_series)
    if policies == "—":
        with when("compare metrics.POLL_OUTCOMES with codex_usage.OUTCOMES"):
            same = tuple(POLL_OUTCOMES) == tuple(OUTCOMES)
        expect("series", "outcome values = the poll's outcomes" if same else f"{POLL_OUTCOMES} ≠ {OUTCOMES}", expected_series)
        return
    from agent_gateway.app import create_app
    with when(f"GET /metrics on an app under each of policies {policies} (declared, nothing polled)"):
        texts = {}
        for name, pol, backend in (("policy-default", policy, None), ("policy-codex", codex_policy, CodexBackend(codex_store, exchange))):
            app = create_app(settings, policy=pol, source=secrets, store=store, clock=clock, codex_backend=backend)
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://gw") as c:
                texts[name] = (await c.get("/metrics")).text
    default = texts["policy-default"].count("gateway_codex_usage_poll_total{")
    zeros = sorted(re.findall(r'gateway_codex_usage_poll_total\{outcome="([^"]+)"\} 0', texts["policy-codex"]))
    expect("series", ("none" if default == 0 else f"{default} series") + " / "
           + (f"the {len(OUTCOMES)} outcomes, each 0" if zeros == sorted(OUTCOMES) else f"{zeros}"), expected_series)
