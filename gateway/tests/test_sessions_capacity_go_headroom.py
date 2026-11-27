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
import re
from datetime import UTC, datetime

import httpx
import pytest

from agent_gateway import __version__
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
        self.answer = None  # None = 200 application/json of `doc`; else a (status, content-type, body) or an exception to raise

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        if str(request.url) != GO_USAGE_URL:
            return await self.rest.handle_async_request(request)
        self.calls.append(request)
        if isinstance(self.answer, Exception):
            raise self.answer
        if self.answer is not None:
            status, ctype, content = self.answer
            return httpx.Response(status, headers={"content-type": ctype}, content=content)
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
                 id="no reading yet is unknown — fail closed ⚖"),
    pytest.param("policy-go · upstream-ok", "set", "fresh @ T0 − 10 → accepted", 115, "opencode", "defer", DASH, "quota-stale", 60,
                 id="a stale reading is stale ⚖"),
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
    pytest.param("policy-go · upstream-ok", "poll user-agent", "agent-gateway/<version> (go-usage)", id="the poll names the gateway ⚖"),
    pytest.param("policy-go · upstream-ok", "poll x-opencode-session", "absent", id="the poll carries no session header ⚖"),
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
    elif observable == "poll user-agent":
        value = go_usage.calls[-1].headers["user-agent"].replace(__version__, "<version>")
    elif observable == "poll x-opencode-session":
        value = go_usage.calls[-1].headers.get("x-opencode-session", "absent")
    else:
        assert caplog.text, "the poll logged nothing — the leak check would be vacuous"
        value = ",".join(k for k, v in DUMMY_IDENTITY.items() if v in caplog.text) or "none"
    expect({"value": value}, value=expected_value)


# -- the gauges and the counter: read off GET /metrics ---------------------------------------------
GAUGE_POLLS = {
    "fresh @ T0 − 10 → accepted": GO_POLLS["fresh @ T0 − 10 → accepted"],
    "fresh @ T0 − 20 → accepted; rolling 50 % resets T0 − 15, others fresh @ T0 − 10 → quota-invalid":
        [(-20, FRESH, "accepted"), (-10, {**FRESH, "rolling": ("ok", 50, -15)}, "quota-invalid")],
    "none": [],
}
GO_WINDOWS = ("rolling", "weekly", "monthly")


def _series(text: str, family: str) -> dict[str, float]:
    """`{labels: value}` of one family's samples in the exposition."""
    return {m.group(1): float(m.group(2)) for m in re.finditer(r"^" + family + r"\{([^}]*)\} (\S+)$", text, re.M)}


async def _scrape(app) -> str:
    async with ObservedAsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://gw") as gw:
        with when("GET /metrics"):
            r = await gw.get("/metrics")
    assert r.status_code == 200
    return r.text


def _fmt(values: list[float | None]) -> str:
    return "absent" if all(v is None for v in values) else " / ".join("absent" if v is None else f"{v:g}" for v in values)


GAUGE_ROWS = [
    pytest.param("policy-go · upstream-ok", "set", "fresh @ T0 − 10 → accepted", "0.2 / 0.46 / 0.36", "T0 + 18000 / T0 + 80000 / T0 + 2000000",
                 id="an accepted reading renders both gauges per window"),
    pytest.param("policy-go · upstream-ok", "set", "fresh @ T0 − 20 → accepted; rolling 50 % resets T0 − 15, others fresh @ T0 − 10 → quota-invalid",
                 "0.2 / 0.46 / 0.36", "T0 + 18000 / T0 + 80000 / T0 + 2000000", id="a refused reading leaves the gauges unchanged ⚖"),
    pytest.param("policy-go · upstream-ok", "set", "none", "absent", "absent", id="no accepted reading, no opencode series"),
    pytest.param("policy-default · upstream-ok", "set", "none", "absent", "absent", id="no headroom block, no opencode series ⚖"),
]


