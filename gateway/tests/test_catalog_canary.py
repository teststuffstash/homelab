"""GW-CATALOG-OR-CANARY — the entry canary: what a ride pins, when a cell is due, the verdict, the
429 backoff, the budget and spend caps, the counters, the launcher (specs/endpoints/catalog.md §The
OpenRouter catalog; homelab#2742, #2775).

World `policy-default · openrouter-catalog` after one good refresh at T0 (M = deepseek/deepseek-v4.1-flash
and G = z-ai/glm-5.3-flash, 15 candidate cells); the policy's canary block: max_per_refresh 3,
usd_per_day 1.0, cooldown_s 86400, backoff_s 3600, backoff_max_s 14400. A canary = POST /sessions
{role: prober, canary: {M, <provider>}}. The tables are the spec's, verbatim (the header is the
parameter list).
"""

from __future__ import annotations

import os
import re
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from agent_gateway.store import iso

from ._catalog_rows import (
    CHAT,
    OR_RAIL,
    THROTTLED,
    G,
    M,
    SecondGateway,
    at_offset,
    canary_body,
    canary_ride,
    horizon,
    joined,
    num,
    or_refreshed,
    or_series,
    or_series_many,
    or_view,
    verdict,
)
from .conftest import attach_json, bearer, given, quiet, rule, when, world

pytestmark = rule("GW-CATALOG-OR-CANARY")
WORLD = "openrouter-catalog"
LAUNCHER = Path(__file__).resolve().parents[1] / "scripts" / "canary-entrants.sh"
T0 = 1_800_000_000


def _at(cell: str) -> str:
    return f"T0 + {num(cell)} s" if isinstance(cell, int | float) else cell


def _time_cell(ts: float | None) -> str:
    return "none" if ts is None else "T0" if ts == T0 else f"T0 + {num(ts - T0)} s"


async def _canary(gw, provider: str = "deepinfra", model: str = M, label: str = "", **extra):
    body = canary_body(model, provider, **extra)
    with when(f"POST /sessions {body}{label}"):
        return await gw.post("/sessions", json=body)


def _answer(r) -> dict:
    doc = r.json()
    if r.status_code != 200:
        return {"decision": str(r.status_code), "reason": doc.get("error", {}).get("code"), "retry_after_s": None}
    return {"decision": doc.get("decision"), "reason": doc.get("reason"), "retry_after_s": doc.get("retry_after_s")}


def _counted(series: dict[str, float | None]) -> str:
    return ", ".join(f"{k} {num(v)}" for k, v in series.items() if v) or "none"


async def _rides_total(gw) -> dict[str, float | None]:
    names = {o: f'gateway_canary_rides_total{{outcome="{o}"}}' for o in ("no-verdict", "eligible", "excluded")}
    got = await or_series_many(gw, list(names.values()))
    return {o: got[n] for o, n in names.items()}


# ── What a session's ride pins ────────────────────────────────────────────────────────────────
PIN_ROWS = [
    pytest.param("worker, tier heavy (M)", "candidate", "none", "none", id="a new cell is a candidate: selection does not pin it ⚖"),
    pytest.param("prober, canary {M, deepinfra}", "candidate", "order deepinfra, allow_fallbacks false", "deepinfra",
                 id="a canary session is admitted on a candidate cell, pinned to it ⚖"),
    pytest.param("worker, tier heavy (M)", "eligible (a clean canary)", "order deepinfra, allow_fallbacks false", "none",
                 id="a clean canary makes the cell eligible: selection pins it"),
]


