"""GW-SESSIONS-ADMIT §Capacity — the ladder's capacity half as admission rows (specs/endpoints/sessions.md).

World policy-default (the `admission` blocks of rails.anthropic / rails.opencode; values ⚖-cited
there). The clock starts at T0 = 1_800_000_000 = Fri 2027-01-15 08:00:00Z — a Go PEAK hour
(Mon–Fri 01–04 / 06–10 UTC). Every arranged reading or usage reaches the gateway through the data
plane (a session + one /anthropic/v1/messages call against the fake upstream), never by seeding.

Subscription window utilization (reviewer; arrange = one anthropic ride whose answer carries the
`anthropic-ratelimit-unified-*` set below, resets at T0 + 3600 (5h) / T0 + 259200 (7d) unless stated):

| description | reading (5h / 7d) | then | body || decision | rail | reason | retry_after_s |
|---|---|---|---||---|---|---|---|
| the 5h window at its threshold defers the subscription until its reset | 0.80 / 0.10 | — | rail anthropic || defer | — | rail-window | 3600 |
| the 5h window under its threshold admits | 0.79 / 0.10 | — | rail anthropic || dispatch | anthropic | — | — |
| the 7d window under its own threshold admits | 0.10 / 0.94 | — | rail anthropic || dispatch | anthropic | — | — |
| the 7d window at its threshold defers until the 7d reset | 0.10 / 0.95 | — | rail anthropic || defer | — | rail-window | 259200 |
| both windows over: the later reset names the wait | 0.90 / 0.97 | — | rail anthropic || defer | — | rail-window | 259200 |
| a window whose reset has passed is no reading | 0.90 (reset T0 − 1) / 0.10 | — | rail anthropic || dispatch | anthropic | — | — |
| a reading older than reading_stale_s is no reading | 0.90 / 0.10 | +901 s | rail anthropic || dispatch | anthropic | — | — |
| a reading just inside reading_stale_s still defers | 0.90 / 0.10 | +900 s | rail anthropic || defer | — | rail-window | 2700 |
| the walk continues past a blocked subscription | 0.90 / 0.10 | — | (policy walk) || dispatch | opencode | — | — |

429 latch per rail (arrange = one ride answered `upstream-429` (`retry-after: 30`) unless stated):

| description | arrange | then | body || decision | rail | reason | retry_after_s |
|---|---|---|---||---|---|---|---|
| an anthropic 429 latches the subscription for its retry-after | reviewer ride on anthropic → 429 | — | reviewer, rail anthropic || defer | — | rail-latched | 30 |
| a 429 without retry-after latches for the policy hold | reviewer ride on anthropic → 429, no retry-after | — | reviewer, rail anthropic || defer | — | rail-latched | 900 |
| the latch lifts at its expiry | reviewer ride on anthropic → 429 | +30 s | reviewer, rail anthropic || dispatch | anthropic | — | — |
| any 2xx on the rail clears the latch | reviewer ride on anthropic → 429, then the same session → 200 | — | reviewer, rail anthropic || dispatch | anthropic | — | — |
| a Go 429 latches the Go rail | worker ride on opencode → 429 | — | worker, rail opencode || defer | — | rail-latched | 30 |
| a latched rail is skipped, the walk continues | worker ride on opencode → 429 | — | worker (policy walk) || dispatch | openrouter | — | — |
| a rail whose policy declares no latch does not latch | worker ride on openrouter → 429 | — | worker, rail openrouter || dispatch | openrouter | — | — |
| every rail blocked: the rail that frees first names the defer | worker ride on opencode → 429; openrouter at its 20 | — | worker (policy walk) || defer | — | rail-latched | 30 |

Go window draw (worker ride on opencode = opencode-go/deepseek-v4-flash; reviewer = the unpriced
opencode-go/claude-sonnet-4-6; the ride's usage below; 5h window = $12 × 0.80 = $9.60):

| description | ride usage (at) | then | body || decision | rail | reason | retry_after_s |
|---|---|---|---||---|---|---|---|
| a 5h draw over threshold defers the Go rail until the window resets | worker in 20M, out 3.2M (T0, peak) | — | worker, rail opencode || defer | — | rail-window | 18000 |
| a 5h draw under threshold admits | worker in 20M, out 2.8M (T0, peak) | — | worker, rail opencode || dispatch | opencode | — | — |
| an off-peak request draws at the base rate | worker in 20M, out 3.2M (T0 + 2 h, off-peak) | — | worker, rail opencode || dispatch | opencode | — | — |
| cache reads draw at their own rate, not the input rate | worker cache_read 1000M (T0, peak) | — | worker, rail opencode || dispatch | opencode | — | — |
| a cache class with no rate draws nothing | worker cache_write 1000M (T0, peak) | — | worker, rail opencode || dispatch | opencode | — | — |
| an unpriced model draws at the fallback row | reviewer in 1M, out 0.1M (T0) | — | worker, rail opencode || defer | — | rail-window | 18000 |
| the walk continues past a full Go window | worker in 20M, out 3.2M (T0, peak) | — | worker (policy walk) || dispatch | openrouter | — | — |
| an expired 5h window draws nothing | worker in 20M, out 3.2M (T0, peak) | +18000 s | worker, rail opencode || dispatch | opencode | — | — |
| the 7d window binds once the 5h one has expired | worker in 90M (T0, peak) | +18000 s | worker, rail opencode || defer | — | rail-window | 212400 |
| the 30d window binds once the week has reset | worker in 170M (T0, peak) | +230401 s | worker, rail opencode || defer | — | rail-window | 2287799 |
"""