@pytest.mark.parametrize(("world", "usage_url", "polls", "expected_utilization", "expected_reset_seconds"), GAUGE_ROWS)
async def test_the_reading_renders_the_gauges(settings, secrets, store, clock, reviews, pods, go_usage, world, usage_url, polls,
                                              expected_utilization, expected_reset_seconds):
    policy = enter_world_policy(world)
    inputs(usage_url=usage_url, polls=polls)
    app, client = _go_app(settings, secrets, store, clock, reviews, pods, go_usage, policy, usage_url)
    try:
        with given(f"polls = {polls}"):
            for at, windows, _ in GAUGE_POLLS[polls]:
                clock.t = T0 + at
                go_usage.doc = _usage_doc(windows)
                if "opencode" in policy_rails(policy):
                    await app.state.go_usage.poll()
        clock.t = T0
        text = await _scrape(app)
    finally:
        await client.aclose()
    util, reset = _series(text, "gateway_subscription_utilization"), _series(text, "gateway_subscription_reset_seconds")
    got_util = _fmt([util.get(f'rail="opencode",window="{w}"') for w in GO_WINDOWS])
    resets = [reset.get(f'rail="opencode",window="{w}"') for w in GO_WINDOWS]
    got_reset = " / ".join("absent" if v is None else f"T0 + {v - T0:.0f}" for v in resets) if any(v is not None for v in resets) else "absent"
    expect({"utilization": got_util, "reset_seconds": got_reset}, utilization=expected_utilization, reset_seconds=expected_reset_seconds)


def policy_rails(policy: str) -> list[str]:
    """The rails whose policy carries a headroom block (the poll exists only for those)."""
    doc = json.loads((HERE / "fixtures" / f"{policy}.json").read_text())
    return [r for r, v in doc["rails"].items() if "headroom" in v]


FAIL_ANSWERS = {
    "401 / 403": [("status", 401), ("status", 403)],
    "429 / 500": [("status", 429), ("status", 500)],
    "connect error / read timeout": [("raise", httpx.ConnectError("refused")), ("raise", httpx.ReadTimeout("slow"))],
    "200 text/html / 200 application/json that is not JSON / 200 application/json of 70 KiB (bound 64 KiB)":
        [("body", (200, "text/html", b"<html></html>")), ("body", (200, "application/json", b"{not json")),
         ("body", (200, "application/json", b'{"usage": {}, "pad": "' + b"x" * 70 * 1024 + b'"}'))],
    "200 application/json `[]` / 200 application/json `{\"usage\": []}`":
        [("body", (200, "application/json", b"[]")), ("body", (200, "application/json", b'{"usage": []}'))],
    "(the key) the Go key mount is empty": [("nokey", None)],
}

FAIL_ROWS = [
    pytest.param("policy-go · upstream-ok", "accepted", "401 / 403", "upstream-auth", "admit", id="an upstream 401 or 403 is counted and changes nothing ⚖"),
    pytest.param("policy-go · upstream-ok", "none", "429 / 500", "upstream-http-error", "quota-unknown", id="a 429 or a 500 is an http error, nothing accepted"),
    pytest.param("policy-go · upstream-ok", "none", "connect error / read timeout", "upstream-unreachable / upstream-timeout", "quota-unknown",
                 id="an unreachable endpoint and a timeout are told apart"),
    pytest.param("policy-go · upstream-ok", "none",
                 "200 text/html / 200 application/json that is not JSON / 200 application/json of 70 KiB (bound 64 KiB)",
                 "upstream-content-type", "quota-unknown", id="a body that is not JSON is refused ⚖"),
    pytest.param("policy-go · upstream-ok", "none", "200 application/json `[]` / 200 application/json `{\"usage\": []}`", "quota-invalid", "quota-unknown",
                 id="a JSON answer that is no reading is refused as a reading, not as a content type ⚖"),
    pytest.param("policy-go · upstream-ok", "none", "(the key) the Go key mount is empty", "credential-unresolved", "quota-unknown",
                 id="an empty Go key mount is counted, the endpoint never contacted ⚖"),
]


@pytest.mark.parametrize(("world", "last_reading", "answer", "expected_outcome", "expected_verdict"), FAIL_ROWS)
async def test_a_failed_poll_is_counted(settings, secrets, store, clock, reviews, pods, go_usage, world, last_reading, answer,
                                        expected_outcome, expected_verdict):
    policy = enter_world_policy(world)
    inputs(last_reading=last_reading, answer=answer)
    outcomes, verdicts, counted, contacted = [], [], [], []
    with given(f"last_reading = {last_reading}; each variant of answer = {answer} is offered to its own gateway"):
        apps = []
        for kind, arg in FAIL_ANSWERS[answer]:
            cfg = dataclasses.replace(settings, opencode_go_api_key="") if kind == "nokey" else settings
            app, client = _go_app(cfg, secrets, store, clock, reviews, pods, go_usage, policy, "set")
            apps.append((kind, arg, app, client))
    try:
        with when("the gateway polls once more, after the last reading"):
            for kind, arg, app, _client in apps:
                go_usage.answer = None
                if last_reading == "accepted":
                    clock.t = T0 - 5
                    go_usage.doc = _usage_doc(FRESH)
                    assert await app.state.go_usage.poll() == "accepted"
                clock.t = T0
                before = len(go_usage.calls)
                go_usage.answer = (arg, "text/plain", b"no") if kind == "status" else arg if kind in ("raise", "body") else None
                outcomes.append(await app.state.go_usage.poll())
                contacted.append(len(go_usage.calls) - before)
                verdicts.append(app.state.go_usage.headroom.verdict().value)
                counted.append(app.state.metrics.go_poll_total.get(outcomes[-1], 0))
    finally:
        go_usage.answer = None
        for *_, client in apps:
            await client.aclose()
    expect({"outcome": " / ".join(dict.fromkeys(outcomes)) if len(set(outcomes)) == 1 else " / ".join(outcomes), "verdict": verdicts[0]},
           outcome=expected_outcome, verdict=expected_verdict)
    then_eq("every variant ended on the same verdict", set(verdicts), {expected_verdict})
    then_eq("every variant's outcome was counted", all(n >= 1 for n in counted), True)
    if answer.startswith("(the key)"):
        then_eq("the endpoint was never contacted", contacted, [0])


