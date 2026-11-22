"""GW-SESSIONS-CAPACITY — the ladder's capacity half as admission rows: the subscription's windows and
429 latch, the Go rail's latch, the Go window draw and the catalog (specs/endpoints/sessions.md
§Admission → GW-SESSIONS-CAPACITY). The clock starts at T0 = 1_800_000_000 = Fri 2027-01-15 08:00:00Z,
a Go PEAK hour (Mon–Fri 01–04 / 06–10 UTC). Every reading or usage reaches the gateway through the
data plane (a session + one /anthropic/v1/messages call the fake answers as the row says), never by
seeding. Header == argnames, description == id (tests/_rows.py)."""

from __future__ import annotations

import re

import pytest

from ._catalog_world import gw_client
from ._rows import DASH, POLICY, body_of, enter_world, expect, inputs
from .conftest import attach_json, bearer, given, open_session, quiet, rule, when

pytestmark = rule("GW-SESSIONS-CAPACITY")

H = 3600
TASK = "homelab-2650-r1"


def _rate(u5: float, u7: float, r5: float, r7: float) -> dict[str, str]:
    """The live `anthropic-ratelimit-unified-*` shape (conftest SUBSCRIPTION_HEADERS) with the row's values."""
    return {
        "anthropic-ratelimit-unified-status": "allowed",
        "anthropic-ratelimit-unified-5h-status": "allowed",
        "anthropic-ratelimit-unified-5h-utilization": f"{u5}",
        "anthropic-ratelimit-unified-5h-reset": f"{r5:.0f}",
        "anthropic-ratelimit-unified-7d-status": "allowed",
        "anthropic-ratelimit-unified-7d-utilization": f"{u7}",
        "anthropic-ratelimit-unified-7d-reset": f"{r7:.0f}",
    }


