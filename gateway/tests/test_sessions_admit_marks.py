"""GW-SESSIONS-ADMIT §Capacity §Kept across a restart — the capacity marks survive a pod roll
(specs/endpoints/sessions.md; operator ruling 2026-10-21).

World policy-default. T0 = 1_800_000_000 (the conftest Clock). The first gateway is the `gw` fixture on
its file-backed store (`settings.db_path`); every mark reaches it through the data plane (one ride the
fake answers as the row says). The roll: the first gateway's store closes, a SECOND gateway is built on
the same DB path at T0 + the row's offset, and the admission (or the re-probe pass, or the scrape) is
asked of that second gateway. `upstream-429-reset` sends OpenRouter's `x-ratelimit-reset` (epoch ms, no
`retry-after`); `upstream-429` sends `retry-after: 30`.

| description | arrange (the first gateway) | the roll | after the roll (the second gateway) | body || decision | rail | reason | retry_after_s |
|---|---|---|---|---||---|---|---|---|
| a cooled cell survives a restart | worker ride on openrouter → 429, reset T0 + 42 s | +10 s | — | worker, rail openrouter || defer | — | cell-cooled | 32 |
| a 429 latch on the subscription survives a restart | reviewer ride on anthropic → 429 (retry-after 30) | +10 s | — | reviewer, rail anthropic || defer | — | rail-latched | 20 |
| a rejected credential's mark survives with its backoff | worker ride on opencode → upstream-401-key-expired | +10 s | — | worker, rail opencode || defer | — | credential-rejected | 50 |
| a mark cleared by a 2xx before the roll is gone after it | worker ride on openrouter → 429, reset T0 + 42 s, the same session → 200 | +10 s | — | worker, rail openrouter || dispatch | openrouter | — | — |
| a half-open hold survives: a repeat rejection after the roll doubles the hold | prober ride on anthropic → upstream-401 | +900 s | a prober ride on anthropic → upstream-401 | prober || defer | — | credential-rejected | 1800 |

The re-probe schedule (opencode's `credential_probe`, backoff [60, 3600]) continues on the second
gateway, which calls `proxy.reprobe()` once on the test clock:

| description | arrange (the first gateway) | the roll | the probe answers || probes sent | decision | reason | retry_after_s |
|---|---|---|---||---|---|---|---|
| the re-probe schedule continues after the roll: a probe rejected again doubles | worker ride on opencode → upstream-401-key-expired | +60 s | upstream-401-key-expired || 1 | defer | credential-rejected | 120 |
| a probe due while the gateway was down is sent on the first pass after the roll | the same | +90 s | upstream-ok || 1 | dispatch (opencode) | — | — |
| a probe is not sent before it is due, across the roll | the same | +30 s | upstream-ok || 0 | defer | credential-rejected | 30 |

What the second gateway shows first — the gauges on its first scrape, the reload line, and the
fail-open store (a gateway on `:memory:` and a second one on a new `:memory:` store):

| description | arrange (the first gateway) | the roll || observed on the second gateway |
|---|---|---||---|
| an expired mark is not reloaded | worker ride on openrouter → 429, reset T0 + 42 s | +42 s || capacity_marks holds no row after the load (the expired one deleted); worker, rail openrouter → dispatch openrouter |
| the gauges show the reloaded counts on the first scrape | worker ride on openrouter → 429 (reset T0 + 42 s); worker ride on opencode → upstream-401-key-expired | +10 s || gateway_cells_cooled{rail="openrouter"} 1; gateway_credentials_rejected{rail="opencode"} 1 |
| the reload is logged | the same | +10 s || capacity: reloaded 3 marks from the store (1 cooled, 0 latched, 1 rejected, 1 holds; 0 dropped as expired) |
| the memory store keeps no mark | worker ride on openrouter → 429 (reset T0 + 42 s) on a `:memory:` gateway | +10 s, a new `:memory:` store || dispatch openrouter |
"""

from __future__ import annotations

import contextlib
import logging
import re

import httpx
import pytest

from agent_gateway.app import create_app
from agent_gateway.store import Store

from .conftest import ObservedAsyncClient, attach_json, given, quiet, rule, then, then_eq, when, world
from .test_sessions_admit_cells import _admit, _arrange, _ride, _verdict

pytestmark = rule("GW-SESSIONS-ADMIT")


@contextlib.asynccontextmanager
async def _rolled(app, transport, clock, advance: int, db: str | None = None):
    """The roll: the first gateway's store closes (the pod is gone), `advance` s pass, and a second
    gateway starts on the same DB path (or on `db`), sharing the fakes, the policy and the clock."""
    st = app.state
    with given(f"the roll = +{advance} s: the first gateway's store closes; {advance} s pass; a second gateway starts on {db or 'the same DB'}"):
        st.store.close()
        clock.advance(advance)
        client = httpx.AsyncClient(transport=transport)  # the rails' fakes + the fake vendor + the fake MCP
        second = create_app(st.settings, policy=st.policy, source=st.resolver.source, store=Store(db or st.settings.db_path),
                            client=client, clock=clock, reviewer=st.sessions.reviewer, pods=st.sessions.pods)
        attach_json(f"the second gateway: db {second.state.store.mode}", {"db": second.state.store.mode, "clock": clock.t})
    try:
        async with ObservedAsyncClient(transport=httpx.ASGITransport(app=second), base_url="http://gw2") as c:
            yield second, c
    finally:
        await client.aclose()


