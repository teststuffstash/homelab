"""GW-CODEX-HEADROOM — the codex rail's account headroom snapshot (specs/endpoints/openai-responses.md
§GW-CODEX-HEADROOM: a report replaces the snapshot, a malformed report is refused, the verdict, the gauges).

World `policy-codex`: rails.codex.headroom = max_age_s 120, ceiling 0.95, windows_minutes [300, 10080].
Rows drive the `Headroom` seam with a clock at T; the gauge rows read /metrics through the gateway.
Ported from experiments/codex-rail/test_headroom.py (FU-270). Argnames = each table's header, ids = its
description cells; the admission rows are tests/test_codex_admission.py (GW-CODEX-ADMISSION).
"""

from __future__ import annotations

import copy
import re

import pytest

from agent_gateway.config import Policy
from agent_gateway.headroom import Headroom, ReportError, Window
from agent_gateway.metrics import Metrics

from ._codex_rows import expect, row, verdicts
from ._codex_world import CODEX_POLICY, fresh_report, observe
from .conftest import attach_json, given, quiet, rule, then, when, world

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


def _snapshot(room: Headroom) -> str:
    s = room.snapshot
    if s is None:
        return "none"
    return " / ".join(f"{w.used:g}" for w in s.windows) + (", limited" if s.limited else "")


def _refusal(room, report) -> str:
    """`accepted`, or the ReportError code the observation raised."""
    try:
        room.observe(copy.deepcopy(report))
    except ReportError as e:
        return str(e)
    return "accepted"


# -- a report replaces the snapshot ---------------------------------------------------------------

LAST = "poll, T−10, 20 % / 64 %"


@pytest.mark.parametrize(("last_accepted", "report", "expected_accepted", "expected_snapshot", "expected_verdict"), [
    pytest.param("none", LAST, "accepted", "0.2 / 0.64", "admit", id="a fresh two-window report admits and normalises"),
    pytest.param("none", "none", "—", "none", "quota-unknown", id="no report yet is unknown"),
    pytest.param(f"{LAST} (on the old instance)", "none", "—", "none", "quota-unknown", id="a gateway restart forgets"),
    pytest.param(LAST, "poll, T−10 / T−11 / T−110, 20 % / 64 %, limited", "quota-out-of-order", "0.2 / 0.64", "admit", id="an equal or older timestamp cannot overwrite"),
    pytest.param(LAST, "jail, T−1, limited", "accepted", "0.2 / 0.64, limited", "quota-limited", id="a newer report from another source replaces"),
])
def test_report_replaces(last_accepted, report, expected_accepted, expected_snapshot, expected_verdict):
    world("policy-codex")
    row(last_accepted=last_accepted, report=report, expected_accepted=expected_accepted, expected_snapshot=expected_snapshot,
        expected_verdict=expected_verdict)
    clock = _Clock()
    room = _room(clock)
    with given(f"last_accepted {last_accepted}"):
        if last_accepted.endswith("(on the old instance)"):
            _room(clock).observe(_report())  # the old instance; `room` is the restarted one
        elif last_accepted != "none":
            room.observe(_report())
    with when(f"observe report {report}"):
        if report == "none":
            accepted = "—"
        elif report == LAST:
            accepted = _refusal(room, _report())
        elif report.startswith("jail"):
            accepted = _refusal(room, _report(at=T - 1, source="jail", limited=True))
        else:
            outcomes = [_refusal(room, _report(at=at, limited=True)) for at in (T - 10, T - 11, T - 110)]
            accepted = outcomes[0] if len(set(outcomes)) == 1 else " / ".join(outcomes)
    verdicts(
        accepted=(accepted, expected_accepted),
        snapshot=(_snapshot(room), expected_snapshot),
        verdict=(str(room.verdict()), expected_verdict),
    )


# -- a malformed report is refused ----------------------------------------------------------------

def _window(key, value) -> dict:
    r = _report()
    r["windows"][0][key] = value
    return r


