"""GW-CODEX-HEADROOM §Upstream headers — the relayed answer's `x-codex-*` windows as the second
observation source (specs/endpoints/openai-responses.md), driven through the gateway against the
fake backend of the `policy-codex` world.

Every case starts from a session admitted on a poll report 20 % / 64 % observed at T−10; the backend
then answers the ride's stream with the headers the row names (the pinned CLI's value grammar:
used-percent a float, window-minutes and reset-at integers; a window present iff its used-percent
header is). The ride itself is a plain `upstream-ok` stream — its 200 and bytes never depend on
what the headers say.

| description | the relayed answer's headers | outcome | verdict after |
|---|---|---|---|
| the relayed answer's windows are the second observation | 30 % / 70 %, resets T+900 / T+7000 | accepted | admit — source `upstream`, gauges 0.3 / 0.7 |
| the pinned CLI's value grammar | `12.5` / `0`, minutes `300` / `10080`, epoch resets | accepted | admit — 0.125 / 0 |
| an answer without window headers is absent, the last report stands | none | absent | admit — gauges 0.2 / 0.64 (unchanged) |
| one window's headers alone are refused whole — unknown, never zero | primary only | quota-invalid | admit (unchanged) — the ride still 200 |
| an unreadable value is refused and the ride is unaffected | `lots` / `5h` / `soon` | quota-invalid | admit (unchanged) — the stream completes |
| the reached-type header limits the next admission | 30 % / 70 % + `x-codex-rate-limit-reached-type: primary` | accepted | quota-limited — the next POST /sessions defers `quota-limited` |
| a window at the ceiling in the headers limits until its reset | 96 % / 64 %, 5h resets T+1000 | accepted | quota-limited — defer `retry_after_s` 1000 |
| the two producers replace each other strictly by time | headers at T; a poll report at T, then at T+1 | accepted; quota-out-of-order; accepted | admit |
| only a relayed answer is read | a 429 and a wrong-type 200 carrying the headers | — (not read) | admit (unchanged) |
| an undeclared rail renders no header family; a declared one renders every outcome from 0 | policy-default vs policy-codex /metrics | — | the family absent / 5 series at 0 |
| the counter's label set is the reader's outcome set | — | — | — |
"""

from __future__ import annotations

import pytest

from agent_gateway.codex_headers import OUTCOMES, translate
from agent_gateway.headroom import ReportError, Verdict
from agent_gateway.metrics import HEADROOM_HEADER_OUTCOMES

from ._codex_world import TEXT, admitted, fresh_report, ride
from .conftest import attach_json, given, rule, then, then_eq, when, world

pytestmark = rule("GW-CODEX-HEADROOM")

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


def _counts(text: str) -> dict[str, int]:
    return {line.split('outcome="')[1].split('"')[0]: int(line.rsplit(" ", 1)[1])
            for line in text.splitlines() if line.startswith(FAMILY + "{")}


async def _ride(gw, doc, upstream, headers: dict[str, str], label: str):
    upstream.response_headers = headers
    with given(f"the backend's answer carries {sorted(headers) if headers else 'no x-codex headroom headers'}"):
        attach_json("issued response headers", headers)
    r = await ride(gw, doc, label=label)
    then_eq("ride status", r.status_code, 200)
    assert TEXT in r.text and "response.completed" in r.text, "the stream is relayed whole"
    return r


async def _snapshot(app) -> dict:
    s = app.state.codex.headroom.snapshot
    return {"source": s.source, "limited": s.limited,
            "windows": [{"minutes": w.minutes, "used": w.used, "resets_at": w.resets_at} for w in s.windows]}


async def test_second_observation(codex_app, codex_gw, codex_upstream, clock):
    """row: the relayed answer's windows are the second observation"""
    world("policy-codex")
    doc = await admitted(codex_app, codex_gw, clock)
    await _ride(codex_gw, doc, codex_upstream, windows(clock), "the backend answers with headroom headers")
    text = (await codex_gw.get("/metrics")).text
    with then("the headroom took the headers as a report", snapshot=await _snapshot(codex_app), counter=_counts(text)):
        then_eq("source", codex_app.state.codex.headroom.snapshot.source, "upstream")
        then_eq("verdict", codex_app.state.codex.headroom.verdict(), Verdict.ADMIT)
        then_eq("accepted", _counts(text)["accepted"], 1)
        assert 'gateway_subscription_utilization{rail="codex",window="5h"} 0.3' in text
        assert 'gateway_subscription_utilization{rail="codex",window="7d"} 0.7' in text