COUNTER_POLLS = {
    "—": [],
    "fresh @ T0 − 20 → accepted; monthly absent @ T0 − 10 → quota-invalid": GO_POLLS["fresh @ T0 − 20 → accepted; monthly absent @ T0 − 10 → quota-invalid"],
    "fresh @ T0 − 10 → accepted; rolling 50 %, others fresh @ T0 − 10 → quota-out-of-order":
        [(-10, FRESH, "accepted"), (-10, {**FRESH, "rolling": ("ok", 50, 18000)}, "quota-out-of-order")],
}
OUTCOMES = ("accepted", "quota-invalid", "quota-time-invalid", "quota-out-of-order", "credential-unresolved", "upstream-auth",
            "upstream-http-error", "upstream-content-type", "upstream-unreachable", "upstream-timeout")

COUNTER_ROWS = [
    pytest.param("policy-default / policy-go", "set", "—", "none / the 10 outcomes, each 0",
                 id="a policy without the headroom block renders no poll family; one with it renders every outcome from 0 ⚖"),
    pytest.param("policy-go", "unset", "—", "the 10 outcomes, each 0",
                 id="the headroom block without a usage URL still renders every outcome from 0: the poll is dark, the family is not ⚖"),
    pytest.param("policy-go", "set", "fresh @ T0 − 20 → accepted; monthly absent @ T0 − 10 → quota-invalid",
                 "accepted 1 · quota-invalid 1 · the other eight 0", id="each poll adds one to its outcome"),
    pytest.param("policy-go", "set", "fresh @ T0 − 10 → accepted; rolling 50 %, others fresh @ T0 − 10 → quota-out-of-order",
                 "accepted 1 · quota-out-of-order 1 · the other eight 0", id="a second reading in the same instant is counted out of order ⚖"),
]


def _describe(series: dict[str, float]) -> str:
    if not series:
        return "none"
    assert set(series) == {f'outcome="{o}"' for o in OUTCOMES}, sorted(series)
    nonzero = [(k[len('outcome="'):-1], v) for k, v in series.items() if v]
    if not nonzero:
        return "the 10 outcomes, each 0"
    assert len(nonzero) == 2, nonzero
    order = {o: i for i, o in enumerate(OUTCOMES)}
    nonzero.sort(key=lambda kv: order[kv[0]])
    return " · ".join(f"{k} {v:g}" for k, v in nonzero) + " · the other eight 0"


@pytest.mark.parametrize(("policies", "usage_url", "polls", "expected_series"), COUNTER_ROWS)
async def test_the_poll_counter(settings, secrets, store, clock, reviews, pods, go_usage, policies, usage_url, polls, expected_series):
    inputs(policies=policies, usage_url=usage_url, polls=polls)
    seen = []
    for policy in policies.split(" / "):
        enter_world_policy(f"{policy} · upstream-ok")
        app, client = _go_app(settings, secrets, store, clock, reviews, pods, go_usage, policy, usage_url)
        try:
            with given(f"polls = {polls}"):
                for at, windows, _ in COUNTER_POLLS[polls]:
                    clock.t = T0 + at
                    go_usage.doc = _usage_doc(windows)
                    await app.state.go_usage.poll()
            clock.t = T0
            seen.append(_describe(_series(await _scrape(app), "gateway_opencode_usage_poll_total")))
        finally:
            await client.aclose()
    expect({"series": " / ".join(seen)}, series=expected_series)