@pytest.mark.parametrize(("session", "cell_before", "expected_pin", "expected_canary_provider"), PIN_ROWS, ids=[p.id for p in PIN_ROWS])
async def test_what_a_ride_pins(gw, app, store, upstreams, session, cell_before, expected_pin, expected_canary_provider):
    world(upstream="upstream-ok", note=WORLD)
    with given(f"a first good refresh; cell_before = {cell_before}"):
        await or_refreshed(app)
        if cell_before.startswith("eligible"):
            await canary_ride(gw, upstreams)
    with given(f"session = {session}"):
        if session.startswith("prober"):
            with quiet():
                r = await gw.post("/sessions", json=canary_body(M, "deepinfra"))
        else:
            with quiet():
                r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "harness": "opencode", "task": "homelab-2742-pin",
                                                     "rail": OR_RAIL, "tier": "heavy"})
        doc = r.json()
        attach_json("the admission", {k: doc.get(k) for k in ("decision", "rail", "model", "harness")})
        assert doc["decision"] == "dispatch", doc
    with when(f"POST {CHAT} on the session (model M)"):
        rr = await gw.post(CHAT, json={"model": M, "messages": []}, headers=bearer(doc))
    prov = (upstreams[OR_RAIL].calls[-1]["body"] or {}).get("provider")
    pin = "none" if prov is None else f"order {', '.join(prov.get('order', []))}" + (", allow_fallbacks false" if prov.get("allow_fallbacks") is False else "")
    verdict(f"pin = {expected_pin} · canary_provider = {expected_canary_provider}",
            expected_pin={"expected": expected_pin, "actual": pin},
            expected_canary_provider={"expected": expected_canary_provider, "actual": store.get_session(doc["session"]["id"]).canary_provider or "none"},
            status={"expected": 200, "actual": rr.status_code},
            admission={"expected": {"decision": "dispatch", "rail": OR_RAIL, "model": M, "harness": "opencode"},
                       "actual": {k: doc.get(k) for k in ("decision", "rail", "model", "harness")}},
            session={"actual": session}, cell_before={"actual": cell_before})


# ── Admitting a canary ────────────────────────────────────────────────────────────────────────
ADMIT_ROWS = [
    pytest.param("worker", "{M, deepinfra}", "400", "malformed-body", "none", id="the canary role is the policy's ⚖"),
    pytest.param("prober", "{M, fireworks}", "defer", "not-in-catalog", 21600, id="a canary on a cell the snapshot lacks"),
    pytest.param("prober", "{moonshotai/kimi-k3, deepinfra}", "defer", "not-in-catalog", 21600, id="a canary names a model the snapshot lacks"),
]


@pytest.mark.parametrize(("role", "canary", "expected_decision", "expected_reason", "expected_retry_after_s"), ADMIT_ROWS, ids=[p.id for p in ADMIT_ROWS])
async def test_admitting_a_canary(gw, app, role, canary, expected_decision, expected_reason, expected_retry_after_s):
    world(note=WORLD)
    with given(f"a first good refresh; role = {role} · canary = {canary}"):
        await or_refreshed(app)
    model, provider = canary.strip("{}").split(", ")
    model = M if model == "M" else model
    r = await _canary(gw, provider, model, role=role)
    got = _answer(r)
    verdict(f"decision = {expected_decision} · reason = {expected_reason} · retry_after_s = {expected_retry_after_s}",
            expected_decision={"expected": expected_decision, "actual": got["decision"]},
            expected_reason={"expected": expected_reason, "actual": got["reason"] or "none"},
            expected_retry_after_s={"expected": expected_retry_after_s, "actual": got["retry_after_s"] or "none"},
            role={"actual": role}, canary={"actual": canary})


# ── Is the cell due ───────────────────────────────────────────────────────────────────────────
ELIGIBLE, EXCLUDED, BACKED_OFF = "eligible (a clean canary at T0)", "excluded (a struck canary at T0)", "backed off (a 429'd canary at T0)"
DUE_ROWS = [
    pytest.param(ELIGIBLE, "T0", "defer", "canary-not-due", 21600, id="a canary on an eligible cell is not due ⚖"),
    pytest.param(EXCLUDED, "T0 + 3600 s", "defer", "canary-not-due", 82800, id="a canary on an excluded cell inside its cooldown is not due"),
    pytest.param(EXCLUDED, "T0 + 86400 s", "dispatch", "none", "none", id="an excluded cell is a candidate again after the cooldown ⚖"),
    pytest.param(BACKED_OFF, "T0", "defer", "canary-not-due", 3600, id="a backed-off cell is not due until its horizon ⚖"),
    pytest.param(BACKED_OFF, "T0 + 3600 s", "dispatch", "none", "none", id="at the horizon the cell is due again"),
]