MALFORMED = {  # the `report` cell → the malformed reports it names (each offered in turn)
    "observed_at T−120": lambda: [_report(at=T - 120, limited=True)],
    "observed_at T+1": lambda: [_report(at=T + 1, limited=True)],
    "observed_at true / NaN / ∞": lambda: [_report(at=at, limited=True) for at in (True, float("nan"), float("inf"))],
    "windows: [] / the 5h window twice": lambda: [dict(_report(), windows=[]), dict(_report(), windows=[_report()["windows"][0]] * 2)],
    "window_minutes: 301 / true": lambda: [_window("window_minutes", 301), _window("window_minutes", True)],
    "used_percent −1 / 101 / true / NaN / ∞": lambda: [_window("used_percent", v) for v in (-1, 101, True, float("nan"), float("inf"))],
    "resets_at ≤ T / true / NaN": lambda: [_window("resets_at", v) for v in (T, T - 1, True, float("nan"))],
    "source: untrusted / limited: 0 / not an object": lambda: [dict(_report(), source="untrusted"), dict(_report(), limited=0), None, [_report()]],
}


@pytest.mark.parametrize(("last_accepted", "report", "expected_refused", "expected_verdict"), [
    pytest.param(LAST, "observed_at T−120", "quota-time-invalid", "admit", id="a report at the freshness bound is refused"),
    pytest.param(LAST, "observed_at T+1", "quota-time-invalid", "admit", id="a future report is refused"),
    pytest.param(LAST, "observed_at true / NaN / ∞", "quota-time-invalid", "admit", id="a non-finite or bool timestamp is refused"),
    pytest.param("none", "windows: [] / the 5h window twice", "quota-invalid", "quota-unknown", id="a missing or duplicated window is refused"),
    pytest.param("none", "window_minutes: 301 / true", "quota-invalid", "quota-unknown", id="a window outside the profile is refused"),
    pytest.param("none", "used_percent −1 / 101 / true / NaN / ∞", "quota-invalid", "quota-unknown", id="an out-of-range or non-finite percentage is refused"),
    pytest.param("none", "resets_at ≤ T / true / NaN", "quota-invalid", "quota-unknown", id="an already-passed reset is refused"),
    pytest.param("none", "source: untrusted / limited: 0 / not an object", "quota-invalid", "quota-unknown", id="an unknown source or a non-bool flag is refused"),
])
def test_malformed_refused(last_accepted, report, expected_refused, expected_verdict):
    world("policy-codex")
    row(last_accepted=last_accepted, report=report, expected_refused=expected_refused, expected_verdict=expected_verdict)
    room = _room()
    with given(f"last_accepted {last_accepted}"):
        if last_accepted != "none":
            room.observe(_report())
    reports = MALFORMED[report]()
    with when(f"observe report {report} ({len(reports)} variants)"):
        outcomes = []
        for variant in reports:
            outcome = _refusal(room, variant)
            outcomes.append(outcome)
            with then(f"{outcome}: {variant!r}"[:160]):
                pass
    verdicts(
        refused=(outcomes[0] if len(set(outcomes)) == 1 else " / ".join(outcomes), expected_refused),
        verdict=(str(room.verdict()), expected_verdict),
    )


# -- the verdict ----------------------------------------------------------------------------------

SNAPSHOTS = {  # the `snapshot` cell → the accepted report (observed T−10)
    "95 % / 64 %": lambda: _report(used=(95, 64)),
    "20 % / 95 %": lambda: _report(used=(20, 95)),
    "20 % / 64 %, limited": lambda: _report(limited=True),
    "20 % / 64 %": lambda: _report(),
    "20 % / 64 %, the 5h window resets at T+10": lambda: _report(resets=(T + 10, T + 8000)),
}
NOW = {"T": T, "T+110 (age 120)": T + 110, "T−20": T - 20, "T+10": T + 10}  # age = T+110 − (T−10) = 120 = max_age_s


@pytest.mark.parametrize(("snapshot", "now", "expected_verdict"), [
    pytest.param("95 % / 64 %", "T", "quota-limited", id="a window at the ceiling limits"),
    pytest.param("20 % / 95 %", "T", "quota-limited", id="either window limits"),
    pytest.param("20 % / 64 %, limited", "T", "quota-limited", id="the explicit flag limits"),
    pytest.param("20 % / 64 %", "T+110 (age 120)", "quota-stale", id="the freshness bound is stale ⚖"),
    pytest.param("20 % / 64 %", "T−20", "quota-stale", id="a clock rollback is stale"),
    pytest.param("20 % / 64 %, the 5h window resets at T+10", "T+10", "quota-stale", id="a reset passing is stale, not replenished ⚖"),
])
def test_verdict(snapshot, now, expected_verdict):
    world("policy-codex")
    row(snapshot=snapshot, now=now, expected_verdict=expected_verdict)
    clock = _Clock()
    room = _room(clock)
    with given(f"snapshot {snapshot}, observed T−10"):
        room.observe(SNAPSHOTS[snapshot]())
    with when(f"the verdict at now = {now}"):
        clock.t = NOW[now]
        v = room.verdict()
    expect("verdict", str(v), expected_verdict)


