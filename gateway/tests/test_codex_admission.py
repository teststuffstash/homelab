"""GW-CODEX-ADMISSION — the headroom verdict composed into the POST /sessions walk
(specs/endpoints/openai-responses.md §GW-CODEX-ADMISSION: the verdict in the walk, the gate's place in
the walk). World `policy-codex`: defer_retry_s 60 (the loader's default — policy-codex sets none),
max_sessions 2; fresh_report's windows reset at now+1000 / now+8000. Argnames = each table's header,
ids = its description cells. Split out of test_codex_headroom.py (the snapshot) — the reading and the
admission are two questions.
"""

from __future__ import annotations

import pytest

from agent_gateway.headroom import Verdict

from ._codex_rows import expect, row, verdicts
from ._codex_world import admitted, codex_session, fresh_report, observe, ride
from .conftest import attach_json, given, quiet, rule, then, when, world

pytestmark = rule("GW-CODEX-ADMISSION")

POST = {"stack": "platform", "role": "prober", "task": "t", "harness": "codex"}


def _observe(app, clock, headroom: str) -> None:
    """The `headroom` cell → the observation (none; `5h % / 7d %`[, limited][, asked at T+N])."""
    if headroom == "none":
        with given("headroom none (no observation)"):
            pass
        return
    used = tuple(int(p.strip(" %")) for p in headroom.split(",")[0].split(" / "))
    observe(app, fresh_report(clock, used=used, limited=", limited" in headroom))
    if "asked at T+" in headroom:
        advance = int(headroom.rsplit("T+", 1)[1])
        with given(f"the clock advances {advance} s (the report is now {advance + 10} s old, max_age_s 120)"):
            clock.advance(advance)


@pytest.mark.parametrize(("headroom", "expected_decision", "expected_reason", "expected_retry_after_s"), [
    pytest.param("20 % / 64 %", "dispatch", "—", "—", id="fresh headroom admits the codex harness"),
    pytest.param("none", "defer", "quota-unknown", 60, id="no observation defers unknown"),
    pytest.param("20 % / 64 %, asked at T+115", "defer", "quota-stale", 60, id="a stale observation defers stale"),
    pytest.param("96 % / 64 %", "defer", "quota-limited", 1000, id="an exhausted window defers until its reset ⚖"),
    pytest.param("96 % / 97 %", "defer", "quota-limited", 8000, id="two exhausted windows wait for the later reset ⚖"),
    pytest.param("20 % / 64 %, limited", "defer", "quota-limited", 60, id="the explicit flag alone defers by the policy interval ⚖"),
])
async def test_verdict_in_the_walk(codex_app, codex_gw, clock, headroom, expected_decision, expected_reason, expected_retry_after_s):
    world("policy-codex")
    row(headroom=headroom, expected_decision=expected_decision, expected_reason=expected_reason, expected_retry_after_s=expected_retry_after_s)
    _observe(codex_app, clock, headroom)
    with when(f"POST /sessions {{role: prober, harness: codex}} on headroom {headroom}"):
        r = await codex_gw.post("/sessions", json=POST)
    doc = r.json()
    verdicts(
        decision=(doc.get("decision"), expected_decision),
        reason=(doc.get("reason", "—"), expected_reason),
        retry_after_s=(doc.get("retry_after_s", "—"), expected_retry_after_s),
    )
    if expected_decision == "dispatch":
        with then("the dispatched rail is codex", rail={"expected": "codex", "actual": doc.get("rail")}):
            assert doc.get("rail") == "codex"


@pytest.mark.parametrize(("headroom", "arranged", "expected_answer"), [
    pytest.param("none", "the store's lock raises", "defer quota-unknown; store reads 0", id="headroom is read before the credential store ⚖"),
    pytest.param("20 % / 64 %", "2 codex sessions active (max_sessions 2)", "defer rail-capacity, retry_after_s 60", id="the rail's session cap still applies"),
    pytest.param("20 % / 64 %, then 99 % / 99 % limited", "a session dispatched before the limited report", "the ride 200, one upstream call",
                 id="an admitted session is not re-gated on the data plane ⚖"),
])
async def test_gates_place(codex_app, codex_gw, codex_store, codex_upstream, clock, headroom, arranged, expected_answer):
    world("policy-codex", "upstream-ok" if arranged.startswith("a session dispatched") else None)
    row(headroom=headroom, arranged=arranged, expected_answer=expected_answer)
    if arranged.startswith("the store's lock"):
        def broken():
            raise RuntimeError("DUMMY-SECRET store down")
        with given(f"headroom {headroom}; arranged {arranged}"):
            codex_store.lock = broken
        with when("POST /sessions {role: prober, harness: codex}"):
            r = await codex_gw.post("/sessions", json=POST)
        answer = f"{r.json()['decision']} {r.json().get('reason')}; store reads {codex_store.loads}"
    elif arranged.startswith("2 codex sessions"):
        _observe(codex_app, clock, headroom)
        with given(f"arranged {arranged}"):
            with quiet():
                for i in range(2):
                    await codex_session(codex_gw, round=i)
            attach_json("filled", {"codex": 2})
        with when("POST /sessions {role: prober, harness: codex}"):
            r = await codex_gw.post("/sessions", json=POST)
        answer = f"{r.json()['decision']} {r.json().get('reason')}, retry_after_s {r.json().get('retry_after_s')}"
    else:
        doc = await admitted(codex_app, codex_gw, clock)
        with given(f"headroom {headroom}: arranged {arranged}, then the limited report"):
            observe(codex_app, fresh_report(clock, used=(99, 99), limited=True, age=5))
        r = await ride(codex_gw, doc)
        calls = len(codex_upstream.calls)
        answer = f"the ride {r.status_code}, {'one' if calls == 1 else calls} upstream call"
        with then("the headroom verdict is now quota-limited (the session was not re-gated)", verdict={"actual": str(codex_app.state.codex.headroom.verdict())}):
            assert codex_app.state.codex.headroom.verdict() == Verdict.LIMITED
    expect("answer", answer, expected_answer)
