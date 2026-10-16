"""GW-CODEX-HEADROOM — the codex rail's account headroom as admission (specs/endpoints/openai-responses.md).

World `policy-codex`: rails.codex.headroom = max_age_s 120, ceiling 0.95, windows_minutes
[300, 10080]; defer_retry_s = 60 (the loader's default — policy-codex sets none). Ported from
experiments/codex-rail/test_headroom.py (FU-270); the admission rows are new (the gateway composition).

Reports (now T; last accepted observed at T-10, 20 % / 64 %):

| description | report | accepted | verdict after |
|---|---|---|---|
| a fresh two-window report admits and normalises | poll, T-10, 20/64 (first) | yes, 0.20/0.64 | admit |
| no report yet is unknown | - | - | quota-unknown |
| a gateway restart forgets | a fresh Headroom | - | quota-unknown |
| an equal or older timestamp cannot overwrite | T-10, T-11, T-110 (limited) | no, quota-out-of-order | admit |
| a newer report from another source replaces | jail, T-1, limited | yes | quota-limited |
| a report at the freshness bound is refused | T-120 | no, quota-time-invalid | admit |
| a future report is refused | T+1 | no, quota-time-invalid | admit |
| a non-finite or bool timestamp is refused | true, NaN, inf | no, quota-time-invalid | admit |
| a missing or duplicated window is refused | [], 5h twice | no, quota-invalid | unknown |
| a window outside the profile is refused | 301, true | no, quota-invalid | unknown |
| an out-of-range or non-finite percentage is refused | -1, 101, true, NaN, inf | no, quota-invalid | unknown |
| an already-passed reset is refused | <= T, true, NaN | no, quota-invalid | unknown |
| an unknown source or a non-bool flag is refused | untrusted, limited 0, not an object | no, quota-invalid | unknown |

Verdicts:

| description | snapshot (T-10) | now | verdict |
|---|---|---|---|
| a window at the ceiling limits | 95/64 | T | quota-limited |
| either window limits | 20/95 | T | quota-limited |
| the explicit flag limits | 20/64 limited | T | quota-limited |
| the freshness bound is stale | 20/64 | T+110 | quota-stale |
| a clock rollback is stale | 20/64 | T-20 | quota-stale |
| a reset passing is stale, not replenished | 5h resets T+10 | T+10 | quota-stale |

Admission:

| description | headroom | decision | reason | retry_after_s |
|---|---|---|---|---|
| fresh headroom admits the codex harness | 20/64 | dispatch codex | - | - |
| no observation defers unknown | - | defer | quota-unknown | 60 |
| a stale observation defers stale | T-10, asked T+115 | defer | quota-stale | 60 |
| an exhausted window defers until its reset | 96/64, 5h resets T+1000 | defer | quota-limited | 1000 |
| two exhausted windows wait for the later reset | 96/97, resets T+1000/T+8000 | defer | quota-limited | 8000 |
| the explicit flag alone defers by the policy interval | 20/64 limited | defer | quota-limited | 60 |
| headroom is read before the credential store | none; store would fail | defer | quota-unknown, store never read | 60 |
| the rail's session cap still applies | fresh; 2 active | defer | rail-capacity | 60 |
| an admitted session is not re-gated on the data plane | dispatched, then limited | data plane 200 | - | - |
"""

from __future__ import annotations

import copy

import pytest

from agent_gateway.config import Policy
from agent_gateway.headroom import Headroom, ReportError, Verdict

from ._codex_world import (
    CODEX_POLICY,
    codex_session,
    fresh_report,
    observe,
    ride,
)
from .conftest import attach_json, check, given, quiet, rule, then, then_eq, when, world

pytestmark = rule("GW-CODEX-HEADROOM")

T = 1000.0  # the seam rows' clock; reports are built relative to it


def _policy():
    return Policy.load(CODEX_POLICY).rails["codex"].headroom


class _Clock:
    def __init__(self, t=T):
        self.t = t

    def __call__(self):
        return self.t


def _report(at=T - 10, used=(20, 64), limited=False, source="poll", resets=(T + 1000, T + 8000)) -> dict:
    return {"observed_at": at, "source": source, "limited": limited,
            "windows": [{"used_percent": used[0], "resets_at": resets[0], "window_minutes": 300},
                        {"used_percent": used[1], "resets_at": resets[1], "window_minutes": 10080}]}


def _room(clock=None) -> Headroom:
    return Headroom(clock or _Clock(), _policy())


def test_fresh_report():
    """row: a fresh two-window report admits and normalises"""
    world("policy-codex")
    room = _room()
    with when("observe poll T-10, 20 % / 64 %"):
        snap = room.observe(_report())
    then_eq("normalised ratios", [w.used for w in snap.windows], [0.20, 0.64])
    then_eq("verdict", room.verdict(), Verdict.ADMIT)