# -- the gauges (§Gauges) -------------------------------------------------------------------------

CODEX_SERIES = [f'gateway_subscription_{fam}{{rail="codex",window="{w}"}}' for fam in ("utilization", "reset_seconds") for w in ("5h", "7d")]
FIRST = "poll, now−10, 20 % / 64 %, resets now+1000 / now+8000"


def _sample(text: str, series: str) -> float | None:
    m = re.search(r"^" + re.escape(series) + r" (\S+)$", text, re.M)
    return float(m.group(1)) if m else None


def _pair(values: list[float | None], as_int: bool) -> str:
    if all(v is None for v in values):
        return "absent"
    return " / ".join("absent" if v is None else (str(int(v)) if as_int else f"{v:g}") for v in values)


@pytest.mark.parametrize(("reports", "expected_utilization", "expected_reset_seconds"), [
    pytest.param(FIRST, "0.2 / 0.64", "1800001000 / 1800008000", id="an accepted report renders both gauges per window"),
    pytest.param("the same, then an older report 99 % / 99 % limited (refused quota-out-of-order)", "0.2 / 0.64", "1800001000 / 1800008000",
                 id="a refused report leaves the gauges unchanged ⚖"),
    pytest.param("none", "absent", "absent", id="a fresh gateway renders no codex series"),
])
async def test_gauges(codex_app, codex_gw, clock, reports, expected_utilization, expected_reset_seconds):
    world("policy-codex")
    row(reports=reports, expected_utilization=expected_utilization, expected_reset_seconds=expected_reset_seconds)
    with given(f"reports {reports} (now = {clock.t:.0f})"):
        if reports != "none":
            observe(codex_app, fresh_report(clock))
        if reports.startswith("the same, then"):
            older = fresh_report(clock, used=(99, 99), limited=True, age=11)
            try:
                codex_app.state.codex.headroom.observe(older)
                refused = "accepted"
            except ReportError as e:
                refused = str(e)
            attach_json("the older report's fate", {"report": older, "outcome": refused})
            assert refused == "quota-out-of-order"
    with when("GET /metrics"):
        with quiet():
            text = (await codex_gw.get("/metrics")).text
        attach_json('sample: gateway_subscription_*{rail="codex"} lines',
                    [line for line in text.splitlines() if line.startswith("gateway_subscription") and 'rail="codex"' in line])
    verdicts(
        utilization=(_pair([_sample(text, CODEX_SERIES[0]), _sample(text, CODEX_SERIES[1])], as_int=False), expected_utilization),
        reset_seconds=(_pair([_sample(text, CODEX_SERIES[2]), _sample(text, CODEX_SERIES[3])], as_int=True), expected_reset_seconds),
    )


@pytest.mark.parametrize(("profile_minutes", "expected_labels"), [
    pytest.param("300, 10080, 1440, 90", "5h, 7d, other", id="the window label is the profile's minutes in the window vocabulary ⚖"),
])
def test_window_label(profile_minutes, expected_labels):
    world("policy-codex")
    row(profile_minutes=profile_minutes, expected_labels=expected_labels)
    minutes = [int(m) for m in profile_minutes.split(", ")]
    m = Metrics(("platform",))
    with when(f"subscription_report codex: windows of profile_minutes {profile_minutes}"):
        m.subscription_report("codex", [Window(0.2 + i / 100, T + 1000 * (i + 1), n) for i, n in enumerate(minutes)])
        labels = re.findall(r'^gateway_subscription_utilization\{rail="codex",window="([^"]+)"\}', m.render(), re.M)
    expect("labels", ", ".join(sorted(set(labels))), expected_labels)