async def test_cli_grammar(codex_app, codex_gw, codex_upstream, clock):
    """row: the pinned CLI's value grammar"""
    world("policy-codex")
    doc = await admitted(codex_app, codex_gw, clock)
    await _ride(codex_gw, doc, codex_upstream, windows(clock, used=("12.5", "0")), "a fractional percent and a zero")
    text = (await codex_gw.get("/metrics")).text
    with then("a float percent reads as the CLI reads it", snapshot=await _snapshot(codex_app)):
        then_eq("verdict", codex_app.state.codex.headroom.verdict(), Verdict.ADMIT)
        assert 'gateway_subscription_utilization{rail="codex",window="5h"} 0.125' in text
        assert 'gateway_subscription_utilization{rail="codex",window="7d"} 0' in text


async def test_absent(codex_app, codex_gw, codex_upstream, clock):
    """row: an answer without window headers is absent, the last report stands"""
    world("policy-codex")
    doc = await admitted(codex_app, codex_gw, clock)
    await _ride(codex_gw, doc, codex_upstream, {}, "the backend answers without headroom headers")
    text = (await codex_gw.get("/metrics")).text
    with then("absent is counted, the poll's report stands", snapshot=await _snapshot(codex_app), counter=_counts(text)):
        then_eq("absent", _counts(text)["absent"], 1)
        then_eq("source", codex_app.state.codex.headroom.snapshot.source, "poll")
        assert 'gateway_subscription_utilization{rail="codex",window="5h"} 0.2' in text
        assert 'gateway_subscription_utilization{rail="codex",window="7d"} 0.64' in text


@pytest.mark.parametrize("case", ["one-window", "unreadable"])
async def test_refused(codex_app, codex_gw, codex_upstream, clock, case):
    """row: one window's headers alone are refused whole — unknown, never zero
    row: an unreadable value is refused and the ride is unaffected"""
    world("policy-codex")
    doc = await admitted(codex_app, codex_gw, clock)
    issued = (windows(clock, used=("30", None), minutes=("300", None)) if case == "one-window"
              else {**windows(clock), "x-codex-primary-used-percent": "lots", "x-codex-primary-window-minutes": "5h",
                    "x-codex-secondary-reset-at": "soon"})
    await _ride(codex_gw, doc, codex_upstream, issued, case)
    text = (await codex_gw.get("/metrics")).text
    with then("refused whole, the last accepted report stands", snapshot=await _snapshot(codex_app), counter=_counts(text)):
        then_eq("quota-invalid", _counts(text)["quota-invalid"], 1)
        then_eq("source", codex_app.state.codex.headroom.snapshot.source, "poll")
        then_eq("verdict", codex_app.state.codex.headroom.verdict(), Verdict.ADMIT)


async def test_reached_type_limits(codex_app, codex_gw, codex_upstream, clock):
    """row: the reached-type header limits the next admission"""
    world("policy-codex")
    doc = await admitted(codex_app, codex_gw, clock)
    await _ride(codex_gw, doc, codex_upstream, windows(clock, **{"x-codex-rate-limit-reached-type": "primary"}),
                "the backend says a limit is reached")
    with given("that session released"):
        await codex_gw.delete(f"/sessions/{doc['session']['id']}", headers={"authorization": f"Bearer {doc['session']['token']}"})
    with when("the next codex admission is asked (POST /sessions {role: prober, harness: codex})"):
        nxt = (await codex_gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "t", "harness": "codex"})).json()
    with then("limited by the vendor's flag", snapshot=await _snapshot(codex_app), admission=nxt):
        then_eq("verdict", codex_app.state.codex.headroom.verdict(), Verdict.LIMITED)
        then_eq("decision", nxt["decision"], "defer")
        then_eq("reason", nxt["reason"], "quota-limited")