@pytest.mark.parametrize(("cell_before", "at", "expected_decision", "expected_reason", "expected_retry_after_s"), DUE_ROWS, ids=[p.id for p in DUE_ROWS])
async def test_is_the_cell_due(gw, app, store, upstreams, clock, cell_before, at, expected_decision, expected_reason, expected_retry_after_s):
    world(upstream="upstream-500" if cell_before == EXCLUDED else THROTTLED if cell_before == BACKED_OFF else "upstream-ok", note=WORLD)
    with given(f"a first good refresh; cell_before = {cell_before}"):
        await or_refreshed(app)
        if cell_before == ELIGIBLE:
            await canary_ride(gw, upstreams)
        elif cell_before == EXCLUDED:
            await canary_ride(gw, upstreams, behaviour="upstream-500", outcome=None)
        else:
            await canary_ride(gw, upstreams, behaviour=THROTTLED, outcome=None)
        attach_json("(M, deepinfra) before", horizon(store))
    clock.advance(at_offset(at))
    r = await _canary(gw, "deepinfra", label=f" at = {at}")
    got = _answer(r)
    verdict(f"decision = {expected_decision} · reason = {expected_reason} · retry_after_s = {expected_retry_after_s}",
            expected_decision={"expected": expected_decision, "actual": got["decision"]},
            expected_reason={"expected": expected_reason, "actual": got["reason"] or "none"},
            expected_retry_after_s={"expected": expected_retry_after_s, "actual": got["retry_after_s"] or "none"},
            cell_before={"actual": cell_before}, at={"actual": at})


# ── A struck canary ───────────────────────────────────────────────────────────────────────────
STRUCK_ROWS = [
    pytest.param("deepinfra answers 500", 500, "deepinfra", "excluded", "provider-5xx", "T0 + 86400 s", "candidate",
                 id="a struck canary never fails over and excludes exactly its cell ⚖"),
]


@pytest.mark.parametrize(("ride", "expected_status", "expected_upstream_pins", "expected_state", "expected_class", "expected_cooldown_until",
                          "expected_other_cell"), STRUCK_ROWS, ids=[p.id for p in STRUCK_ROWS])
async def test_a_struck_canary(gw, app, store, upstreams, ride, expected_status, expected_upstream_pins, expected_state, expected_class,
                               expected_cooldown_until, expected_other_cell):
    world(upstream="upstream-500", note=f"{WORLD}; deepinfra answers 500 to the canary")
    with given(f"a first good refresh; a canary session on (M, deepinfra); ride = {ride}"):
        await or_refreshed(app)
        with quiet():
            doc = (await gw.post("/sessions", json=canary_body(M, "deepinfra"))).json()
        assert doc["decision"] == "dispatch", doc
        upstreams[OR_RAIL].provider_behaviours["deepinfra"] = "upstream-500"
    with when(f"the canary's ride: POST {CHAT} (no consumer outcome follows)"):
        r = await gw.post(CHAT, json={"model": M, "messages": []}, headers=bearer(doc))
    row = horizon(store)
    pins = [((c["body"] or {}).get("provider") or {}).get("order", [None])[0] for c in upstreams[OR_RAIL].calls if c["path"] == "/v1/chat/completions"]
    verdict(f"status = {expected_status} · upstream_pins = {expected_upstream_pins} · state = {expected_state} · class = {expected_class} · "
            f"cooldown_until = {expected_cooldown_until} · other_cell = {expected_other_cell}",
            expected_status={"expected": expected_status, "actual": r.status_code},
            expected_upstream_pins={"expected": expected_upstream_pins, "actual": joined([p or "none" for p in pins])},
            expected_state={"expected": expected_state, "actual": row["state"]},
            expected_class={"expected": expected_class, "actual": row["class"]},
            expected_cooldown_until={"expected": expected_cooldown_until, "actual": _time_cell(row["cooldown_until"])},
            expected_other_cell={"expected": expected_other_cell, "actual": store.cell_get(M, "atlas-cloud")["state"]},
            ride={"actual": ride})


