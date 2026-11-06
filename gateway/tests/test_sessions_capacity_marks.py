"""GW-SESSIONS-CAPACITY §Kept across a restart — the capacity marks survive a pod roll
(specs/endpoints/sessions.md; operator ruling 2026-10-21). T0 = 1_800_000_000 (the conftest Clock).
The first gateway is the `gw` fixture on its file-backed store (`settings.db_path`); every mark
reaches it through the data plane (one ride the fake answers as the row says). The roll: the first
gateway's store closes, a SECOND gateway is built on the same DB path at T0 + the row's offset, and
the admission (or the re-probe pass, or the scrape) is asked of that second gateway.
`upstream-429-reset` sends OpenRouter's `x-ratelimit-reset` (epoch ms, no `retry-after`);
`upstream-429` sends `retry-after: 30`. Header == argnames, description == id (tests/_rows.py)."""

from __future__ import annotations

import contextlib
import logging
import re

import httpx
import pytest

from agent_gateway.app import create_app
from agent_gateway.store import Store

from ._rows import DASH, POLICY, body_of, enter_world, expect, inputs
from .conftest import ObservedAsyncClient, attach_json, given, quiet, rule, when
from .test_sessions_capacity_cells import _admit, _arrange, _ride

pytestmark = rule("GW-SESSIONS-CAPACITY")


def _roll_seconds(roll: str) -> int:
    """`roll` = `+10 s` (the gap between the first gateway's close and the second's start)."""
    return int(re.fullmatch(r"\+(\d+) s.*", roll).group(1))


@contextlib.asynccontextmanager
async def _rolled(app, transport, clock, roll: str, db: str | None = None):
    """The roll: the first gateway's store closes (the pod is gone), the roll's seconds pass, and a
    second gateway starts on the same DB path (or on `db`), sharing the fakes, the policy and the clock."""
    st = app.state
    with when(f"roll = {roll}: the first gateway's store closes; {_roll_seconds(roll)} s pass; a second gateway starts on {db or 'the same DB'}"):
        st.store.close()
        clock.advance(_roll_seconds(roll))
        client = httpx.AsyncClient(transport=transport)  # the rails' fakes + the fake vendor + the fake MCP
        second = create_app(st.settings, policy=st.policy, source=st.resolver.source, store=Store(db or st.settings.db_path),
                            client=client, clock=clock, reviewer=st.sessions.reviewer, pods=st.sessions.pods)
        attach_json(f"the second gateway: db {second.state.store.mode}", {"db": second.state.store.mode, "clock": clock.t})
    try:
        async with ObservedAsyncClient(transport=httpx.ASGITransport(app=second), base_url="http://gw2") as c:
            yield second, c
    finally:
        await client.aclose()


# -- the marks survive ------------------------------------------------------------------------------
MARK_ROWS = [
    # the cell cooled until T0 + 42; asked at T0 + 10 → retry 32
    pytest.param("policy-default · upstream-429-reset", "worker ride on openrouter → 429, reset T0 + 42 s", "+10 s", DASH, "worker", "openrouter",
                 "defer", DASH, "cell-cooled", 32, id="a cooled cell survives a restart"),
    # latched until T0 + 30 (retry-after); asked at T0 + 10 → 20
    pytest.param("policy-default · upstream-429", "reviewer ride on anthropic → 429 (retry-after: 30)", "+10 s", DASH, "reviewer", "anthropic",
                 "defer", DASH, "rail-latched", 20, id="a 429 latch on the subscription survives a restart"),
    # opencode's first backoff 60 → the probe is due at T0 + 60; asked at T0 + 10 → 50
    pytest.param("policy-default · upstream-401-key-expired", "worker ride on opencode → upstream-401-key-expired", "+10 s", DASH, "worker", "opencode",
                 "defer", DASH, "credential-rejected", 50, id="a rejected credential's mark survives with its backoff"),
    pytest.param("policy-default · upstream-429-reset", "worker ride on openrouter → 429, reset T0 + 42 s, the same session → 200", "+10 s", DASH, "worker", "openrouter",
                 "dispatch", "openrouter", DASH, DASH, id="a mark cleared by a 2xx before the roll is gone after it"),
    # anthropic (no probe): hold 900 → the mark lifts half-open at T0 + 900, the hold row keeps 900; the
    # second gateway admits the prober's ride (half-open), its 401 doubles to 1800
    pytest.param("policy-default · upstream-401", "prober ride on anthropic → upstream-401", "+900 s", "prober ride on anthropic → upstream-401", "prober", POLICY,
                 "defer", DASH, "credential-rejected", 1800, id="a half-open hold survives: a repeat rejection after the roll doubles the hold ⚖"),
]


