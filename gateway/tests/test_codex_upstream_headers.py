"""GW-CODEX-UPSTREAM-HEADERS — the relayed answer's `x-codex-*` windows as the second observation source
(specs/endpoints/openai-responses.md §GW-CODEX-UPSTREAM-HEADERS), driven through the gateway against the
fake backend of the `policy-codex` world.

Every case starts from a session admitted on a poll report 20 % / 64 % observed at T−10; the backend
then answers the ride's stream with the headers the row names (the pinned CLI's value grammar:
used-percent a float, window-minutes and reset-at integers; a window present iff its used-percent
header is). The ride itself is a plain `upstream-ok` stream — its 200 and bytes never depend on
what the headers say. Argnames = each table's header, ids = its description cells.
"""

from __future__ import annotations

import pytest

from agent_gateway.codex_headers import OUTCOMES, translate
from agent_gateway.headroom import ReportError
from agent_gateway.metrics import HEADROOM_HEADER_OUTCOMES

from ._codex_rows import expect, row, verdicts
from ._codex_world import TEXT, admitted, fresh_report, ride
from .conftest import attach_json, given, quiet, rule, then, then_eq, when, world

pytestmark = rule("GW-CODEX-UPSTREAM-HEADERS")

FAMILY = "gateway_codex_upstream_headroom_total"


def windows(clock, used=("30", "70"), resets=(900, 7000), minutes=("300", "10080"), **extra) -> dict[str, str]:
    """The header set the live backend issued (names observed 2026-10-22; values synthetic)."""
    h = {}
    for name, u, r, m in zip(("primary", "secondary"), used, resets, minutes, strict=True):
        if u is not None:
            h[f"x-codex-{name}-used-percent"] = u
        if m is not None:
            h[f"x-codex-{name}-window-minutes"] = m
        if r is not None:
            h[f"x-codex-{name}-reset-at"] = str(int(clock.t + r))
    return {**h, **extra}


HEADERS = {  # the `headers` cell → the response headers the backend issues
    "30 % / 70 %, minutes 300 / 10080, resets T+900 / T+7000": lambda c: windows(c),
    "12.5 / 0, integer minutes, epoch resets": lambda c: windows(c, used=("12.5", "0")),
    "none": lambda c: {},
    "the primary set only": lambda c: windows(c, used=("30", None), minutes=("300", None)),
    "lots / 5h / soon": lambda c: {**windows(c), "x-codex-primary-used-percent": "lots", "x-codex-primary-window-minutes": "5h",
                                   "x-codex-secondary-reset-at": "soon"},
    "30 % / 70 % at T; then a poll report at T, then one at T+1": lambda c: windows(c),
    "30 % / 70 % + x-codex-rate-limit-reached-type: primary": lambda c: windows(c, **{"x-codex-rate-limit-reached-type": "primary"}),
    "96 % / 64 %, 5h resets T+1000": lambda c: windows(c, used=("96", "64"), resets=(1000, 8000)),
}


def _counts(text: str) -> dict[str, int]:
    return {line.split('outcome="')[1].split('"')[0]: int(line.rsplit(" ", 1)[1])
            for line in text.splitlines() if line.startswith(FAMILY + "{")}


async def _ride(gw, doc, upstream, headers: dict[str, str], label: str):
    upstream.response_headers = headers
    with given(f"headers {label}: the backend's answer carries {sorted(headers) if headers else 'no x-codex headroom headers'}"):
        attach_json("issued response headers", headers)
    r = await ride(gw, doc, label=f"headers {label}")
    assert r.status_code == 200, f"ride status {r.status_code}: {r.text[:200]}"
    assert TEXT in r.text and "response.completed" in r.text, "the stream is relayed whole"
    return r


def _snapshot(app) -> str:
    s = app.state.codex.headroom.snapshot
    return "none" if s is None else f"source {s.source}; " + " / ".join(f"{w.used:g}" for w in s.windows)


def _outcome(text: str) -> str:
    counted = [o for o, n in _counts(text).items() if n]
    return counted[0] if len(counted) == 1 else ("nothing counted" if not counted else ", ".join(counted))