async def _ride(gw, upstreams, *, rail: str, role: str, behaviour: str = "upstream-ok", usage=None, rate=None, doc=None):
    """Arrange through the data plane: one ride on `rail` (the role's harness, from the picked cell)
    answered by the fake as stated — the request rides the anthropic dialect, which every rail here
    serves."""
    if doc is None:
        with quiet():
            doc = await open_session(gw, role=role, rail=rail, task=f"arrange-{rail}-{role}")
    up = upstreams[rail]
    up.behaviour, up.usage, up.rate_headers = behaviour, usage, rate
    with quiet():
        r = await gw.post("/anthropic/v1/messages", headers=bearer(doc),
                          json={"max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]})
    up.behaviour, up.usage, up.rate_headers = "upstream-ok", None, None
    attach_json(f"arranged ride: {role} on {rail} → {r.status_code}",
                {"session": doc["session"]["id"], "rail": rail, "model": doc["model"],
                 "upstream": {"behaviour": behaviour, "usage": usage, "ratelimit_headers": rate},
                 "gateway_status": r.status_code, "retry_after": r.headers.get("retry-after")})
    return doc


async def _fill(gw, rail: str, n: int) -> None:
    with quiet():
        for i in range(n):
            await open_session(gw, role="worker", task=f"fill-{rail}-{i}", rail=rail)
    attach_json(f"filled: {rail} × {n}", {"rail": rail, "active_sessions_opened": n})


async def _admit(gw, body: dict) -> dict:
    req = {"stack": "platform", "role": "worker", "task": TASK, **body}
    with when(f"POST /sessions {req}"):
        r = await gw.post("/sessions", json=req)
    assert r.status_code == 200, r.text
    return r.json()


def _seconds(then: str) -> int:
    """`then` cell → seconds: `—` = none pass, `+901 s` = 901."""
    return 0 if then == DASH else int(re.fullmatch(r"\+(\d+) s", then).group(1))


# -- the subscription's windows ---------------------------------------------------------------------
# thresholds (policy, ⚖ the old proxy): 5h 0.80, 7d 0.95; reading_stale_s 900. retry = reset − now.
READING = re.compile(r"^([\d.]+)( \(reset T0 − 1\))? / ([\d.]+)$")


async def _reading(gw, upstreams, clock, reading: str) -> None:
    """`reading` = the last anthropic answer's 5h / 7d utilization; resets at T0 + 3600 / T0 + 259200
    unless the cell says `(reset T0 − 1)`."""
    m = READING.match(reading)
    u5, u7 = float(m.group(1)), float(m.group(3))
    d5 = -1 if m.group(2) else H
    with given(f"reading = {reading}: one reviewer ride on anthropic answered with 5h {u5} (reset T0{d5:+d} s) / 7d {u7} (reset T0+259200 s)"):
        await _ride(gw, upstreams, rail="anthropic", role="reviewer", rate=_rate(u5, u7, clock.t + d5, clock.t + 3 * 86400))


WINDOW_ROWS = [
    pytest.param("policy-default · upstream-ok", "0.80 / 0.10", "defer", DASH, "rail-window", 3600,
                 id="the 5h window at its threshold defers the subscription until its reset"),
    pytest.param("policy-default · upstream-ok", "0.79 / 0.10", "dispatch", "anthropic", DASH, DASH,
                 id="the 5h window under its threshold admits"),
    pytest.param("policy-default · upstream-ok", "0.10 / 0.94", "dispatch", "anthropic", DASH, DASH,
                 id="the 7d window under its own threshold admits"),
    pytest.param("policy-default · upstream-ok", "0.10 / 0.95", "defer", DASH, "rail-window", 259200,
                 id="the 7d window at its threshold defers until the 7d reset"),
    pytest.param("policy-default · upstream-ok", "0.90 / 0.97", "defer", DASH, "rail-window", 259200,
                 id="both windows over: the later reset names the wait"),
]


@pytest.mark.parametrize(("world", "reading", "expected_decision", "expected_rail", "expected_reason", "expected_retry_after_s"), WINDOW_ROWS)
async def test_the_subscriptions_windows(gw, upstreams, clock, world, reading, expected_decision, expected_rail, expected_reason, expected_retry_after_s):
    enter_world(world)
    inputs(reading=reading)
    await _reading(gw, upstreams, clock, reading)
    doc = await _admit(gw, {"role": "reviewer", "rail": "anthropic"})
    expect(doc, decision=expected_decision, rail=expected_rail, reason=expected_reason, retry_after_s=expected_retry_after_s)


NO_READING_ROWS = [
    pytest.param("policy-default · upstream-ok", "0.90 (reset T0 − 1) / 0.10", DASH, "anthropic", "dispatch", "anthropic", DASH, DASH,
                 id="a window whose reset has passed is no reading"),
    pytest.param("policy-default · upstream-ok", "0.90 / 0.10", "+901 s", "anthropic", "dispatch", "anthropic", DASH, DASH,
                 id="a reading older than reading_stale_s is no reading ⚖"),
    pytest.param("policy-default · upstream-ok", "0.90 / 0.10", "+900 s", "anthropic", "defer", DASH, "rail-window", 2700,
                 id="a reading just inside reading_stale_s still defers"),
    pytest.param("policy-default · upstream-ok", "0.90 / 0.10", DASH, POLICY, "dispatch", "opencode", DASH, DASH,
                 id="the walk continues past a blocked subscription"),
]


@pytest.mark.parametrize(("world", "reading", "then", "rail", "expected_decision", "expected_rail", "expected_reason", "expected_retry_after_s"), NO_READING_ROWS)
async def test_a_reading_that_is_no_reading(gw, upstreams, clock, world, reading, then, rail,
                                            expected_decision, expected_rail, expected_reason, expected_retry_after_s):
    enter_world(world)
    inputs(reading=reading, then=then, rail=rail)
    await _reading(gw, upstreams, clock, reading)
    with given(f"then = {then}: {_seconds(then)} s pass with no further anthropic answer"):
        clock.advance(_seconds(then))
    doc = await _admit(gw, {"role": "reviewer", **body_of(rail=rail)})
    expect(doc, decision=expected_decision, rail=expected_rail, reason=expected_reason, retry_after_s=expected_retry_after_s)


# -- the 429 latch ----------------------------------------------------------------------------------
# latch_429_hold_s (policy, ⚖ the old proxy): anthropic 900 and opencode 900, both `latch_scope: account`;
# openrouter declares none. The fake's `upstream-429` sends retry-after: 30 (specs/worlds/), which beats the hold.
# `arrange` cell → the rides, in order: (rail, role, behaviour) — the same session answers again when the
# rail repeats; ("fill", rail, n) = the rail at its cap.
LATCH_ARRANGE = {
    "reviewer ride on anthropic → 429": [("anthropic", "reviewer", "upstream-429")],
    "reviewer ride on anthropic → 429, no retry-after": [("anthropic", "reviewer", "upstream-429-no-header")],
    "reviewer ride on anthropic → 429, the same session → 200": [("anthropic", "reviewer", "upstream-429"), ("anthropic", "reviewer", "upstream-ok")],
    "worker ride on opencode → 429": [("opencode", "worker", "upstream-429")],
    "worker ride on opencode → 429, no retry-after": [("opencode", "worker", "upstream-429-no-header")],
    "worker ride on openrouter → 429": [("openrouter", "worker", "upstream-429")],
    "worker ride on opencode → 429; openrouter at its 20": [("opencode", "worker", "upstream-429"), ("fill", "openrouter", 20)],
}


async def _latch_arrange(gw, upstreams, arrange: str) -> None:
    with given(f"arrange = {arrange}"):
        doc = None
        for step in LATCH_ARRANGE[arrange]:
            if step[0] == "fill":
                await _fill(gw, step[1], step[2])
                continue
            rail, role, behaviour = step
            doc = await _ride(gw, upstreams, rail=rail, role=role, behaviour=behaviour, doc=doc if doc and doc["rail"] == rail else None)


SUB_LATCH_ROWS = [
    pytest.param("policy-default · upstream-429", "reviewer ride on anthropic → 429", DASH, "defer", DASH, "rail-latched", 30,
                 id="an anthropic 429 latches the subscription for its retry-after"),
    pytest.param("policy-default · upstream-429-no-header", "reviewer ride on anthropic → 429, no retry-after", DASH, "defer", DASH, "rail-latched", 900,
                 id="a 429 without retry-after latches for the policy hold"),
    pytest.param("policy-default · upstream-429", "reviewer ride on anthropic → 429", "+30 s", "dispatch", "anthropic", DASH, DASH,
                 id="the latch lifts at its expiry"),
    pytest.param("policy-default · upstream-429", "reviewer ride on anthropic → 429, the same session → 200", DASH, "dispatch", "anthropic", DASH, DASH,
                 id="any 2xx on the rail clears the latch"),
]


@pytest.mark.parametrize(("world", "arrange", "then", "expected_decision", "expected_rail", "expected_reason", "expected_retry_after_s"), SUB_LATCH_ROWS)
async def test_the_subscriptions_429_latch(gw, upstreams, clock, world, arrange, then, expected_decision, expected_rail, expected_reason, expected_retry_after_s):
    enter_world(world)
    inputs(arrange=arrange, then=then)
    await _latch_arrange(gw, upstreams, arrange)
    with given(f"then = {then}: {_seconds(then)} s pass"):
        clock.advance(_seconds(then))
    doc = await _admit(gw, {"role": "reviewer", "rail": "anthropic"})
    expect(doc, decision=expected_decision, rail=expected_rail, reason=expected_reason, retry_after_s=expected_retry_after_s)


GO_LATCH_ROWS = [
    pytest.param("policy-default · upstream-429", "worker ride on opencode → 429", "opencode", POLICY, "defer", DASH, "rail-latched", 30,
                 id="a Go 429 latches the rail for its retry-after"),
    pytest.param("policy-default · upstream-429-no-header", "worker ride on opencode → 429, no retry-after", "opencode", POLICY, "defer", DASH, "rail-latched", 900,
                 id="a Go 429 without retry-after latches for the rail's hold"),
    pytest.param("policy-default · upstream-429", "worker ride on opencode → 429", "opencode", "heavy", "defer", DASH, "rail-latched", 30,
                 id="one Go model's 429 blocks every Go model: one shared allowance ⚖"),
    pytest.param("policy-default · upstream-429", "worker ride on opencode → 429", POLICY, POLICY, "dispatch", "openrouter", DASH, DASH,
                 id="a latched Go rail is skipped, the walk continues"),
    pytest.param("policy-default · upstream-429", "worker ride on openrouter → 429", "openrouter", "heavy", "dispatch", "openrouter", DASH, DASH,
                 id="a rail whose policy declares no latch is not latched: its other model admits ⚖"),
    pytest.param("policy-default · upstream-429", "worker ride on opencode → 429; openrouter at its 20", POLICY, POLICY, "defer", DASH, "rail-latched", 30,
                 id="every rail blocked: the rail that frees first names the defer ⚖"),
]


@pytest.mark.parametrize(("world", "arrange", "rail", "tier", "expected_decision", "expected_rail", "expected_reason", "expected_retry_after_s"), GO_LATCH_ROWS)
async def test_the_go_rails_429_latch(gw, upstreams, world, arrange, rail, tier, expected_decision, expected_rail, expected_reason, expected_retry_after_s):
    enter_world(world)
    inputs(arrange=arrange, rail=rail, tier=tier)
    await _latch_arrange(gw, upstreams, arrange)
    doc = await _admit(gw, body_of(rail=rail, tier=tier))
    expect(doc, decision=expected_decision, rail=expected_rail, reason=expected_reason, retry_after_s=expected_retry_after_s)


# -- the Go window draw -----------------------------------------------------------------------------
# Every price, peak row/hour, monthly limit and window share is the world's Go catalog snapshot
# (conftest.seed_go_catalog: catalog-ok + docs-ok, plan go — GW-CATALOG-GO), never the policy:
#   deepseek-v4.1-flash  base 0.15 / 0.60 / cache_read 0.003 / cache_write none; peak (Mon–Fri
#                        01–04 + 06–10 UTC) 0.30 / 1.20 / 0.006 / none; $80/month
#   claude-haiku-5-5     base 0.10 / 0.50 / 0.01 / 0.125; above 100000 prompt tokens 0.50 / 2.50 /
#                        0.05 / 0.625; no peak row; $15/month
# Shares 5h 0.2 · 7d 0.5 · 30d 1.0; policy threshold 0.80 each → v4.1-flash $12.80 / $32 / $64,
# haiku $2.40 / $6 / $12. Anchors (policy): 5h chain, 7d weekly Mon 00:00, 30d monthly 13th 11:30.
# Each row's draw is in the spec's legend; the arithmetic per row:
#   30M in + 3.2M out at peak = 9.00 + 3.84 = $12.84 ≥ 12.80; 3.1M out → $12.72 < 12.80; off-peak 4.50 + 1.92 = $6.42;
#   cache_read 1000M × 0.006 = $6.00 (× 0.30 would be $300); cache_write 1000M → $0 (no rate);
#   haiku 4M in + 0.2M out, prompt > 100000 → 2.00 + 0.50 = $2.50 ≥ 2.40 (base row $0.50); 90K in + 1M out → 0.009 + 0.50 = $0.509 < 2.40;
#   10M in + 1M out = 3.00 + 1.20 = $4.20 < 12.80 (haiku's 2.40 would block); 110M in = $33 ≥ 32 (7d); 220M in = $66 ≥ 64 (30d).
USAGE_KEYS = {"in": "input_tokens", "out": "output_tokens", "cache_read": "cache_read_input_tokens", "cache_write": "cache_creation_input_tokens"}
UNITS = {"M": 1_000_000, "K": 1_000}


def _parse_ride(ride: str) -> tuple[str, dict]:
    """`ride` = `<role> in 30M, out 3.2M` / `<role> cache_read 1000M` → (role, the answer's usage)."""
    role, rest = ride.split(" ", 1)
    usage = {"input_tokens": 0, "output_tokens": 0}
    for part in rest.split(", "):
        key, amount = part.split(" ")
        usage[USAGE_KEYS[key]] = int(round(float(amount[:-1]) * UNITS[amount[-1]]))
    return role, usage


def _at(at: str) -> int:
    """`at` = `T0` / `T0 + 2 h` → seconds after T0."""
    return 0 if at == "T0" else int(re.fullmatch(r"T0 \+ (\d+) h", at).group(1)) * H


DRAW_ROWS = [
    pytest.param("policy-default · upstream-ok", "worker in 30M, out 3.2M", "T0", DASH, "opencode", POLICY, "defer", DASH, "rail-window", 18000,
                 id="a 5h draw over threshold defers the Go model until its window resets"),
    pytest.param("policy-default · upstream-ok", "worker in 30M, out 3.1M", "T0", DASH, "opencode", POLICY, "dispatch", "opencode", DASH, DASH,
                 id="a 5h draw under threshold admits"),
    pytest.param("policy-default · upstream-ok", "worker in 30M, out 3.2M", "T0 + 2 h", DASH, "opencode", POLICY, "dispatch", "opencode", DASH, DASH,
                 id="an off-peak request draws at the base rate"),
    pytest.param("policy-default · upstream-ok", "worker cache_read 1000M", "T0", DASH, "opencode", POLICY, "dispatch", "opencode", DASH, DASH,
                 id="cache reads draw at their own rate, not the input rate"),
    pytest.param("policy-default · upstream-ok", "worker cache_write 1000M", "T0", DASH, "opencode", POLICY, "dispatch", "opencode", DASH, DASH,
                 id="a cache class with no rate draws nothing ⚖"),
    pytest.param("policy-default · upstream-ok", "reviewer in 4M, out 0.2M", "T0", DASH, "opencode", "heavy", "defer", DASH, "rail-window", 18000,
                 id="a prompt past the context tier draws at the tier's rate ⚖"),
    pytest.param("policy-default · upstream-ok", "reviewer in 90K, out 1M", "T0", DASH, "opencode", "heavy", "dispatch", "opencode", DASH, DASH,
                 id="a prompt within the context tier draws at the base row ⚖"),
]

WINDOWS_ROWS = [
    pytest.param("policy-default · upstream-ok", "worker in 10M, out 1M", "T0", DASH, "opencode", POLICY, "dispatch", "opencode", DASH, DASH,
                 id="each model's windows are its own monthly limit's shares"),
    pytest.param("policy-default · upstream-ok", "worker in 30M, out 3.2M", "T0", DASH, "opencode", "heavy", "dispatch", "opencode", DASH, DASH,
                 id="a full window on one Go model never blocks another"),
    pytest.param("policy-default · upstream-ok", "worker in 30M, out 3.2M", "T0", DASH, POLICY, POLICY, "dispatch", "openrouter", DASH, DASH,
                 id="the walk continues past a full Go window"),
    pytest.param("policy-default · upstream-ok", "worker in 30M, out 3.2M", "T0", "+18000 s", "opencode", POLICY, "dispatch", "opencode", DASH, DASH,
                 id="an expired 5h window draws nothing"),
    pytest.param("policy-default · upstream-ok", "worker in 110M", "T0", "+18000 s", "opencode", POLICY, "defer", DASH, "rail-window", 212400,
                 id="the 7d window binds once the 5h one has expired"),
    pytest.param("policy-default · upstream-ok", "worker in 220M", "T0", "+230401 s", "opencode", POLICY, "defer", DASH, "rail-window", 2287799,
                 id="the 30d window binds once the week has reset"),
]


async def _draw(gw, upstreams, clock, world, ride, at, then, rail, tier, expected):
    enter_world(world)
    inputs(ride=ride, at=at, then=then, rail=rail, tier=tier)
    role, usage = _parse_ride(ride)
    with given(f"ride = {ride} at {at}: the clock at T0 + {_at(at)} s, one {role} ride on opencode whose answer's usage is {usage}"):
        clock.advance(_at(at))
        await _ride(gw, upstreams, rail="opencode", role=role, usage=usage)
    with given(f"then = {then}: {_seconds(then)} s pass with no further Go request"):
        clock.advance(_seconds(then))
    doc = await _admit(gw, body_of(rail=rail, tier=tier))
    expect(doc, **expected)


@pytest.mark.parametrize(("world", "ride", "at", "then", "rail", "tier", "expected_decision", "expected_rail", "expected_reason", "expected_retry_after_s"), DRAW_ROWS)
async def test_the_go_window_draw(gw, upstreams, clock, world, ride, at, then, rail, tier, expected_decision, expected_rail, expected_reason, expected_retry_after_s):
    await _draw(gw, upstreams, clock, world, ride, at, then, rail, tier,
                {"decision": expected_decision, "rail": expected_rail, "reason": expected_reason, "retry_after_s": expected_retry_after_s})


@pytest.mark.parametrize(("world", "ride", "at", "then", "rail", "tier", "expected_decision", "expected_rail", "expected_reason", "expected_retry_after_s"), WINDOWS_ROWS)
async def test_the_go_windows(gw, upstreams, clock, world, ride, at, then, rail, tier, expected_decision, expected_rail, expected_reason, expected_retry_after_s):
    await _draw(gw, upstreams, clock, world, ride, at, then, rail, tier,
                {"decision": expected_decision, "rail": expected_rail, "reason": expected_reason, "retry_after_s": expected_retry_after_s})


# -- not in the catalog (GW-CATALOG-GO ruling 4) ----------------------------------------------------
# `refresh` = the world's catalog refreshed against the fake vendor (tests/_catalog_world.py) before the
# ask: `catalog-retired` = the catalog (models.dev) without deepseek-v4.1-flash; `docs-retired` = the Go
# page without claude-haiku-5-5's plan rows. retry = the next scheduled refresh (T0 +
# GATEWAY_GO_CATALOG_REFRESH_S, 21600 the default).
CATALOG_ROWS = [
    pytest.param("policy-default · catalog-retired", "catalog-retired", "opencode", POLICY, "defer", DASH, "not-in-catalog", 21600,
                 id="a Go model the catalog no longer lists defers not-in-catalog ⚖"),
    pytest.param("policy-default · catalog-retired", "catalog-retired", POLICY, POLICY, "dispatch", "openrouter", DASH, DASH,
                 id="a not-in-catalog model is skipped, the walk continues ⚖"),
    pytest.param("policy-default · docs-retired", "docs-retired", "opencode", "heavy", "defer", DASH, "not-in-catalog", 21600,
                 id="a listed model with no monthly limit under the plan defers not-in-catalog ⚖"),
    pytest.param("policy-default · catalog-retired", "catalog-retired", "opencode", "heavy", "dispatch", "opencode", DASH, DASH,
                 id="the other Go models still admit ⚖"),
]


@pytest.mark.parametrize(("world", "refresh", "rail", "tier", "expected_decision", "expected_rail", "expected_reason", "expected_retry_after_s"), CATALOG_ROWS)
async def test_not_in_the_catalog(gw, app, vendor, world, refresh, rail, tier, expected_decision, expected_rail, expected_reason, expected_retry_after_s):
    enter_world(world)
    inputs(refresh=refresh, rail=rail, tier=tier)
    source = "config" if refresh.startswith("catalog-") else "docs"
    with given(f"refresh = {refresh}: the {source} source refreshes against the fake vendor's {refresh}"):
        setattr(vendor, "catalog" if source == "config" else "docs", refresh)
        outcome = await app.state.catalog.refresh_source(source)
        attach_json("refresh outcome", {"source": source, "behaviour": refresh, "outcome": outcome})
        assert outcome == "ok", outcome
    doc = await _admit(gw, body_of(rail=rail, tier=tier))
    expect(doc, decision=expected_decision, rail=expected_rail, reason=expected_reason, retry_after_s=expected_retry_after_s)


NO_SNAPSHOT_ROWS = [
    pytest.param("policy-default", "none (a fresh store)", "opencode", POLICY, "defer", DASH, "not-in-catalog", 60,
                 id="no catalog snapshot at all: every Go model is not-in-catalog ⚖"),
]


@pytest.mark.parametrize(("world", "refresh", "rail", "tier", "expected_decision", "expected_rail", "expected_reason", "expected_retry_after_s"), NO_SNAPSHOT_ROWS)
async def test_no_catalog_snapshot(cworld, world, refresh, rail, tier, expected_decision, expected_rail, expected_reason, expected_retry_after_s):
    enter_world(world)
    inputs(refresh=refresh, rail=rail, tier=tier)
    with given(f"refresh = {refresh}: a gateway on a fresh store — no Go catalog snapshot, no refresh run (fails closed)"):
        app = cworld.build()
    async with gw_client(app) as gw:
        doc = await _admit(gw, body_of(rail=rail, tier=tier))
    expect(doc, decision=expected_decision, rail=expected_rail, reason=expected_reason, retry_after_s=expected_retry_after_s)