# arrange / after step = (rail, role, behaviour, extra) — the cells module's `_arrange`; "same" = the same session
MARK_ROWS = [
    # the cell cooled until T0 + 42; asked at T0 + 10 → retry 32
    ("a cooled cell survives a restart", [("openrouter", "worker", "upstream-429-reset", {"reset_in": 42})], 10, [],
     {"rail": "openrouter"}, {"decision": "defer", "reason": "cell-cooled", "retry_after_s": 32}),
    # latched until T0 + 30 (retry-after); asked at T0 + 10 → 20
    ("a 429 latch on the subscription survives a restart", [("anthropic", "reviewer", "upstream-429", {})], 10, [],
     {"role": "reviewer", "rail": "anthropic"}, {"decision": "defer", "reason": "rail-latched", "retry_after_s": 20}),
    # opencode's first backoff 60 → the probe is due at T0 + 60; asked at T0 + 10 → 50
    ("a rejected credential's mark survives with its backoff", [("opencode", "worker", "upstream-401-key-expired", {})], 10, [],
     {"rail": "opencode"}, {"decision": "defer", "reason": "credential-rejected", "retry_after_s": 50}),
    ("a mark cleared by a 2xx before the roll is gone after it",
     [("openrouter", "worker", "upstream-429-reset", {"reset_in": 42}), ("same", "worker", "upstream-ok", {})], 10, [],
     {"rail": "openrouter"}, {"decision": "dispatch", "rail": "openrouter"}),
    # anthropic (no probe): hold 900 → the mark lifts half-open at T0 + 900, the hold row keeps 900; the
    # second gateway admits the prober's ride (half-open), its 401 doubles to 1800. The after-ride is another
    # task: the first ride's own auth-storm strike excludes its cell for ITS task (§The retry contract)
    ("a half-open hold survives: a repeat rejection after the roll doubles the hold", [("anthropic", "prober", "upstream-401", {})], 900,
     [("anthropic", "prober", "upstream-401", {"task": "arrange-second-ride"})],
     {"role": "prober"}, {"decision": "defer", "reason": "credential-rejected", "retry_after_s": 1800}),
]


@pytest.mark.parametrize(("arrange", "roll", "after", "body", "expected"), [r[1:] for r in MARK_ROWS], ids=[r[0] for r in MARK_ROWS])
async def test_mark_survives(gw, app, upstreams, mcp_transport, clock, arrange, roll, after, body, expected):
    world(upstream=arrange[0][2], note="the arranged ride's answer on the first gateway; every other answer is upstream-ok")
    await _arrange(gw, upstreams, clock, arrange)
    async with _rolled(app, mcp_transport, clock, roll) as (_second, gw2):
        if after:
            await _arrange(gw2, upstreams, clock, after)
        _verdict(await _admit(gw2, body), expected)


PROBE_ROWS = [
    # (roll offset, the probe's answer, probes expected, body, expected)
    ("the re-probe schedule continues after the roll: a probe rejected again doubles", 60, "upstream-401-key-expired", 1,
     {"rail": "opencode"}, {"decision": "defer", "reason": "credential-rejected", "retry_after_s": 120}),
    # due at T0 + 60, the roll at T0 + 90: the mark reloads as due (a probe rail), the first pass sends it
    ("a probe due while the gateway was down is sent on the first pass after the roll", 90, "upstream-ok", 1,
     {"rail": "opencode"}, {"decision": "dispatch", "rail": "opencode"}),
    ("a probe is not sent before it is due, across the roll", 30, "upstream-ok", 0,
     {"rail": "opencode"}, {"decision": "defer", "reason": "credential-rejected", "retry_after_s": 30}),
]


@pytest.mark.parametrize(("roll", "probe", "probes", "body", "expected"), [r[1:] for r in PROBE_ROWS], ids=[r[0] for r in PROBE_ROWS])
async def test_reprobe_continues(gw, app, upstreams, mcp_transport, clock, roll, probe, probes, body, expected):
    world(upstream="upstream-401-key-expired", note=f"the arranged ride's answer on the first gateway; the probe answers {probe}")
    with given("arrange: a worker ride on opencode is answered upstream-401-key-expired"):
        await _ride(gw, upstreams, clock, rail="opencode", role="worker", behaviour="upstream-401-key-expired")
    async with _rolled(app, mcp_transport, clock, roll) as (second, gw2):
        with given(f"probe = {probe!r}: the second gateway's re-probe pass, the upstream answering {probe}"):
            upstreams["opencode"].behaviour = probe
            with quiet():
                sent = await second.state.proxy.reprobe()
            upstreams["opencode"].behaviour = "upstream-ok"
            attach_json("the re-probe pass", {"probes sent": sent})
        then_eq("probes", sent, probes, claim=f"probes = {probes!r} sent by the second gateway's re-probe pass")
        _verdict(await _admit(gw2, body), expected)