# ── A 429'd canary is no verdict ──────────────────────────────────────────────────────────────
UPS = "upstream_provider_shared_pool"
BACKOFF_ROWS = [
    pytest.param("a 429'd canary at T0", "candidate", "T0 + 3600 s", "3600", UPS, "no-verdict 1", "none", 0,
                 id="a 429'd canary is no verdict: the cell backs off ⚖"),
    pytest.param("a struck canary at T0; a 429'd canary at T0 + 86400 s", "candidate", "T0 + 90000 s", "3600", UPS, "no-verdict 1, excluded 1", "none", 1,
                 id="a cell back from exclusion backs off the same way"),
    pytest.param("four 429'd canaries, each at the previous horizon", "candidate", "T0 + 39600 s", "3600, 7200, 14400, 14400", UPS, "no-verdict 4", "none", 0,
                 id="a consecutive 429'd canary doubles the horizon; the policy caps it ⚖"),
    pytest.param("two 429'd canaries at their horizons, then a clean canary", "eligible", "none", "3600, 7200, none", "none", "no-verdict 2, eligible 1", "none", 1,
                 id="a verdict resets the backoff ⚖"),
    pytest.param("a 429'd canary at T0, then its consumer reports harness-gave-up", "candidate", "T0 + 3600 s", "3600", UPS, "no-verdict 1", "harness-gave-up, scope cell", 0,
                 id="a strike on a ride that saw a 429 is not the cell's verdict ⚖"),
    pytest.param("a 429'd canary at T0; the same session then 200, outcome clean", "eligible", "none", "3600, none", "none", "no-verdict 1, eligible 1", "none", 1,
                 id="a clean finish after a 429 on the same ride: the cell enters"),
]


@pytest.mark.parametrize(("rides", "expected_state", "expected_retry_at", "expected_backoff_s", "expected_limit_source", "expected_counted",
                          "expected_strike", "expected_admitted"), BACKOFF_ROWS, ids=[p.id for p in BACKOFF_ROWS])