def test_no_report():
    """row: no report yet is unknown"""
    world("policy-codex")
    with when("a fresh Headroom, nothing observed"):
        v = _room().verdict()
    then_eq("verdict", v, Verdict.UNKNOWN)


def test_restart():
    """row: a gateway restart forgets"""
    world("policy-codex")
    clock = _Clock()
    with given("one accepted report on the old instance"):
        _room(clock).observe(_report())
    with when("a new Headroom (the restarted gateway)"):
        v = _room(clock).verdict()
    then_eq("verdict", v, Verdict.UNKNOWN)


def _refused(room, report, code) -> None:
    try:
        room.observe(report)
    except ReportError as e:
        assert str(e) == code, (str(e), code)
    else:
        raise AssertionError(f"accepted: {report}")


def test_out_of_order():
    """row: an equal or older timestamp cannot overwrite"""
    world("policy-codex")
    room = _room()
    with given("last accepted: poll T-10, 20 % / 64 %"):
        room.observe(_report())
    with when("observe T-10, T-11, T-110 — each limited"):
        for at in (T - 10, T - 11, T - 110):
            with then(f"observed_at {at:g} refused quota-out-of-order"):
                _refused(room, _report(at=at, limited=True), "quota-out-of-order")
    then_eq("verdict", room.verdict(), Verdict.ADMIT, claim="verdict = admit (unchanged)")


def test_newer_other_source():
    """row: a newer report from another source replaces"""
    world("policy-codex")
    room = _room()
    with given("last accepted: poll T-10"):
        room.observe(_report())
    with when("observe jail T-1, limited"):
        room.observe(_report(at=T - 1, source="jail", limited=True))
    then_eq("verdict", room.verdict(), Verdict.LIMITED)


TIME_ROWS = [
    ("a report at the freshness bound is refused", [T - 120]),
    ("a future report is refused", [T + 1]),
    ("a non-finite or bool timestamp is refused", [True, float("nan"), float("inf")]),
]


@pytest.mark.parametrize("ats", [r[1] for r in TIME_ROWS], ids=[r[0] for r in TIME_ROWS])
def test_time_refused(ats):
    world("policy-codex")
    room = _room()
    with given("last accepted: poll T-10"):
        room.observe(_report())
    with when(f"observe at {ats}"):
        for at in ats:
            with then(f"observed_at {at!r} refused quota-time-invalid"):
                _refused(room, _report(at=at, limited=True), "quota-time-invalid")
    then_eq("verdict", room.verdict(), Verdict.ADMIT, claim="verdict = admit (unchanged)")


def _window(key, value) -> dict:
    r = _report()
    r["windows"][0][key] = value
    return r


SHAPE_ROWS = [
    ("a missing or duplicated window is refused", [dict(_report(), windows=[]), dict(_report(), windows=[_report()["windows"][0]] * 2)]),
    ("a window outside the profile is refused", [_window("window_minutes", 301), _window("window_minutes", True)]),
    ("an out-of-range or non-finite percentage is refused", [_window("used_percent", v) for v in (-1, 101, True, float("nan"), float("inf"))]),
    ("an already-passed reset is refused", [_window("resets_at", v) for v in (T, T - 1, True, float("nan"))]),
    ("an unknown source or a non-bool flag is refused", [dict(_report(), source="untrusted"), dict(_report(), limited=0), None, [_report()]]),
]


@pytest.mark.parametrize("reports", [r[1] for r in SHAPE_ROWS], ids=[r[0] for r in SHAPE_ROWS])
def test_shape_refused(reports):
    world("policy-codex")
    room = _room()
    with when(f"observe {len(reports)} malformed reports"):
        for report in reports:
            with then(f"refused quota-invalid: {report!r}"[:160]):
                _refused(room, copy.deepcopy(report), "quota-invalid")
    then_eq("verdict", room.verdict(), Verdict.UNKNOWN, claim="verdict = unknown (nothing accepted)")


VERDICT_ROWS = [
    ("a window at the ceiling limits", _report(used=(95, 64)), T, Verdict.LIMITED),
    ("either window limits", _report(used=(20, 95)), T, Verdict.LIMITED),
    ("the explicit flag limits", _report(limited=True), T, Verdict.LIMITED),
    ("the freshness bound is stale", _report(), T + 110, Verdict.STALE),  # age = T+110 − (T−10) = 120 = max_age_s
    ("a clock rollback is stale", _report(), T - 20, Verdict.STALE),
    ("a reset passing is stale, not replenished", _report(resets=(T + 10, T + 8000)), T + 10, Verdict.STALE),
]


