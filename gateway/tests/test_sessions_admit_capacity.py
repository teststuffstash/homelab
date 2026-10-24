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
| a Go 429 cools only its cell, for its retry-after | worker ride on opencode → 429 | — | worker, rail opencode || defer | — | cell-cooled | 30 |
| a Go 429 without retry-after cools its cell for the rail's hold | worker ride on opencode → 429, no retry-after | — | worker, rail opencode || defer | — | cell-cooled | 900 |
| one Go model's 429 never blocks another Go model | worker ride on opencode → 429 | — | worker, rail opencode, tier heavy || dispatch | opencode | — | — |
| a cooled Go cell is skipped, the walk continues | worker ride on opencode → 429 | — | worker (policy walk) || dispatch | openrouter | — | — |
| a rail whose policy declares no latch is not latched: its other model admits | worker ride on openrouter → 429 | — | worker, rail openrouter, tier heavy || dispatch | openrouter | — | — |
| every rail blocked: the rail that frees first names the defer | worker ride on opencode → 429; openrouter at its 20 | — | worker (policy walk) || defer | — | cell-cooled | 30 |

Go window draw (the world's Go catalog: catalog-ok + docs-ok, plan go). worker on opencode =
opencode-go/deepseek-v4.1-flash ($80/month → 5h $16 · 7d $40 · 30d $80; × 0.80 = $12.80 / $32 /
$64); worker tier heavy / reviewer = opencode-go/claude-haiku-5-5 ($15/month → 5h $3 × 0.80 = $2.40):

| description | ride usage (at) | then | body || decision | rail | reason | retry_after_s |
|---|---|---|---||---|---|---|---|
| a 5h draw over threshold defers the Go model until its window resets | worker in 30M, out 3.2M (T0, peak) — $12.84 | — | worker, rail opencode || defer | — | rail-window | 18000 |
| a 5h draw under threshold admits | worker in 30M, out 3.1M (T0, peak) — $12.72 | — | worker, rail opencode || dispatch | opencode | — | — |
| an off-peak request draws at the base rate | worker in 30M, out 3.2M (T0 + 2 h) — $6.42 | — | worker, rail opencode || dispatch | opencode | — | — |
| cache reads draw at their own rate, not the input rate | worker cache_read 1000M (T0) — $6.00 | — | worker, rail opencode || dispatch | opencode | — | — |
| a cache class with no rate draws nothing | worker cache_write 1000M (T0) — $0 | — | worker, rail opencode || dispatch | opencode | — | — |
| a prompt past the context tier draws at the tier's rate | reviewer in 4M, out 0.2M (T0) — $2.50 (the base row: $0.50) | — | worker, rail opencode, tier heavy || defer | — | rail-window | 18000 |
| a prompt within the context tier draws at the base row | reviewer in 90K, out 1M (T0) — $0.509 (the tier row: $2.545) | — | worker, rail opencode, tier heavy || dispatch | opencode | — | — |
| each model's windows are its own monthly limit's shares | worker in 10M, out 1M (T0) — $4.20 (< $12.80; haiku's $2.40 would block) | — | worker, rail opencode || dispatch | opencode | — | — |
| a full window on one Go model never blocks another | worker in 30M, out 3.2M (T0) | — | worker, rail opencode, tier heavy || dispatch | opencode | — | — |
| the walk continues past a full Go window | worker in 30M, out 3.2M (T0) | — | worker (policy walk) || dispatch | openrouter | — | — |
| an expired 5h window draws nothing | worker in 30M, out 3.2M (T0) | +18000 s | worker, rail opencode || dispatch | opencode | — | — |
| the 7d window binds once the 5h one has expired | worker in 110M (T0) — $33 | +18000 s | worker, rail opencode || defer | — | rail-window | 212400 |
| the 30d window binds once the week has reset | worker in 220M (T0) — $66 | +230401 s | worker, rail opencode || defer | — | rail-window | 2287799 |

Not in the catalog (ruling 4): a refresh against the fake vendor (`catalog-retired` drops
deepseek-v4.1-flash from the catalog; `docs-retired` drops claude-haiku-5-5's plan rows), then:

| description | the refresh || body || decision | rail | reason | retry_after_s |
|---|---|---|---||---|---|---|---|
| a Go model the catalog no longer lists defers not-in-catalog | catalog-retired | — | worker, rail opencode || defer | — | not-in-catalog | 21600 |
| a not-in-catalog model is skipped, the walk continues | catalog-retired | — | worker (policy walk) || dispatch | openrouter | — | — |
| a listed model with no monthly limit under the plan defers not-in-catalog | docs-retired | — | worker, rail opencode, tier heavy || defer | — | not-in-catalog | 21600 |
| the other Go models still admit | catalog-retired | — | worker, rail opencode, tier heavy || dispatch | opencode | — | — |
| no catalog snapshot at all: every Go model is not-in-catalog | none (a fresh store) | — | worker, rail opencode || defer | — | not-in-catalog | 60 |
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
# latch_429_hold_s (policy, ⚖ the old proxy): anthropic 900 (latch_scope account), opencode 900
# (latch_scope model: a 429 cools only its cell — GW-CATALOG-GO ruling 3), openrouter none. The fake's
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
    ("a Go 429 cools only its cell, for its retry-after", [("opencode", "worker", "upstream-429")], 0,
     {"rail": "opencode"}, {"decision": "defer", "reason": "cell-cooled", "retry_after_s": 30}),
    ("a Go 429 without retry-after cools its cell for the rail's hold", [("opencode", "worker", "upstream-429-no-header")], 0,
     {"rail": "opencode"}, {"decision": "defer", "reason": "cell-cooled", "retry_after_s": 900}),
    # the worker's standard cell (deepseek-v4.1-flash) cooled; its heavy tier is claude-haiku-5-5
    ("one Go model's 429 never blocks another Go model", [("opencode", "worker", "upstream-429")], 0,
     {"rail": "opencode", "tier": "heavy"}, {"decision": "dispatch", "rail": "opencode"}),
    ("a cooled Go cell is skipped, the walk continues", [("opencode", "worker", "upstream-429")], 0,
     {}, {"decision": "dispatch", "rail": "openrouter"}),
    # openrouter declares no latch: the 429 cooled only its cell (deepseek-v4-flash, the worker's standard
    # tier — test_sessions_admit_cells.py); the heavy tier's deepseek-v4.1-flash cell is untouched
    ("a rail whose policy declares no latch is not latched: its other model admits", [("openrouter", "worker", "upstream-429")], 0,
     {"rail": "openrouter", "tier": "heavy"}, {"decision": "dispatch", "rail": "openrouter"}),
    # opencode frees at +30 (the cell), openrouter at +60 (full → defer_retry_s): the earlier names the defer
    ("every rail blocked: the rail that frees first names the defer", [("opencode", "worker", "upstream-429"), ("fill", "openrouter", 20)], 0,
     {}, {"decision": "defer", "reason": "cell-cooled", "retry_after_s": 30}),
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
# Every price, peak row/hour, monthly limit and window share is the world's Go catalog snapshot
# (conftest.seed_go_catalog: catalog-ok + docs-ok, plan go — GW-CATALOG-GO), never the policy:
#   deepseek-v4.1-flash  base 0.15 / 0.60 / cache_read 0.003 / cache_write none; peak (Mon–Fri
#                        01–04 + 06–10 UTC) 0.30 / 1.20 / 0.006 / none; $80/month
#   claude-haiku-5-5     base 0.10 / 0.50 / 0.01 / 0.125; above 100000 prompt tokens 0.50 / 2.50 /
#                        0.05 / 0.625; no peak row; $15/month
# Shares 5h 0.2 · 7d 0.5 · 30d 1.0; policy threshold 0.80 each → v4.1-flash $12.80 / $32 / $64,
# haiku $2.40 / $6 / $12. Anchors (policy): 5h chain, 7d weekly Mon 00:00, 30d monthly 13th 11:30.
M = 1_000_000
DRAW_ROWS = [
    # peak: 30M × 0.30 + 3.2M × 1.20 = 9.00 + 3.84 = $12.84 ≥ $12.80 → blocked until open (T0) + 18000
    ("a 5h draw over threshold defers the Go model until its window resets", ("worker", {"input_tokens": 30 * M, "output_tokens": 3_200_000}, 0), 0,
     {"rail": "opencode"}, {"decision": "defer", "reason": "rail-window", "retry_after_s": 18000}),
    # peak: 9.00 + 3.1M × 1.20 = 9.00 + 3.72 = $12.72 < $12.80
    ("a 5h draw under threshold admits", ("worker", {"input_tokens": 30 * M, "output_tokens": 3_100_000}, 0), 0,
     {"rail": "opencode"}, {"decision": "dispatch", "rail": "opencode"}),
    # 10:00Z is off-peak: 30M × 0.15 + 3.2M × 0.60 = 4.50 + 1.92 = $6.42 < $12.80
    ("an off-peak request draws at the base rate", ("worker", {"input_tokens": 30 * M, "output_tokens": 3_200_000}, 2 * H), 0,
     {"rail": "opencode"}, {"decision": "dispatch", "rail": "opencode"}),
    # 1000M × 0.006 = $6.00 < $12.80 (at the input rate it would be 1000M × 0.30 = $300)
    ("cache reads draw at their own rate, not the input rate", ("worker", {"input_tokens": 0, "cache_read_input_tokens": 1000 * M, "output_tokens": 0}, 0), 0,
     {"rail": "opencode"}, {"decision": "dispatch", "rail": "opencode"}),
    # cache_write has no rate on v4.1-flash's rows → $0
    ("a cache class with no rate draws nothing", ("worker", {"input_tokens": 0, "cache_creation_input_tokens": 1000 * M, "output_tokens": 0}, 0), 0,
     {"rail": "opencode"}, {"decision": "dispatch", "rail": "opencode"}),
    # haiku, prompt 4M > 100000 → the tier row: 4M × 0.50 + 0.2M × 2.50 = 2.00 + 0.50 = $2.50 ≥ $2.40
    # → blocked (the base row would draw 0.40 + 0.10 = $0.50 and admit)
    ("a prompt past the context tier draws at the tier's rate", ("reviewer", {"input_tokens": 4 * M, "output_tokens": 200_000}, 0), 0,
     {"rail": "opencode", "tier": "heavy"}, {"decision": "defer", "reason": "rail-window", "retry_after_s": 18000}),
    # haiku, prompt 90000 ≤ 100000 → the base row: 0.09M × 0.10 + 1M × 0.50 = 0.009 + 0.50 = $0.509 < $2.40
    # → admits (the tier row would draw 0.045 + 2.50 = $2.545 and block)
    ("a prompt within the context tier draws at the base row", ("reviewer", {"input_tokens": 90_000, "output_tokens": 1_000_000}, 0), 0,
     {"rail": "opencode", "tier": "heavy"}, {"decision": "dispatch", "rail": "opencode"}),
    # v4.1-flash, peak: 10M × 0.30 + 1M × 1.20 = 3.00 + 1.20 = $4.20 < its own $12.80 → admits
    # (against haiku's $2.40 it would block)
    ("each model's windows are its own monthly limit's shares", ("worker", {"input_tokens": 10 * M, "output_tokens": 1_000_000}, 0), 0,
     {"rail": "opencode"}, {"decision": "dispatch", "rail": "opencode"}),
    # v4.1-flash's 5h window is full ($12.84); the heavy tier's claude-haiku-5-5 cell drew nothing
    ("a full window on one Go model never blocks another", ("worker", {"input_tokens": 30 * M, "output_tokens": 3_200_000}, 0), 0,
     {"rail": "opencode", "tier": "heavy"}, {"decision": "dispatch", "rail": "opencode"}),
    # worker rails = [opencode, openrouter]
    ("the walk continues past a full Go window", ("worker", {"input_tokens": 30 * M, "output_tokens": 3_200_000}, 0), 0,
     {}, {"decision": "dispatch", "rail": "openrouter"}),
    # at T0 + 18000 the chained window [T0, T0 + 18000) has expired, no request opened another;
    # 7d: $12.84 < $32; 30d: $12.84 < $64
    ("an expired 5h window draws nothing", ("worker", {"input_tokens": 30 * M, "output_tokens": 3_200_000}, 0), 18000,
     {"rail": "opencode"}, {"decision": "dispatch", "rail": "opencode"}),
    # 110M × 0.30 = $33 ≥ $32 (7d) and < $64 (30d); 5h expired at T0 + 18000; 7d resets Mon
    # 2027-01-18 00:00Z = T0 + 230400 → retry = 230400 − 18000 = 212400
    ("the 7d window binds once the 5h one has expired", ("worker", {"input_tokens": 110 * M, "output_tokens": 0}, 0), 18000,
     {"rail": "opencode"}, {"decision": "defer", "reason": "rail-window", "retry_after_s": 212400}),
    # 220M × 0.30 = $66 ≥ $64 (30d); at T0 + 230401 the week has reset; the 30d window opened
    # 2027-01-13 11:30Z and resets 2027-02-13 11:30Z = T0 + 2518200 → retry = 2518200 − 230401 = 2287799
    ("the 30d window binds once the week has reset", ("worker", {"input_tokens": 220 * M, "output_tokens": 0}, 0), 230401,
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


# -- not in the catalog (GW-CATALOG-GO ruling 4) ----------------------------------------------------
# The world's catalog is refreshed against the fake vendor (tests/_catalog_world.py) before the ask:
# `catalog-retired` = the catalog (models.dev) without deepseek-v4.1-flash; `docs-retired` = the Go
# page without claude-haiku-5-5's plan rows (listed by the catalog, but no monthly limit). retry =
# the next scheduled refresh: the refresh at T0 + GATEWAY_GO_CATALOG_REFRESH_S (21600, the default).
CATALOG_ROWS = [
    ("a Go model the catalog no longer lists defers not-in-catalog", ("config", "catalog-retired"),
     {"rail": "opencode"}, {"decision": "defer", "reason": "not-in-catalog", "retry_after_s": 21600}),
    ("a not-in-catalog model is skipped, the walk continues", ("config", "catalog-retired"),
     {}, {"decision": "dispatch", "rail": "openrouter"}),
    ("a listed model with no monthly limit under the plan defers not-in-catalog", ("docs", "docs-retired"),
     {"rail": "opencode", "tier": "heavy"}, {"decision": "defer", "reason": "not-in-catalog", "retry_after_s": 21600}),
    ("the other Go models still admit", ("config", "catalog-retired"),
     {"rail": "opencode", "tier": "heavy"}, {"decision": "dispatch", "rail": "opencode"}),
]


@pytest.mark.parametrize(("refresh", "body", "expected"), [r[1:] for r in CATALOG_ROWS], ids=[r[0] for r in CATALOG_ROWS])
async def test_not_in_catalog(gw, app, vendor, refresh, body, expected):
    source, behaviour = refresh
    world(upstream=behaviour, note="the Go catalog's fake vendor answers the refresh")
    with given(f"refresh = {refresh!r}: the {source} source refreshes against {behaviour}"):
        setattr(vendor, "catalog" if behaviour.startswith("catalog-") else source, behaviour)
        outcome = await app.state.catalog.refresh_source(source)
        attach_json("refresh outcome", {"source": source, "behaviour": behaviour, "outcome": outcome})
        assert outcome == "ok", outcome
    _verdict(await _admit(gw, body), expected)


async def test_no_snapshot(cworld):
    """row: no catalog snapshot at all: every Go model is not-in-catalog ⚖"""
    world(note="a fresh store: no catalog snapshot, no refresh attempted yet (fails closed)")
    from ._catalog_world import gw_client

    with given("a gateway on a fresh store — no Go catalog snapshot, no refresh run"):
        app = cworld.build()
    async with gw_client(app) as gw:
        _verdict(await _admit(gw, {"rail": "opencode"}), {"decision": "defer", "reason": "not-in-catalog", "retry_after_s": 60})