async def test_429_is_no_verdict(gw, app, store, upstreams, clock, rides, expected_state, expected_retry_at, expected_backoff_s, expected_limit_source,
                                 expected_counted, expected_strike, expected_admitted):
    world(upstream=THROTTLED, note=f"{WORLD}; deepinfra answers OpenRouter's shared-pool 429 to the canary")
    steps: list[str] = []
    strike = "none"

    def note_backoff() -> None:
        b = horizon(store)["backoff_s"]
        steps.append("none" if b is None else num(b))

    with given(f"a first good refresh; rides = {rides}"):
        await or_refreshed(app)
    with when(f"the canary rides on (M, deepinfra): {rides}"):
        if rides == "a 429'd canary at T0":
            await canary_ride(gw, upstreams, behaviour=THROTTLED, outcome=None)
            note_backoff()
        elif rides.startswith("a struck canary at T0;"):
            await canary_ride(gw, upstreams, behaviour="upstream-500", outcome=None)
            clock.advance(86400)
            await canary_ride(gw, upstreams, behaviour=THROTTLED, outcome=None)
            note_backoff()
        elif rides.startswith("four 429'd canaries"):
            for _ in range(4):
                await canary_ride(gw, upstreams, behaviour=THROTTLED, outcome=None)
                note_backoff()
                clock.advance(horizon(store)["backoff_s"])
            clock.t -= horizon(store)["backoff_s"]  # the row reads the cell at the fourth ride's time
        elif rides.startswith("two 429'd canaries"):
            for _ in range(2):
                await canary_ride(gw, upstreams, behaviour=THROTTLED, outcome=None)
                note_backoff()
                clock.advance(horizon(store)["backoff_s"])
            await canary_ride(gw, upstreams, behaviour="upstream-ok", outcome="clean")
            note_backoff()
        elif rides.endswith("reports harness-gave-up"):
            doc = await canary_ride(gw, upstreams, behaviour=THROTTLED, outcome=None)
            note_backoff()
            with quiet():
                ro = await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": "harness-gave-up"})
            attach_json("the outcome answer", ro.json())
            s = ro.json().get("strike")
            strike = f"{s['class']}, scope {s['scope']}" if s else "none"
        else:  # a 429'd canary; the same session then 200, outcome clean
            doc = await canary_ride(gw, upstreams, behaviour=THROTTLED, outcome=None)
            note_backoff()
            with quiet():
                rr = await gw.post(CHAT, json={"model": M, "messages": []}, headers=bearer(doc))
                assert rr.status_code == 200, rr.text
                await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": "clean"})
            note_backoff()
        row = horizon(store)
        attach_json("(M, deepinfra) after", row)
    with quiet():  # one view read, one metrics read (ATTACH_BULK: ≤ 8 attachments per case)
        view = await or_view(gw)
    view_row = next(e for e in view["models"][M]["endpoints"] if e["tag"] == "deepinfra/fp8")
    counted = _counted(await _rides_total(gw))
    verdict(f"state = {expected_state} · retry_at = {expected_retry_at} · backoff_s = {expected_backoff_s} · limit_source = {expected_limit_source} · "
            f"counted = {expected_counted} · strike = {expected_strike} · admitted = {expected_admitted}",
            expected_state={"expected": expected_state, "actual": row["state"]},
            expected_retry_at={"expected": expected_retry_at, "actual": _time_cell(row["retry_at"])},
            expected_backoff_s={"expected": expected_backoff_s, "actual": ", ".join(steps)},
            expected_limit_source={"expected": expected_limit_source, "actual": row["limit_source"] or "none"},
            expected_counted={"expected": expected_counted, "actual": counted},
            expected_strike={"expected": expected_strike, "actual": strike},
            expected_admitted={"expected": expected_admitted, "actual": view["canary"]["admitted_this_refresh"]},
            the_view_reads_the_same={"expected": (row["state"], None if row["retry_at"] is None else iso(row["retry_at"]), row["backoff_s"]),
                                     "actual": (view_row["state"], view_row["retry_at"], view_row["backoff_s"])},
            rides={"actual": rides})


# ── The budget cap ────────────────────────────────────────────────────────────────────────────
BUDGET_ROWS = [
    pytest.param("2", "—", "dispatch", "none", "none", 3, 1, id="under budget: N entrants are canaried"),
    pytest.param("3", "—", "defer", "canary-budget", 3600, 3, 1, id="at the cap the N+1th waits ⚖"),
    pytest.param("3", "a refresh", "dispatch", "none", "none", 1, 0, id="a refresh opens the next N ⚖"),
    pytest.param("3, the first 429'd", "—", "dispatch", "none", "none", 3, 1, id="a 429'd canary consumes no admission ⚖"),
    pytest.param("3", "a pod roll +3600 s", "defer", "canary-budget", 3600, 3, 1, id="a pod roll inside the window keeps the count ⚖"),
    pytest.param("3", "a pod roll +21600 s, its refresh at start", "dispatch", "none", "none", 1, 0,
                 id="a pod roll after the interval refreshes and opens the next N"),
]
PROVIDERS = ("deepinfra", "atlas-cloud", "morph")


@pytest.mark.parametrize(("canaries_before", "then", "expected_decision", "expected_reason", "expected_retry_after_s", "expected_admitted",
                          "expected_exhausted"), BUDGET_ROWS, ids=[p.id for p in BUDGET_ROWS])