@pytest.mark.parametrize(("world", "arrange", "roll", "after", "role", "rail", "expected_decision", "expected_rail", "expected_reason", "expected_retry_after_s"), MARK_ROWS)
async def test_kept_across_a_restart(gw, app, upstreams, mcp_transport, clock, secrets, world, arrange, roll, after, role, rail,
                                     expected_decision, expected_rail, expected_reason, expected_retry_after_s):
    enter_world(world)
    inputs(arrange=arrange, roll=roll, after=after, role=role, rail=rail)
    await _arrange(gw, upstreams, clock, secrets, arrange)
    async with _rolled(app, mcp_transport, clock, roll) as (_second, gw2):
        if after != DASH:
            with given(f"after = {after}: on the second gateway (another task — the first ride's own auth-storm strike excludes its cell for ITS task)"):
                await _ride(gw2, upstreams, clock, rail="anthropic", role="prober", behaviour="upstream-401", task="arrange-second-ride")
        doc = await _admit(gw2, body_of(role=role, rail=rail))
    expect(doc, decision=expected_decision, rail=expected_rail, reason=expected_reason, retry_after_s=expected_retry_after_s)


# -- the re-probe schedule continues on the second gateway --------------------------------------------
PROBE_ROWS = [
    pytest.param("policy-default · upstream-401-key-expired", "worker ride on opencode → upstream-401-key-expired", "+60 s", "upstream-401-key-expired",
                 1, "defer", DASH, "credential-rejected", 120, id="the re-probe schedule continues after the roll: a probe rejected again doubles"),
    # due at T0 + 60, the roll at T0 + 90: the mark reloads as due (a probe rail), the first pass sends it
    pytest.param("policy-default · upstream-401-key-expired", "worker ride on opencode → upstream-401-key-expired", "+90 s", "upstream-ok",
                 1, "dispatch", "opencode", DASH, DASH, id="a probe due while the gateway was down is sent on the first pass after the roll ⚖"),
    pytest.param("policy-default · upstream-401-key-expired", "worker ride on opencode → upstream-401-key-expired", "+30 s", "upstream-ok",
                 0, "defer", DASH, "credential-rejected", 30, id="a probe is not sent before it is due, across the roll"),
]


@pytest.mark.parametrize(("world", "arrange", "roll", "probe_answers", "expected_probes_sent", "expected_decision", "expected_rail", "expected_reason", "expected_retry_after_s"), PROBE_ROWS)
async def test_the_reprobe_schedule_across_a_restart(gw, app, upstreams, mcp_transport, clock, secrets, world, arrange, roll, probe_answers,
                                                     expected_probes_sent, expected_decision, expected_rail, expected_reason, expected_retry_after_s):
    enter_world(world)
    inputs(arrange=arrange, roll=roll, probe_answers=probe_answers)
    await _arrange(gw, upstreams, clock, secrets, arrange)
    async with _rolled(app, mcp_transport, clock, roll) as (second, gw2):
        with given(f"probe_answers = {probe_answers}: the second gateway's re-probe pass, the upstream answering {probe_answers}"):
            upstreams["opencode"].behaviour = probe_answers
            with quiet():
                sent = await second.state.proxy.reprobe()
            upstreams["opencode"].behaviour = "upstream-ok"
            attach_json("the re-probe pass", {"probes sent": sent})
        doc = await _admit(gw2, {"rail": "opencode"})
    expect({**doc, "probes_sent": sent}, probes_sent=expected_probes_sent, decision=expected_decision, rail=expected_rail,
           reason=expected_reason, retry_after_s=expected_retry_after_s)


# -- what the second gateway shows first --------------------------------------------------------------
TWO_MARKS = "worker ride on openrouter → 429, reset T0 + 42 s; worker ride on opencode → upstream-401-key-expired"
MEMORY = "worker ride on openrouter → 429, reset T0 + 42 s, on a :memory: gateway"
GAUGES = 'gateway_cells_cooled{rail="openrouter"} 1 · gateway_credentials_rejected{rail="opencode"} 1'
RELOAD_LINE = "capacity: reloaded 3 marks from the store (1 cooled, 0 latched, 1 rejected, 1 holds; 0 dropped as expired)"