# -- the headers become a report ------------------------------------------------------------------

@pytest.mark.parametrize(("headers", "expected_outcome", "expected_snapshot"), [
    pytest.param("30 % / 70 %, minutes 300 / 10080, resets T+900 / T+7000", "accepted", "source upstream; 0.3 / 0.7",
                 id="the relayed answer's windows are the second observation"),
    pytest.param("12.5 / 0, integer minutes, epoch resets", "accepted", "source upstream; 0.125 / 0", id="the pinned CLI's value grammar ⚖"),
    pytest.param("none", "absent", "source poll; 0.2 / 0.64", id="an answer without window headers is absent, the last report stands"),
    pytest.param("the primary set only", "quota-invalid", "source poll; 0.2 / 0.64",
                 id="one window's headers alone are refused whole — unknown, never zero ⚖"),
    pytest.param("lots / 5h / soon", "quota-invalid", "source poll; 0.2 / 0.64", id="an unreadable value is refused and the ride is unaffected ⚖"),
    pytest.param("30 % / 70 % at T; then a poll report at T, then one at T+1", "accepted; quota-out-of-order; accepted", "source poll; 0.2 / 0.64",
                 id="the two producers replace each other strictly by time ⚖"),
])
async def test_headers_become_report(codex_app, codex_gw, codex_upstream, clock, headers, expected_outcome, expected_snapshot):
    world("policy-codex")
    row(headers=headers, expected_outcome=expected_outcome, expected_snapshot=expected_snapshot)
    doc = await admitted(codex_app, codex_gw, clock)
    await _ride(codex_gw, doc, codex_upstream, HEADERS[headers](clock), headers)
    with quiet():
        text = (await codex_gw.get("/metrics")).text
    outcome = _outcome(text)
    if headers.endswith("then one at T+1"):
        headroom = codex_app.state.codex.headroom
        with then("a poll report observed at the same instant T, then one at T+1 (observed at the seam)"):
            try:
                headroom.observe(fresh_report(clock, age=0))
                same = "accepted"
            except ReportError as e:
                same = str(e)
            clock.t += 1
            headroom.observe(fresh_report(clock, age=0))
        outcome = f"{outcome}; {same}; accepted"
    verdicts(
        outcome=(outcome, expected_outcome),
        snapshot=(_snapshot(codex_app), expected_snapshot),
    )
    then_eq("verdict", str(codex_app.state.codex.headroom.verdict()), "admit")
    if headers.startswith("30 % / 70 %, minutes"):
        with then("the gauges follow the accepted report: utilization 5h 0.3, 7d 0.7"):
            assert 'gateway_subscription_utilization{rail="codex",window="5h"} 0.3' in text
            assert 'gateway_subscription_utilization{rail="codex",window="7d"} 0.7' in text
    if headers == "none":
        with then("the gauges keep the poll's report: 0.2 / 0.64"):
            assert 'gateway_subscription_utilization{rail="codex",window="5h"} 0.2' in text
            assert 'gateway_subscription_utilization{rail="codex",window="7d"} 0.64' in text


# -- the report gates the next admission ----------------------------------------------------------

@pytest.mark.parametrize(("headers", "expected_verdict", "expected_next_admission"), [
    pytest.param("30 % / 70 % + x-codex-rate-limit-reached-type: primary", "quota-limited", "defer quota-limited, retry_after_s 60",
                 id="the reached-type header limits the next admission"),
    pytest.param("96 % / 64 %, 5h resets T+1000", "quota-limited", "defer quota-limited, retry_after_s 1000",
                 id="a window at the ceiling in the headers limits until its reset"),
])
async def test_report_gates_next_admission(codex_app, codex_gw, codex_upstream, clock, headers, expected_verdict, expected_next_admission):
    world("policy-codex")
    row(headers=headers, expected_verdict=expected_verdict, expected_next_admission=expected_next_admission)
    doc = await admitted(codex_app, codex_gw, clock)
    await _ride(codex_gw, doc, codex_upstream, HEADERS[headers](clock), headers)
    with given("that session released, so the next admission is the headroom's call"):
        with quiet():
            await codex_gw.delete(f"/sessions/{doc['session']['id']}", headers={"authorization": f"Bearer {doc['session']['token']}"})
    with when("the next codex admission is asked (POST /sessions {role: prober, harness: codex})"):
        nxt = (await codex_gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "t", "harness": "codex"})).json()
    verdicts(
        verdict=(str(codex_app.state.codex.headroom.verdict()), expected_verdict),
        next_admission=(f"{nxt['decision']} {nxt.get('reason')}, retry_after_s {nxt.get('retry_after_s')}", expected_next_admission),
    )