async def test_budget_cap(gw, app, upstreams, clock, settings, policy, secrets, mcp_transport, reviews, pods, canaries_before, then, expected_decision,
                          expected_reason, expected_retry_after_s, expected_admitted, expected_exhausted):
    world(upstream=THROTTLED if "429" in canaries_before else "upstream-ok", note=f"{WORLD}; max_per_refresh 3" + (f"; {then}" if then != "—" else ""))
    with given(f"a first good refresh; canaries_before = {canaries_before}"):
        await or_refreshed(app)
        n = int(canaries_before[0])
        with quiet():
            for i, p in enumerate(PROVIDERS[:n]):
                if i == 0 and "429" in canaries_before:
                    await canary_ride(gw, upstreams, p, behaviour=THROTTLED, outcome=None)
                elif "429" in canaries_before:
                    await canary_ride(gw, upstreams, p)
                else:
                    assert (await gw.post("/sessions", json=canary_body(M, p))).json()["decision"] == "dispatch"
        attach_json("arranged canaries", {"providers": PROVIDERS[:n], "admitted_this_refresh": (await or_view(gw))["canary"]["admitted_this_refresh"]})
    reader, second = gw, None
    with given(f"then = {then}"):
        if then == "a refresh":
            clock.advance(1)
            await or_refreshed(app)
        elif then.startswith("a pod roll"):
            clock.advance(float(then.split("+")[1].split(" ")[0]))
            second = SecondGateway(settings, policy, secrets, mcp_transport, reviews, pods, clock)
            reader = second.gw
            if "its refresh at start" in then:
                assert second.or_delay == 0.0
                with quiet():
                    assert await second.app.state.orcatalog.refresh() == "ok"
    r = await _canary(reader, "inference-net", label=" (the next canary, another cell)")
    got = _answer(r)
    admitted = (await or_view(reader))["canary"]["admitted_this_refresh"]
    exhausted = await or_series(reader, "gateway_canary_budget_exhausted")
    if second is not None:
        await second.close()
    verdict(f"decision = {expected_decision} · reason = {expected_reason} · retry_after_s = {expected_retry_after_s} · admitted = {expected_admitted} · "
            f"exhausted = {expected_exhausted}",
            expected_decision={"expected": expected_decision, "actual": got["decision"]},
            expected_reason={"expected": expected_reason, "actual": got["reason"] or "none"},
            expected_retry_after_s={"expected": expected_retry_after_s, "actual": got["retry_after_s"] or "none"},
            expected_admitted={"expected": expected_admitted, "actual": admitted},
            expected_exhausted={"expected": expected_exhausted, "actual": exhausted},
            canaries_before={"actual": canaries_before}, then={"actual": then})


# ── The spend cap ─────────────────────────────────────────────────────────────────────────────
SPEND_ROWS = [
    pytest.param("in 5M, out 1M", "T0", "defer", "canary-budget", 3600, "1.12", 1, id="the day's spend at the cap defers ⚖"),
    pytest.param("in 5M, out 1M", "T0 + 86400 s", "dispatch", "none", "none", "0", 0, id="the day rolls over"),
    pytest.param("in 1M, out 1M", "T0", "dispatch", "none", "none", "0.56", 0, id="spend is metered at the cell's endpoint price ⚖"),
]


@pytest.mark.parametrize(("usage", "at", "expected_decision", "expected_reason", "expected_retry_after_s", "expected_spend_usd", "expected_exhausted"),
                         SPEND_ROWS, ids=[p.id for p in SPEND_ROWS])