async def test_expired_not_reloaded(gw, app, upstreams, mcp_transport, clock):
    """row: an expired mark is not reloaded"""
    world(upstream="upstream-429-reset", note="the arranged ride's answer on the first gateway; every other answer is upstream-ok")
    with given("arrange: a worker ride on openrouter answered 429 (reset T0 + 42 s): the cell is cooled until T0 + 42"):
        await _ride(gw, upstreams, clock, rail="openrouter", role="worker", behaviour="upstream-429-reset", reset_in=42)
    async with _rolled(app, mcp_transport, clock, 42) as (second, gw2):
        rows = second.state.store.marks_load()
        with then("capacity_marks holds no row after the load: the expired cooldown was dropped and deleted",
                  marks={"statement": "SELECT kind, key, until, stack, at, backoff FROM capacity_marks", "expected": [], "actual": rows}):
            assert rows == [], rows
        _verdict(await _admit(gw2, {"rail": "openrouter"}), {"decision": "dispatch", "rail": "openrouter"})


async def _two_marks(gw, upstreams, clock) -> None:
    with given("arrange: a worker ride on openrouter answered 429 (reset T0 + 42 s); a worker ride on opencode answered upstream-401-key-expired"):
        await _ride(gw, upstreams, clock, rail="openrouter", role="worker", behaviour="upstream-429-reset", reset_in=42)
        await _ride(gw, upstreams, clock, rail="opencode", role="worker", behaviour="upstream-401-key-expired")


async def test_gauges_reloaded(gw, app, upstreams, mcp_transport, clock):
    """row: the gauges show the reloaded counts on the first scrape"""
    world(upstream="upstream-429-reset", note="one 429 on openrouter, one 401 on opencode, both on the first gateway")
    await _two_marks(gw, upstreams, clock)
    async with _rolled(app, mcp_transport, clock, 10) as (_second, gw2):
        with when("GET /metrics on the second gateway, before any admission"):
            text = (await gw2.get("/metrics")).text
    got = {s: _value(text, s) for s in ('gateway_cells_cooled{rail="openrouter"}', 'gateway_credentials_rejected{rail="opencode"}')}
    with then("gateway_cells_cooled{rail=openrouter} = 1 and gateway_credentials_rejected{rail=opencode} = 1 on the first scrape",
              gauges={"expected": {k: 1.0 for k in got}, "actual": got}):
        assert got == {k: 1.0 for k in got}, got


async def test_reload_logged(gw, app, upstreams, mcp_transport, clock, caplog):
    """row: the reload is logged"""
    world(upstream="upstream-429-reset", note="one 429 on openrouter, one 401 on opencode, both on the first gateway")
    caplog.set_level(logging.INFO, logger="gateway.capacity")
    await _two_marks(gw, upstreams, clock)
    caplog.clear()
    async with _rolled(app, mcp_transport, clock, 10) as (_second, _gw2):
        pass
    lines = [rec.getMessage() for rec in caplog.records if rec.getMessage().startswith("capacity: reloaded")]
    with then("the second gateway logs capacity: reloaded 3 marks (1 cooled, 0 latched, 1 rejected, 1 holds; 0 dropped)", log={"actual": lines}):
        assert lines == ["capacity: reloaded 3 marks from the store (1 cooled, 0 latched, 1 rejected, 1 holds; 0 dropped as expired)"], lines


async def test_memory_store_keeps_nothing(settings, policy, secrets, mcp_transport, clock, reviews, pods, upstreams):
    """row: the memory store keeps no mark"""
    world(upstream="upstream-429-reset", note="the first gateway fails open to :memory:; the second starts on a new :memory: store")
    with given("a gateway on a :memory: store; a worker ride on openrouter answered 429 (reset T0 + 42 s)"):
        client = httpx.AsyncClient(transport=mcp_transport)
        first = create_app(settings, policy=policy, source=secrets, store=Store(":memory:"), client=client, clock=clock, reviewer=reviews, pods=pods)
        async with ObservedAsyncClient(transport=httpx.ASGITransport(app=first), base_url="http://gw") as gw:
            await _ride(gw, upstreams, clock, rail="openrouter", role="worker", behaviour="upstream-429-reset", reset_in=42)
    try:
        async with _rolled(first, mcp_transport, clock, 10, db=":memory:") as (_second, gw2):
            _verdict(await _admit(gw2, {"rail": "openrouter"}), {"decision": "dispatch", "rail": "openrouter"})
    finally:
        await client.aclose()


def _value(text: str, series: str) -> float | None:
    m = re.search(r"^" + re.escape(series) + r" (\S+)$", text, re.M)
    return float(m.group(1)) if m else None