# -- what is read, and the counter ----------------------------------------------------------------

@pytest.mark.parametrize(("arranged", "expected_counter"), [
    pytest.param("upstream-429 carrying exhausted windows", "nothing counted; the poll's report stands", id="a 429's headers are not read ⚖"),
    pytest.param("upstream-wrong-type carrying exhausted windows", "nothing counted; the poll's report stands", id="a wrong-type 200's headers are not read ⚖"),
    pytest.param("GET /metrics under policy-default / policy-codex", "no series / the 5 outcomes, each 0",
                 id="an undeclared rail renders no header family; a declared one renders every outcome from 0 ⚖"),
    pytest.param("—", "outcome values = the reader's outcomes", id="the counter's label set is the reader's outcome set"),
])
async def test_read_and_counter(codex_app, codex_gw, codex_upstream, gw, clock, arranged, expected_counter):
    world("policy-default" if "policy-default" in arranged else "policy-codex", note="pure" if arranged == "—" else None)
    row(arranged=arranged, expected_counter=expected_counter)
    if arranged.startswith("upstream-"):
        behaviour = arranged.split(" ", 1)[0]
        doc = await admitted(codex_app, codex_gw, clock)
        codex_upstream.behaviour = behaviour
        codex_upstream.response_headers = windows(clock, used=("96", "96"))
        with given(f"arranged {arranged}: the backend answers {behaviour} with exhausted windows in its headers"):
            pass
        r = await ride(codex_gw, doc, label=behaviour)
        with quiet():
            text = (await codex_gw.get("/metrics")).text
        headroom = codex_app.state.codex.headroom
        counter = (("nothing counted" if sum(_counts(text).values()) == 0 else f"counted {_counts(text)}")
                   + ("; the poll's report stands" if headroom.snapshot.source == "poll" and str(headroom.verdict()) == "admit" else f"; {_snapshot(codex_app)}"))
        then_eq("the ride's status", r.status_code, 429 if behaviour == "upstream-429" else 502)
    elif arranged.startswith("GET /metrics"):
        with when(f"arranged {arranged}"):
            default = (await gw.get("/metrics")).text
            codex = (await codex_gw.get("/metrics")).text
        counter = (("no series" if FAMILY not in default else "series present") + " / "
                   + (f"the {len(OUTCOMES)} outcomes, each 0" if _counts(codex) == {o: 0 for o in OUTCOMES} else f"{_counts(codex)}"))
    else:
        with when("compare metrics.HEADROOM_HEADER_OUTCOMES with codex_headers.OUTCOMES; translate's grammar is the CLI's"):
            same = set(HEADROOM_HEADER_OUTCOMES) == set(OUTCOMES)
            assert translate({}, 1.0) is None, "absent"
            assert translate({"x-codex-primary-used-percent": "12.5", "x-codex-primary-window-minutes": "300",
                              "x-codex-primary-reset-at": "1800000000"}, 1.0)["windows"][0]["used_percent"] == 12.5
            with pytest.raises(ReportError):
                translate({"x-codex-primary-used-percent": "12.5"}, 1.0)
        counter = "outcome values = the reader's outcomes" if same else f"{HEADROOM_HEADER_OUTCOMES} ≠ {OUTCOMES}"
    expect("counter", counter, expected_counter)