SHOWS_ROWS = [
    pytest.param("policy-default · upstream-429-reset", "worker ride on openrouter → 429, reset T0 + 42 s", "+42 s",
                 "capacity_marks holds no row; worker, rail openrouter → dispatch openrouter", id="an expired mark is not reloaded"),
    pytest.param("policy-default · upstream-429-reset", TWO_MARKS, "+10 s", GAUGES, id="the gauges show the reloaded counts on the first scrape ⚖"),
    pytest.param("policy-default · upstream-429-reset", TWO_MARKS, "+10 s", RELOAD_LINE, id="the reload is logged"),
    pytest.param("policy-default · upstream-429-reset", MEMORY, "+10 s, a new :memory: store", "dispatch openrouter", id="the memory store keeps no mark ⚖"),
]


def _value(text: str, series: str) -> float | None:
    m = re.search(r"^" + re.escape(series) + r" (\S+)$", text, re.M)
    return float(m.group(1)) if m else None


async def _two_marks(gw, upstreams, clock) -> None:
    with given(f"arrange = {TWO_MARKS}"):
        await _ride(gw, upstreams, clock, rail="openrouter", role="worker", behaviour="upstream-429-reset", reset_in=42)
        await _ride(gw, upstreams, clock, rail="opencode", role="worker", behaviour="upstream-401-key-expired")


@pytest.mark.parametrize(("world", "arrange", "roll", "expected_observed"), SHOWS_ROWS)
async def test_what_the_second_gateway_shows_first(gw, app, upstreams, mcp_transport, clock, secrets, settings, policy, reviews, pods, caplog,
                                                   world, arrange, roll, expected_observed):
    enter_world(world)
    inputs(arrange=arrange, roll=roll)
    caplog.set_level(logging.INFO, logger="gateway.capacity")
    if arrange == TWO_MARKS:
        await _two_marks(gw, upstreams, clock)
        caplog.clear()
        async with _rolled(app, mcp_transport, clock, roll) as (_second, gw2):
            if expected_observed == GAUGES:
                with quiet():
                    text = (await gw2.get("/metrics")).text
                got = {s: _value(text, s) for s in ('gateway_cells_cooled{rail="openrouter"}', 'gateway_credentials_rejected{rail="opencode"}')}
                observed = " · ".join(f"{s} {v:g}" for s, v in got.items())
            else:
                lines = [rec.getMessage() for rec in caplog.records if rec.getMessage().startswith("capacity: reloaded")]
                observed = lines[0] if len(lines) == 1 else f"{len(lines)} reload lines: {lines}"
    elif arrange == MEMORY:
        with given(f"arrange = {arrange}: the first gateway fails open to :memory:"):
            client = httpx.AsyncClient(transport=mcp_transport)
            first = create_app(settings, policy=policy, source=secrets, store=Store(":memory:"), client=client, clock=clock, reviewer=reviews, pods=pods)
            async with ObservedAsyncClient(transport=httpx.ASGITransport(app=first), base_url="http://gw") as gw1:
                await _ride(gw1, upstreams, clock, rail="openrouter", role="worker", behaviour="upstream-429-reset", reset_in=42)
        try:
            async with _rolled(first, mcp_transport, clock, roll, db=":memory:") as (_second, gw2):
                doc = await _admit(gw2, {"rail": "openrouter"})
                observed = f"{doc['decision']} {doc.get('rail') or doc.get('reason')}"
        finally:
            await client.aclose()
    else:
        await _arrange(gw, upstreams, clock, secrets, arrange)
        async with _rolled(app, mcp_transport, clock, roll) as (second, gw2):
            rows = second.state.store.marks_load()
            attach_json("SELECT kind, key, until, stack, at, backoff FROM capacity_marks — after the load", rows)
            doc = await _admit(gw2, {"rail": "openrouter"})
            observed = (("capacity_marks holds no row" if rows == [] else f"capacity_marks holds {len(rows)} rows")
                        + f"; worker, rail openrouter → {doc['decision']} {doc.get('rail') or doc.get('reason')}")
    expect({"observed": observed}, observed=expected_observed)