async def test_spend_cap(gw, app, upstreams, clock, usage, at, expected_decision, expected_reason, expected_retry_after_s, expected_spend_usd,
                         expected_exhausted):
    world(upstream="upstream-ok-usage", note=f"{WORLD}; usd_per_day 1.0")
    m = re.match(r"in (\d+)M, out (\d+)M", usage)
    tokens = {"input_tokens": int(m.group(1)) * 1_000_000, "output_tokens": int(m.group(2)) * 1_000_000}
    with given(f"a first good refresh; one canary ride on (M, deepinfra) with the claude harness metered usage = {usage} (deepinfra 0.14 / 0.42 $/M)"):
        await or_refreshed(app)
        with quiet():
            doc = (await gw.post("/sessions", json=canary_body(M, "deepinfra", harness="claude"))).json()
            assert doc["decision"] == "dispatch", doc
            upstreams[OR_RAIL].behaviour, upstreams[OR_RAIL].usage = "upstream-ok-usage", tokens
            rr = await gw.post("/anthropic/v1/messages", json={"model": M, "max_tokens": 8, "messages": []}, headers={"x-api-key": doc["session"]["token"]})
            upstreams[OR_RAIL].behaviour, upstreams[OR_RAIL].usage = "upstream-ok", None
        attach_json("the metered canary ride", {"status": rr.status_code, "usage": tokens})
    clock.advance(at_offset(at))
    r = await _canary(gw, "atlas-cloud", label=f" at = {at}")
    got = _answer(r)
    spend = await or_series(gw, "gateway_canary_spend_usd")
    verdict(f"decision = {expected_decision} · reason = {expected_reason} · retry_after_s = {expected_retry_after_s} · spend_usd = {expected_spend_usd} · "
            f"exhausted = {expected_exhausted}",
            expected_decision={"expected": expected_decision, "actual": got["decision"]},
            expected_reason={"expected": expected_reason, "actual": got["reason"] or "none"},
            expected_retry_after_s={"expected": expected_retry_after_s, "actual": got["retry_after_s"] or "none"},
            expected_spend_usd={"expected": expected_spend_usd, "actual": num(spend)},
            expected_exhausted={"expected": expected_exhausted, "actual": await or_series(gw, "gateway_canary_budget_exhausted")},
            view_spend_usd_1d={"expected": spend, "actual": (await or_view(gw))["canary"]["spend_usd_1d"]},
            usage={"actual": usage}, at={"actual": at})


# ── Cells and verdicts are counted ────────────────────────────────────────────────────────────
COUNT_ROWS = [
    pytest.param("a clean canary on (M, deepinfra), a struck one on (M, atlas-cloud)",
                 'gateway_openrouter_cells{state="candidate"} / gateway_openrouter_cells{state="eligible"} / gateway_openrouter_cells{state="excluded"}',
                 "13 / 1 / 1", id="cells are counted by state"),
    pytest.param("a clean canary on (M, deepinfra), a struck one on (M, atlas-cloud)",
                 'gateway_canary_rides_total{outcome="eligible"} / gateway_canary_rides_total{outcome="excluded"}', "1 / 1",
                 id="canary verdicts are counted"),
]


@pytest.mark.parametrize(("rides", "series", "expected_value"), COUNT_ROWS, ids=[p.id for p in COUNT_ROWS])
async def test_counted(gw, app, upstreams, rides, series, expected_value):
    world(upstream="upstream-ok", note=WORLD)
    with given(f"a first good refresh; rides = {rides}"):
        await or_refreshed(app)
        await canary_ride(gw, upstreams, "deepinfra")
        await canary_ride(gw, upstreams, "atlas-cloud", behaviour="upstream-500", outcome=None)
    names = [s.strip() for s in series.split(" / ")]
    with when(f"GET /metrics: {series}"):
        values = [await or_series(gw, n) for n in names]
    verdict(f"{series} = {expected_value}", expected_value={"expected": expected_value, "actual": " / ".join("absent" if x is None else num(x) for x in values)},
            rides={"actual": rides}, series={"actual": series})


# ── The launcher ──────────────────────────────────────────────────────────────────────────────
SKIPPED = ("M@alibaba (quantization unknown), M@open-inference (quantization fp4 < fp8), M@parasail (uptime_1d 77.4359 < 95), "
           "G@atlas-cloud (uptime_1d 77.8199 < 95), G@open-inference (quantization fp4 < fp8), G@reka (quantization unknown)")