from __future__ import annotations

import pytest

from .conftest import attach_json, bearer, given, open_session, quiet, rule, then, then_eq, when, world

pytestmark = rule("GW-SESSIONS-ADMIT")

H = 3600
T0 = 1_800_000_000  # conftest Clock's start: Fri 2027-01-15 08:00:00Z


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
    """Arrange through the data plane: one claude-harness ride on `rail` answered by the fake as stated."""
    if doc is None:
        with quiet():
            doc = await open_session(gw, role=role, rail=rail, harness="claude", task=f"arrange-{rail}-{role}")
    up = upstreams[rail]
    up.behaviour, up.usage, up.rate_headers = behaviour, usage, rate
    with quiet():  # one folded attachment per arranged ride instead of the gateway + fake exchange pair
        r = await gw.post("/anthropic/v1/messages", headers=bearer(doc),
                          json={"max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]})
    up.behaviour, up.usage, up.rate_headers = "upstream-ok", None, None
    call = up.calls[-1] if up.calls else {}
    attach_json(f"arranged ride: {role} on {rail} → {r.status_code}",
                {"session": doc["session"]["id"], "rail": rail, "model": doc["model"],
                 "upstream": {"behaviour": behaviour, "path": call.get("path"), "usage": usage, "ratelimit_headers": rate},
                 "gateway_status": r.status_code, "retry_after": r.headers.get("retry-after")})
    return doc


async def _fill(gw, rail: str, n: int):
    with quiet():
        for i in range(n):
            await open_session(gw, role="worker", task=f"fill-{rail}-{i}", rail=rail)
    attach_json(f"filled: {rail} × {n}", {"rail": rail, "active_sessions_opened": n})


async def _admit(gw, body: dict) -> dict:
    req = {"stack": "platform", "role": "worker", "task": "homelab-2650-r1", **body}
    with when(f"POST /sessions body {body}"):
        r = await gw.post("/sessions", json=req)
    then_eq("status", r.status_code, 200)
    return r.json()


def _verdict(doc: dict, expected: dict) -> None:
    claim = "expected " + ", ".join(f"{k} = {v}" for k, v in expected.items())
    with then(claim, **{k: {"expected": v, "actual": doc.get(k)} for k, v in expected.items()}):  # one verdict attachment
        assert {k: doc.get(k) for k in expected} == expected, f"{claim}: got {doc}"
    if doc.get("decision") == "defer":
        with then("a defer carries exactly decision, reason, retry_after_s",
                  keys={"expected": ["decision", "reason", "retry_after_s"], "actual": sorted(doc)}):
            assert set(doc) == {"decision", "reason", "retry_after_s"}


# -- subscription window utilization ---------------------------------------------------------------
# thresholds (policy, ⚖ the old proxy): 5h 0.80, 7d 0.95; reading_stale_s 900. retry = reset − now.
UTIL_ROWS = [
    # 5h 0.80 ≥ 0.80 → blocked until r5 = T0 + 3600 → retry 3600
    ("the 5h window at its threshold defers the subscription until its reset", (0.80, 0.10, H, 3 * 86400), 0, {"rail": "anthropic"},
     {"decision": "defer", "reason": "rail-window", "retry_after_s": 3600}),
    ("the 5h window under its threshold admits", (0.79, 0.10, H, 3 * 86400), 0, {"rail": "anthropic"},
     {"decision": "dispatch", "rail": "anthropic"}),
    ("the 7d window under its own threshold admits", (0.10, 0.94, H, 3 * 86400), 0, {"rail": "anthropic"},
     {"decision": "dispatch", "rail": "anthropic"}),
    # 7d 0.95 ≥ 0.95 → blocked until r7 = T0 + 259200
    ("the 7d window at its threshold defers until the 7d reset", (0.10, 0.95, H, 3 * 86400), 0, {"rail": "anthropic"},
     {"decision": "defer", "reason": "rail-window", "retry_after_s": 259200}),
    # both blocked: the rail frees when the LATER one resets → 259200
    ("both windows over: the later reset names the wait", (0.90, 0.97, H, 3 * 86400), 0, {"rail": "anthropic"},
     {"decision": "defer", "reason": "rail-window", "retry_after_s": 259200}),
    ("a window whose reset has passed is no reading", (0.90, 0.10, -1, 3 * 86400), 0, {"rail": "anthropic"},
     {"decision": "dispatch", "rail": "anthropic"}),
    # seen at T0, asked at T0 + 901 > 900 → stale → admits
    ("a reading older than reading_stale_s is no reading", (0.90, 0.10, H, 3 * 86400), 901, {"rail": "anthropic"},
     {"decision": "dispatch", "rail": "anthropic"}),
    # asked at T0 + 900 (not > 900) → still a reading → retry = 3600 − 900 = 2700
    ("a reading just inside reading_stale_s still defers", (0.90, 0.10, H, 3 * 86400), 900, {"rail": "anthropic"},
     {"decision": "defer", "reason": "rail-window", "retry_after_s": 2700}),
    # reviewer rails = [anthropic, opencode]: anthropic blocked → opencode
    ("the walk continues past a blocked subscription", (0.90, 0.10, H, 3 * 86400), 0, {},
     {"decision": "dispatch", "rail": "opencode"}),
]


@pytest.mark.parametrize(("reading", "advance", "body", "expected"), [r[1:] for r in UTIL_ROWS], ids=[r[0] for r in UTIL_ROWS])
async def test_utilization(gw, upstreams, clock, reading, advance, body, expected):
    world(upstream="upstream-ok", note="the subscription answer carries the row's anthropic-ratelimit-unified-* set")
    u5, u7, d5, d7 = reading
    with given(f"reading = {reading!r}: the last anthropic answer read 5h {u5} (reset T0{d5:+d} s) / 7d {u7} (reset T0{d7:+d} s)"):
        await _ride(gw, upstreams, rail="anthropic", role="reviewer", rate=_rate(u5, u7, clock.t + d5, clock.t + d7))
    with given(f"advance = {advance}: {advance} s pass with no further anthropic answer"):
        clock.advance(advance)
    doc = await _admit(gw, {"role": "reviewer", **body})
    _verdict(doc, expected)


# -- 429 latch per rail ----------------------------------------------------------------------------
# latch_429_hold_s (policy, ⚖ the old proxy): anthropic 900, opencode 900, openrouter none. The fake's
# `upstream-429` sends retry-after: 30 (specs/worlds/), which beats the hold.
LATCH_ROWS = [
    ("an anthropic 429 latches the subscription for its retry-after", [("anthropic", "reviewer", "upstream-429")], 0,
     {"role": "reviewer", "rail": "anthropic"}, {"decision": "defer", "reason": "rail-latched", "retry_after_s": 30}),
    ("a 429 without retry-after latches for the policy hold", [("anthropic", "reviewer", "upstream-429-no-header")], 0,
     {"role": "reviewer", "rail": "anthropic"}, {"decision": "defer", "reason": "rail-latched", "retry_after_s": 900}),
    ("the latch lifts at its expiry", [("anthropic", "reviewer", "upstream-429")], 30,
     {"role": "reviewer", "rail": "anthropic"}, {"decision": "dispatch", "rail": "anthropic"}),
    ("any 2xx on the rail clears the latch", [("anthropic", "reviewer", "upstream-429"), ("anthropic", "reviewer", "upstream-ok")], 0,
     {"role": "reviewer", "rail": "anthropic"}, {"decision": "dispatch", "rail": "anthropic"}),
    ("a Go 429 latches the Go rail", [("opencode", "worker", "upstream-429")], 0,
     {"rail": "opencode"}, {"decision": "defer", "reason": "rail-latched", "retry_after_s": 30}),
    ("a latched rail is skipped, the walk continues", [("opencode", "worker", "upstream-429")], 0,
     {}, {"decision": "dispatch", "rail": "openrouter"}),
    ("a rail whose policy declares no latch does not latch", [("openrouter", "worker", "upstream-429")], 0,
     {"rail": "openrouter"}, {"decision": "dispatch", "rail": "openrouter"}),
    # opencode frees at +30 (latch), openrouter at +60 (full → defer_retry_s): the earlier names the defer
    ("every rail blocked: the rail that frees first names the defer", [("opencode", "worker", "upstream-429"), ("fill", "openrouter", 20)], 0,
     {}, {"decision": "defer", "reason": "rail-latched", "retry_after_s": 30}),
]


@pytest.mark.parametrize(("arrange", "advance", "body", "expected"), [r[1:] for r in LATCH_ROWS], ids=[r[0] for r in LATCH_ROWS])
async def test_latch(gw, upstreams, clock, arrange, advance, body, expected):
    world(upstream="upstream-429", note="the arranged ride's answer; every other answer is upstream-ok")
    doc = None
    for step in arrange:
        if step[0] == "fill":
            with given(f"state: rail {step[1]} holds {step[2]} active sessions (its cap)"):
                await _fill(gw, step[1], step[2])
            continue
        rail, role, behaviour = step
        with given(f"arrange: a {role} ride on {rail} is answered {behaviour}"):
            doc = await _ride(gw, upstreams, rail=rail, role=role, behaviour=behaviour,
                              doc=doc if doc and doc["rail"] == rail else None)
    with given(f"advance = {advance}: {advance} s pass"):
        clock.advance(advance)
    _verdict(await _admit(gw, body), expected)


# -- Go window draw --------------------------------------------------------------------------------
# Prices (policy, ⚖ gometer GO_PRICES 2026-09-17): deepseek-v4-flash off-peak in 0.15 / out 0.60 /
# cache_read 0.003 / cache_write none; peak 0.30 / 1.20 / 0.006 / none; unpriced → fallback 9.00 / 9.00.
# Windows: 5h $12 chain (opens at the first request), 7d $30 weekly Mon 00:00, 30d $60 monthly 13th
# 11:30; threshold 0.80 each → $9.60 / $24 / $48.
M = 1_000_000
DRAW_ROWS = [
    # peak: 20M × 0.30 + 3.2M × 1.20 = 6.00 + 3.84 = $9.84 ≥ $9.60 → blocked until open (T0) + 18000
    ("a 5h draw over threshold defers the Go rail until the window resets", ("worker", {"input_tokens": 20 * M, "output_tokens": 3_200_000}, 0), 0,
     {"rail": "opencode"}, {"decision": "defer", "reason": "rail-window", "retry_after_s": 18000}),
    # peak: 6.00 + 2.8M × 1.20 = 6.00 + 3.36 = $9.36 < $9.60
    ("a 5h draw under threshold admits", ("worker", {"input_tokens": 20 * M, "output_tokens": 2_800_000}, 0), 0,
     {"rail": "opencode"}, {"decision": "dispatch", "rail": "opencode"}),
    # 10:00Z is off-peak: 20M × 0.15 + 3.2M × 0.60 = 3.00 + 1.92 = $4.92 < $9.60
    ("an off-peak request draws at the base rate", ("worker", {"input_tokens": 20 * M, "output_tokens": 3_200_000}, 2 * H), 0,
     {"rail": "opencode"}, {"decision": "dispatch", "rail": "opencode"}),
    # 1000M × 0.006 = $6.00 < $9.60 (at the input rate it would be 1000M × 0.30 = $300)
    ("cache reads draw at their own rate, not the input rate", ("worker", {"input_tokens": 0, "cache_read_input_tokens": 1000 * M, "output_tokens": 0}, 0), 0,
     {"rail": "opencode"}, {"decision": "dispatch", "rail": "opencode"}),
    # cache_write has no rate on this row → $0
    ("a cache class with no rate draws nothing", ("worker", {"input_tokens": 0, "cache_creation_input_tokens": 1000 * M, "output_tokens": 0}, 0), 0,
     {"rail": "opencode"}, {"decision": "dispatch", "rail": "opencode"}),
    # fallback: 1M × 9.00 + 0.1M × 9.00 = $9.90 ≥ $9.60 (deepseek's peak row would give 0.30 + 0.12 = $0.42)
    ("an unpriced model draws at the fallback row", ("reviewer", {"input_tokens": M, "output_tokens": 100_000}, 0), 0,
     {"rail": "opencode"}, {"decision": "defer", "reason": "rail-window", "retry_after_s": 18000}),
    # worker rails = [opencode, openrouter]
    ("the walk continues past a full Go window", ("worker", {"input_tokens": 20 * M, "output_tokens": 3_200_000}, 0), 0,
     {}, {"decision": "dispatch", "rail": "openrouter"}),
    # at T0 + 18000 the chained window [T0, T0 + 18000) has expired, no request opened another;
    # 7d: $9.84 < $24; 30d: $9.84 < $48
    ("an expired 5h window draws nothing", ("worker", {"input_tokens": 20 * M, "output_tokens": 3_200_000}, 0), 18000,
     {"rail": "opencode"}, {"decision": "dispatch", "rail": "opencode"}),
    # 90M × 0.30 = $27 ≥ $24 (7d) and < $48 (30d); 5h expired at T0 + 18000; 7d resets Mon
    # 2027-01-18 00:00Z = T0 + 230400 → retry = 230400 − 18000 = 212400
    ("the 7d window binds once the 5h one has expired", ("worker", {"input_tokens": 90 * M, "output_tokens": 0}, 0), 18000,
     {"rail": "opencode"}, {"decision": "defer", "reason": "rail-window", "retry_after_s": 212400}),
    # 170M × 0.30 = $51 ≥ $48 (30d); at T0 + 230401 the week has reset; the 30d window opened
    # 2027-01-13 11:30Z and resets 2027-02-13 11:30Z = T0 + 2518200 → retry = 2518200 − 230401 = 2287799
    ("the 30d window binds once the week has reset", ("worker", {"input_tokens": 170 * M, "output_tokens": 0}, 0), 230401,
     {"rail": "opencode"}, {"decision": "defer", "reason": "rail-window", "retry_after_s": 2287799}),
]


@pytest.mark.parametrize(("ride", "advance", "body", "expected"), [r[1:] for r in DRAW_ROWS], ids=[r[0] for r in DRAW_ROWS])
async def test_window_draw(gw, upstreams, clock, ride, advance, body, expected):
    world(upstream="upstream-ok-usage", note="the Go answer's anthropic-dialect usage is the row's")
    role, usage, at = ride
    with given(f"ride = {ride!r}: the clock is at T0 + {at} s"):
        clock.advance(at)
    with given(f"ride = {ride!r}: one {role} ride on opencode drew usage {usage}"):
        await _ride(gw, upstreams, rail="opencode", role=role, usage=usage)
    with given(f"advance = {advance}: {advance} s pass with no further Go request"):
        clock.advance(advance)
    _verdict(await _admit(gw, body), expected)