@pytest.mark.parametrize(("report", "now", "verdict"), [r[1:] for r in VERDICT_ROWS], ids=[r[0] for r in VERDICT_ROWS])
def test_verdicts(report, now, verdict):
    world("policy-codex")
    clock = _Clock()
    room = _room(clock)
    with given(f"snapshot {[w['used_percent'] for w in report['windows']]} %, limited={report['limited']}, observed T-10"):
        room.observe(report)
    with when(f"verdict at now = T{now - T:+g}"):
        clock.t = now
        v = room.verdict()
    then_eq("verdict", v, verdict)


# -- admission through POST /sessions -----------------------------------------------------------

def _limited(clock, used, resets=(1000, 8000)):
    return fresh_report(clock, used=used, resets=resets)


ADMIT_ROWS = [
    # retry_after_s expectations: defer_retry_s = 60 (Policy default; policy-codex sets none) unless
    # windows block — then the LATEST exhausted window's reset − now (fresh_report resets at now+1000 / now+8000)
    ("fresh headroom admits the codex harness", lambda c: fresh_report(c), 0, {"decision": "dispatch", "rail": "codex"}),
    ("no observation defers unknown", None, 0, {"decision": "defer", "reason": "quota-unknown", "retry_after_s": 60}),
    ("a stale observation defers stale", lambda c: fresh_report(c), 115, {"decision": "defer", "reason": "quota-stale", "retry_after_s": 60}),
    ("an exhausted window defers until its reset", lambda c: _limited(c, (96, 64)), 0, {"decision": "defer", "reason": "quota-limited", "retry_after_s": 1000}),
    ("two exhausted windows wait for the later reset", lambda c: _limited(c, (96, 97)), 0, {"decision": "defer", "reason": "quota-limited", "retry_after_s": 8000}),
    ("the explicit flag alone defers by the policy interval", lambda c: fresh_report(c, limited=True), 0, {"decision": "defer", "reason": "quota-limited", "retry_after_s": 60}),
]


@pytest.mark.parametrize(("report", "advance", "expected"), [r[1:] for r in ADMIT_ROWS], ids=[r[0] for r in ADMIT_ROWS])
async def test_admission(codex_app, codex_gw, clock, report, advance, expected):
    world("policy-codex")
    if report is not None:
        observe(codex_app, report(clock))
    else:
        with given("no headroom observation"):
            pass
    if advance:
        with given(f"the clock advances {advance} s (the report is now {advance + 10} s old, max_age_s 120)"):
            clock.advance(advance)
    with when("POST /sessions {role: prober, harness: codex}"):
        r = await codex_gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "t", "harness": "codex"})
    doc = r.json()
    with then("expected " + ", ".join(f"{k} = {v}" for k, v in expected.items())):
        for k, v in expected.items():
            check(k, doc.get(k), v)


async def test_headroom_before_store(codex_app, codex_gw, codex_store):
    """row: headroom is read before the credential store"""
    world("policy-codex")

    def broken():
        raise RuntimeError("DUMMY-SECRET store down")
    with given("no observation; the store's lock would raise"):
        codex_store.lock = broken
    with when("POST /sessions {role: prober, harness: codex}"):
        r = await codex_gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "t", "harness": "codex"})
    then_eq("(decision, reason)", (r.json()["decision"], r.json()["reason"]), ("defer", "quota-unknown"))
    then_eq("store loads", codex_store.loads, 0, claim="the store was never read")


async def test_rail_cap(codex_app, codex_gw, clock):
    """row: the rail's session cap still applies"""
    world("policy-codex")
    observe(codex_app, fresh_report(clock))
    with given("2 codex sessions active (rails.codex.max_sessions = 2)"):
        with quiet():
            for i in range(2):
                await codex_session(codex_gw, round=i)
        attach_json("filled", {"codex": 2})
    with when("POST /sessions {role: prober, harness: codex}"):
        r = await codex_gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "t", "harness": "codex"})
    then_eq("(decision, reason, retry_after_s)", (r.json()["decision"], r.json()["reason"], r.json()["retry_after_s"]), ("defer", "rail-capacity", 60))


async def test_no_regate_on_data_plane(codex_app, codex_gw, codex_upstream, clock):
    """row: an admitted session is not re-gated on the data plane"""
    world("policy-codex", "upstream-ok")
    observe(codex_app, fresh_report(clock))
    with given("a codex session dispatched at 20 % / 64 %"):
        doc = await codex_session(codex_gw)
    observe(codex_app, fresh_report(clock, used=(99, 99), limited=True, age=5))
    with given("the new verdict is quota-limited"):
        check("verdict", codex_app.state.codex.headroom.verdict(), Verdict.LIMITED)
    r = await ride(codex_gw, doc)
    then_eq("status", r.status_code, 200)
    then_eq("upstream calls", len(codex_upstream.calls), 1)