LAUNCH_ROWS = [
    pytest.param("after a refresh: 15 candidate cells, 9 pinnable for opencode",
                 "M@deepinfra, G@near-ai, G@z-ai, M@atlas-cloud, M@morph, G@morph, G@inceptron, M@inference-net, M@baidu", SKIPPED, "none",
                 id="the launcher walks pinnable candidate cells cheapest-first; the skipped cells and their floor are in the banner ⚖"),
    pytest.param("the same view after a 429'd canary on M@deepinfra (retry_at T0 + 3600 s — T0 is 2027-01-15, ahead of the wall clock)",
                 "G@near-ai, G@z-ai, M@atlas-cloud, M@morph, G@morph, G@inceptron, M@inference-net, M@baidu", "the same six",
                 "M@deepinfra (upstream_provider_shared_pool; candidate again at 2027-01-15T09:00:00Z, backoff 3600 s)",
                 id="the launcher skips a backed-off cell and names it in `== throttled`"),
]


def _short(cell: str) -> str:
    return cell.replace(M, "M").replace(G, "G")


def _banner_section(out: str, head: str) -> list[str]:
    lines = out.splitlines()
    start = next((i for i, line in enumerate(lines) if line.startswith(head)), None)
    if start is None:
        return []
    body = []
    for line in lines[start + 1:]:
        if line.startswith("=="):
            break
        body.append(line.strip())
    return body


def _run_launcher(view_body: bytes, label: str) -> tuple[subprocess.CompletedProcess, list[str]]:
    seen: list[str] = []

    class View(BaseHTTPRequestHandler):
        def do_GET(self):
            seen.append(self.path)
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(view_body)))
            self.end_headers()
            self.wfile.write(view_body)

        def log_message(self, *_):
            pass

    srv = ThreadingHTTPServer(("127.0.0.1", 0), View)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        with when(label):
            r = subprocess.run(["bash", str(LAUNCHER), "--dry-run"], env={**os.environ, "AGENT_GATEWAY_URL": f"http://127.0.0.1:{srv.server_port}"},
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120, check=False)
            attach_json("the launcher's output", {"exit": r.returncode, "stdout": r.stdout, "stderr": r.stderr, "requests": seen})
    finally:
        srv.shutdown()
        srv.server_close()
    return r, seen


@pytest.mark.parametrize(("view", "expected_walk", "expected_skipped", "expected_throttled"), LAUNCH_ROWS, ids=[p.id for p in LAUNCH_ROWS])
async def test_launcher(gw, app, upstreams, view, expected_walk, expected_skipped, expected_throttled):
    import json

    throttled_view = view.startswith("the same view")
    world(upstream=THROTTLED if throttled_view else None, note=f"{WORLD}; a fake HTTP server hands scripts/canary-entrants.sh the view; stdin /dev/null; --dry-run")
    with given(f"view = {view}"):
        await or_refreshed(app)
        if throttled_view:
            await canary_ride(gw, upstreams, behaviour=THROTTLED, outcome=None)
        body = json.dumps(await or_view(gw)).encode()
    r, seen = _run_launcher(body, "bash scripts/canary-entrants.sh --dry-run < /dev/null, AGENT_GATEWAY_URL = the fake serving the view")
    skipped = ", ".join(_short(x) for x in _banner_section(r.stdout, "== skipped"))
    verdict(f"walk = {expected_walk} · skipped = {expected_skipped} · throttled = {expected_throttled}",
            expected_walk={"expected": expected_walk, "actual": ", ".join(_short(x) for x in re.findall(r"^== canary \d+/\d+: (\S+)$", r.stdout, re.M))},
            expected_skipped={"expected": expected_skipped, "actual": "the same six" if expected_skipped == "the same six" and skipped == SKIPPED else skipped},
            expected_throttled={"expected": expected_throttled, "actual": joined([_short(x) for x in _banner_section(r.stdout, "== throttled")])},
            exit_and_requests={"expected": (0, ["/catalog/openrouter", "/catalog/openrouter"], 0), "actual": (r.returncode, seen, r.stdout.count("ride did not dispatch"))},
            view={"actual": view})