async def test_ceiling_limits(codex_app, codex_gw, codex_upstream, clock):
    """row: a window at the ceiling in the headers limits until its reset"""
    world("policy-codex")
    doc = await admitted(codex_app, codex_gw, clock)
    await _ride(codex_gw, doc, codex_upstream, windows(clock, used=("96", "64"), resets=(1000, 8000)), "the 5h window at 96 %")
    with given("that session released"):
        await codex_gw.delete(f"/sessions/{doc['session']['id']}", headers={"authorization": f"Bearer {doc['session']['token']}"})
    with when("the next codex admission is asked (POST /sessions {role: prober, harness: codex})"):
        nxt = (await codex_gw.post("/sessions", json={"stack": "platform", "role": "prober", "task": "t", "harness": "codex"})).json()
    with then("deferred until the exhausted window resets", snapshot=await _snapshot(codex_app), admission=nxt):
        then_eq("decision", nxt["decision"], "defer")
        then_eq("reason", nxt["reason"], "quota-limited")
        then_eq("retry_after_s", nxt["retry_after_s"], 1000)


async def test_strictly_by_time(codex_app, codex_gw, codex_upstream, clock):
    """row: the two producers replace each other strictly by time"""
    world("policy-codex")
    doc = await admitted(codex_app, codex_gw, clock)
    await _ride(codex_gw, doc, codex_upstream, windows(clock), "headers observed at T")
    headroom = codex_app.state.codex.headroom
    with when("a poll report observed at the same instant T"):
        try:
            headroom.observe(fresh_report(clock, age=0))
            same = "accepted"
        except ReportError as e:
            same = str(e)
    with when("a poll report observed at T+1"):
        clock.t += 1
        headroom.observe(fresh_report(clock, age=0))
    with then("same instant refused, the newer poll replaces", same_instant=same, snapshot=await _snapshot(codex_app)):
        then_eq("same instant", same, "quota-out-of-order")
        then_eq("source after", headroom.snapshot.source, "poll")
        then_eq("verdict", headroom.verdict(), Verdict.ADMIT)


@pytest.mark.parametrize("behaviour", ["upstream-429", "upstream-wrong-type"])
async def test_only_relayed_is_read(codex_app, codex_gw, codex_upstream, clock, behaviour):
    """row: only a relayed answer is read"""
    world("policy-codex")
    doc = await admitted(codex_app, codex_gw, clock)
    codex_upstream.behaviour = behaviour
    codex_upstream.response_headers = windows(clock, used=("96", "96"))
    with given(f"the backend answers {behaviour} carrying exhausted windows in its headers"):
        pass
    r = await ride(codex_gw, doc, label=behaviour)
    text = (await codex_gw.get("/metrics")).text
    with then("not read: nothing counted, the poll's report stands", status=r.status_code, counter=_counts(text)):
        then_eq("counted", sum(_counts(text).values()), 0)
        then_eq("source", codex_app.state.codex.headroom.snapshot.source, "poll")
        then_eq("verdict", codex_app.state.codex.headroom.verdict(), Verdict.ADMIT)


async def test_family_declared(codex_gw, gw):
    """row: an undeclared rail renders no header family; a declared one renders every outcome from 0"""
    world("policy-default")
    with when("GET /metrics under policy-default and under policy-codex"):
        default = (await gw.get("/metrics")).text
        codex = (await codex_gw.get("/metrics")).text
    then_eq("undeclared", FAMILY in default, False)
    then_eq("declared: every outcome at 0", _counts(codex), {o: 0 for o in OUTCOMES})


def test_label_set():
    """row: the counter's label set is the reader's outcome set"""
    world("policy-codex", note="pure")
    then_eq("outcomes", set(HEADROOM_HEADER_OUTCOMES), set(OUTCOMES))
    with then("translate's grammar is the CLI's"):
        then_eq("absent", translate({}, 1.0), None)
        then_eq("float percent", translate({"x-codex-primary-used-percent": "12.5", "x-codex-primary-window-minutes": "300",
                                            "x-codex-primary-reset-at": "1800000000"}, 1.0)["windows"][0]["used_percent"], 12.5)
        with pytest.raises(ReportError):
            translate({"x-codex-primary-used-percent": "12.5"}, 1.0)
