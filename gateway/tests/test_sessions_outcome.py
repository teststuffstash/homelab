"""GW-SESSIONS-OUTCOME — the consumer's outcome and the strike store (specs/endpoints/sessions.md
§Cross-cutting → GW-SESSIONS-OUTCOME). Worlds `policy-enforce` (the caller rows: every call presents a
caller token, reviewed by the fake TokenReview) and `policy-default` (the rest). Fixture callers: the
platform loop (admits platform workers), the specs reviewer (another listed caller) and the judge
(`outcome: any`, admits nothing). "the worker session" = the platform loop admitted `{platform, worker,
task homelab-2700, round 1}` on the policy walk (opencode, `opencode-go/deepseek-v4.1-flash`).
Header == argnames, description == id (tests/_rows.py)."""

from __future__ import annotations

import json

import httpx
import pytest

from agent_gateway.app import create_app
from agent_gateway.config import Policy
from agent_gateway.outcomes import OUTCOME_CLASSES
from agent_gateway.pull import Review

from ._rows import DASH, enter_world, expect, inputs
from .conftest import (
    ISLAND,
    POLICY_FIXTURE,
    ObservedAsyncClient,
    attach_json,
    bearer,
    check,
    err,
    given,
    open_session,
    quiet,
    rule,
    seed_openrouter_endpoints,
    then,
    when,
)

pytestmark = rule("GW-SESSIONS-OUTCOME")

LOOP = "system:serviceaccount:platform-agents:agentstack-loop"
SPECS = "system:serviceaccount:agent-coordinator:agent-coordinator"
JUDGE = "system:serviceaccount:agent-coordinator:outcome-judge"
TOKENS = {"the platform loop": "fake-caller-token-platform-loop", "the specs reviewer": "fake-caller-token-specs-reviewer",
          "the judge": "fake-caller-token-judge"}
TASK = "homelab-2700"
WORKER = {"stack": "platform", "role": "worker", "task": TASK, "round": 1}
CELL = {"rail": "opencode", "model": "opencode-go/deepseek-v4.1-flash", "harness": "opencode"}


@pytest.fixture(autouse=True)
def _callers(reviews):
    reviews.tokens.update({TOKENS["the platform loop"]: Review(True, LOOP, ("agent-gateway",), {}),
                           TOKENS["the specs reviewer"]: Review(True, SPECS, ("agent-gateway",), {}),
                           TOKENS["the judge"]: Review(True, JUDGE, ("agent-gateway",), {})})


def as_(who: str | None) -> dict[str, str]:
    return {} if who in (None, "no bearer") else {"authorization": f"Bearer {TOKENS[who]}"}


@pytest.fixture
async def enforce_gw(settings, secrets, store, transport, clock, reviews):
    client = httpx.AsyncClient(transport=transport)
    a = create_app(settings, policy=Policy.load(POLICY_FIXTURE.parent / "policy-enforce.json"), source=secrets, store=store,
                   client=client, clock=clock, reviewer=reviews)
    async with ObservedAsyncClient(transport=httpx.ASGITransport(app=a), base_url="http://gw") as c:
        yield c
    await client.aclose()


async def _admit(gw, who: str | None = "the platform loop", **body) -> dict:
    with quiet():
        r = await gw.post("/sessions", json={**WORKER, **body}, headers=as_(who))
    assert r.status_code == 200 and r.json()["decision"] == "dispatch", r.text
    doc = r.json()
    attach_json(f"admitted: {doc['session']['id']} on {doc['rail']} {doc['model']}", {"by": who, "rail": doc["rail"], "model": doc["model"]})
    return doc


async def _report(gw, sid: str, body: dict, who: str | None = "the platform loop"):
    return await gw.post(f"/sessions/{sid}/outcome", json=body, headers=as_(who))


def _strikes(store, counted: bool = True) -> list[dict]:
    rows = store.strikes_for("platform", TASK, counted_only=counted)
    return [{k: r[k] for k in ("rail", "model", "harness", "class", "scope", "source")} for r in rows]


def _strike_cell(rows: list[dict]) -> str:
    """The `strike?` / `strikes?` cell: `{rail, model, harness, class, scope, source}` per counted strike, `none` for none."""
    return "; ".join("{" + ", ".join(str(r[k]) for k in ("rail", "model", "harness", "class", "scope", "source")) + "}" for r in rows) or "none"


async def _series(gw, klass: str, source: str) -> float:
    with quiet():
        text = (await gw.get("/metrics")).text
    series = f'gateway_strikes_total{{class="{klass}",source="{source}"}}'
    for line in text.splitlines():
        if line.startswith(series + " "):
            return float(line.split()[-1])
    return 0.0


# -- who may report --------------------------------------------------------------------------------------
WHO_ROWS = [
    pytest.param("policy-enforce", "the platform loop", "the worker session", "no-verdict", 200, "strike {no-verdict, model}", id="the admitting caller reports an outcome"),
    pytest.param("policy-enforce", "the specs reviewer", "the worker session", "no-verdict", 403, "caller-not-owner", id="another listed caller may not"),
    pytest.param("policy-enforce", "the judge", "the worker session", "wrong-verdict", 200, "strike {wrong-verdict, model}", id="a judge may report on a session it did not admit ⚖"),
    pytest.param("policy-enforce", "the platform loop", "the worker session", "wrong-verdict", 403, "outcome-judge-only", id="wrong-verdict is a judge's call ⚖"),
    pytest.param("policy-enforce", "no bearer", "the worker session", "no-verdict", 401, "caller-unauthenticated", id="no bearer, under enforce"),
    pytest.param("policy-enforce", "the platform loop", "nope", "no-verdict", 404, "session-not-found", id="an unknown id after the caller check"),
]


@pytest.mark.parametrize(("world", "reporter", "session", "class_", "expected_status", "expected_result"), WHO_ROWS)
async def test_who_may_report(enforce_gw, world, reporter, session, class_, expected_status, expected_result):
    enter_world(world)
    inputs(reporter=reporter, session=session, **{"class": class_})
    with given(f"session = {session}: the platform loop admitted a worker session"):
        doc = await _admit(enforce_gw)
    sid = doc["session"]["id"] if session == "the worker session" else session
    with when(f"POST /sessions/{sid}/outcome {{class: {class_}}} presenting {reporter}"):
        r = await _report(enforce_gw, sid, {"class": class_}, reporter)
    result = f"strike {{{r.json()['strike']['class']}, {r.json()['strike']['scope']}}}" if r.status_code == 200 else err(r)
    expect({"status": r.status_code, "result": result}, status=expected_status, result=expected_result)


# -- what an outcome may say ------------------------------------------------------------------------------
BODIES = {
    "class: changes-requested": {"class": "changes-requested"},
    "class: flaky": {"class": "flaky"},
    "{}": {},
    "class: no-verdict, verdict: APPROVE": {"class": "no-verdict", "verdict": "APPROVE"},
    "class: no-verdict, evidence: {log: auth sk-or-v1-FAKE0000}": {"class": "no-verdict", "evidence": {"log": "auth sk-or-v1-FAKE0000"}},
    "class: no-verdict, evidence: {log: 5000 × x}": {"class": "no-verdict", "evidence": {"log": "x" * 5000}},
}
BODY_ROWS = [
    pytest.param("policy-default", "class: changes-requested", 400, "outcome-class-unknown", id="a logic failure is not an outcome class"),
    pytest.param("policy-default", "class: flaky", 400, "outcome-class-unknown", id="a class outside the vocabulary"),
    pytest.param("policy-default", "{}", 400, "malformed-body", id="a missing class"),
    pytest.param("policy-default", "class: no-verdict, verdict: APPROVE", 400, "malformed-body", id="an unknown key"),
    pytest.param("policy-default", "class: no-verdict, evidence: {log: auth sk-or-v1-FAKE0000}", 400, "outcome-evidence-refused", id="a credential-shaped evidence value is refused ⚖"),
    pytest.param("policy-default", "class: no-verdict, evidence: {log: 5000 × x}", 400, "malformed-body", id="evidence over 4096 bytes ⚖"),
]


@pytest.mark.parametrize(("world", "body", "expected_status", "expected_code"), BODY_ROWS)
async def test_what_an_outcome_may_say(gw, store, world, body, expected_status, expected_code):
    enter_world(world)
    inputs(body=body)
    with given("a worker session"):
        doc = await _admit(gw, who=None)
    with when(f"POST /sessions/{{id}}/outcome {body}"):
        r = await _report(gw, doc["session"]["id"], BODIES[body], None)
    expect({"status": r.status_code, "code": err(r)}, status=expected_status, code=expected_code)
    with then("nothing stored: no strike on the task"):
        check("strikes", _strikes(store), [])


# -- when --------------------------------------------------------------------------------------------------
WHEN_ROWS = [
    pytest.param("policy-default", "report, the session active", 200, "stored", id="an outcome before release is accepted"),
    pytest.param("policy-default", "DELETE, +3600 s, report", 200, "stored", id="an outcome after release, inside the window ⚖"),
    pytest.param("policy-default", "DELETE, +86401 s, report", 409, "outcome-window-closed", id="an outcome after the window"),
    pytest.param("policy-default", "report no-verdict twice", 200, "replay: true; one strike", id="the same outcome twice is a replay ⚖"),
    pytest.param("policy-default", "report no-verdict, then repetition", 409, "outcome-conflict", id="a different outcome from the same reporter"),
]


@pytest.mark.parametrize(("world", "sequence", "expected_status", "expected_result"), WHEN_ROWS)
async def test_when(gw, store, clock, world, sequence, expected_status, expected_result):
    enter_world(world)
    inputs(sequence=sequence)
    with given(f"sequence = {sequence}: a worker session, and everything before the last report"):
        doc = await _admit(gw, who=None)
        sid = doc["session"]["id"]
        with quiet():
            if sequence.startswith("DELETE"):
                await gw.delete(f"/sessions/{sid}")
                clock.advance(int(sequence.split("+")[1].split(" ")[0]))
            elif sequence.startswith("report no-verdict"):
                first = await _report(gw, sid, {"class": "no-verdict"}, None)
                assert first.status_code == 200, first.text
    last = "repetition" if sequence.endswith("repetition") else "no-verdict"
    with when(f"POST /sessions/{sid}/outcome {{class: {last}}}"):
        r = await _report(gw, sid, {"class": last}, None)
    if r.status_code >= 400:
        result = err(r)
    elif sequence == "report no-verdict twice":
        n = len(_strikes(store))
        result = f"replay: {str(r.json().get('replay')).lower()}; {'one strike' if n == 1 else f'{n} strikes'}"
    else:
        with quiet():
            outcome = (await gw.get(f"/sessions/{sid}")).json()["outcome"]
        result = "stored" if outcome and outcome.get("class") == "no-verdict" else f"not stored: {outcome}"
    expect({"status": r.status_code, "result": result}, status=expected_status, result=expected_result)


# -- the store ---------------------------------------------------------------------------------------------
async def _act(gw, upstreams, doc, kind: str, what: str, transport=None):
    if kind == "report":
        return await _report(gw, doc["session"]["id"], {"class": what}, None)
    if what in ("upstream-slow", "upstream-down"):  # the transport-level worlds (RailTransport)
        (transport.slow if what == "upstream-slow" else transport.unreachable).add("opencode")
    else:
        upstreams["opencode"].behaviour = what
    with quiet():
        r = await gw.post("/openai/v1/chat/completions", headers=bearer(doc),
                          json={"messages": [], **({"stream": True} if kind == "stream" else {})})
    upstreams["opencode"].behaviour = "upstream-ok"
    if transport is not None:
        transport.slow.discard("opencode")
        transport.unreachable.discard("opencode")
    attach_json(f"the session's request answered {what} → {r.status_code}", {"status": r.status_code})
    return r


def _series_cell(klass: str | None, source: str | None, n: float) -> str:
    return f'{{class="{klass}",source="{source}"}} {n:g}'


CONSUMER_ROWS = [
    pytest.param("policy-default", "no-verdict", "{opencode, opencode-go/deepseek-v4.1-flash, opencode, no-verdict, model, outcome}", '{class="no-verdict",source="outcome"} 1',
                 id="a model-scoped class strikes the model"),
    pytest.param("policy-default", "harness-gave-up", "{opencode, opencode-go/deepseek-v4.1-flash, opencode, harness-gave-up, cell, outcome}", '{class="harness-gave-up",source="outcome"} 1',
                 id="a serving-scoped class strikes the cell"),
    pytest.param("policy-default", "harness-fault", "{opencode, opencode-go/deepseek-v4.1-flash, opencode, harness-fault, harness, outcome}", '{class="harness-fault",source="outcome"} 1',
                 id="a harness-scoped class strikes the harness"),
]


@pytest.mark.parametrize(("world", "report", "expected_strike", "expected_series"), CONSUMER_ROWS)
async def test_the_consumers_strike(gw, upstreams, store, world, report, expected_strike, expected_series):
    enter_world(world)
    inputs(report=report)
    with given("a worker session (opencode, opencode-go/deepseek-v4.1-flash)"):
        doc = await open_session(gw, **WORKER)
    with when(f"POST /sessions/{{id}}/outcome {{class: {report}}}"):
        await _act(gw, upstreams, doc, "report", report)
    rows = _strikes(store)
    series = _series_cell(report, "outcome", await _series(gw, report, "outcome"))
    expect({"strike": _strike_cell(rows), "series": series}, strike=expected_strike, series=expected_series)


ANSWERED = {
    "upstream-401": [("ride", "upstream-401")],
    "upstream-500 × 3": [("ride", "upstream-500")] * 3,
    "upstream-429": [("ride", "upstream-429")],
    "upstream-slow (504 upstream-timeout)": [("ride", "upstream-slow")],
    "upstream-down (502 upstream-unreachable)": [("ride", "upstream-down")],
    "upstream-403-refused (403 upstream-refused)": [("ride", "upstream-403-refused")],
    "upstream-stream-truncated (a stream)": [("stream", "upstream-stream-truncated")],
}
GATEWAY_ROWS = [
    pytest.param("policy-default · upstream-401", "upstream-401", "{opencode, opencode-go/deepseek-v4.1-flash, opencode, auth-storm, cell, gateway}", '{class="auth-storm",source="gateway"} 1',
                 id="the gateway writes its own transport class"),
    pytest.param("policy-default · upstream-500", "upstream-500 × 3", "{opencode, opencode-go/deepseek-v4.1-flash, opencode, provider-5xx, cell, gateway}", '{class="provider-5xx",source="gateway"} 1',
                 id="one transport strike per session and class ⚖"),
    pytest.param("policy-default · upstream-429", "upstream-429", "none", DASH, id="a 429 is a cooldown, not a strike ⚖"),
    pytest.param("policy-default · upstream-slow", "upstream-slow (504 upstream-timeout)", "{opencode, opencode-go/deepseek-v4.1-flash, opencode, timeout, cell, gateway}", '{class="timeout",source="gateway"} 1',
                 id="a read timeout is a transport strike"),
    pytest.param("policy-default · upstream-down", "upstream-down (502 upstream-unreachable)", "{opencode, opencode-go/deepseek-v4.1-flash, opencode, provider-5xx, cell, gateway}", '{class="provider-5xx",source="gateway"} 1',
                 id="an unreachable upstream is a transport strike"),
    pytest.param("policy-default · upstream-403-refused", "upstream-403-refused (403 upstream-refused)", "{opencode, opencode-go/deepseek-v4.1-flash, opencode, refused, cell, gateway}", '{class="refused",source="gateway"} 1',
                 id="a policy refusal is a transport strike, not a rejected credential"),
    pytest.param("policy-default · upstream-stream-truncated", "upstream-stream-truncated (a stream)", "{opencode, opencode-go/deepseek-v4.1-flash, opencode, stream-incomplete, cell, gateway}", '{class="stream-incomplete",source="gateway"} 1',
                 id="a cut stream is a transport strike"),
]


@pytest.mark.parametrize(("world", "answered", "expected_strike", "expected_series"), GATEWAY_ROWS)
async def test_the_gateways_transport_strike(gw, upstreams, transport, store, world, answered, expected_strike, expected_series):
    enter_world(world)
    inputs(answered=answered)
    steps = ANSWERED[answered]
    with given("a worker session (opencode, opencode-go/deepseek-v4.1-flash)" + (f", its first {len(steps) - 1} request(s) answered {steps[0][1]}" if len(steps) > 1 else "")):
        doc = await open_session(gw, **WORKER)
        with quiet():
            for kind, what in steps[:-1]:
                await _act(gw, upstreams, doc, kind, what, transport)
    kind, what = steps[-1]
    with when(f"the session's {'streaming ' if kind == 'stream' else ''}request is answered {what}"):
        await _act(gw, upstreams, doc, kind, what, transport)
    rows = _strikes(store)
    series = _series_cell(rows[0]["class"], rows[0]["source"], await _series(gw, rows[0]["class"], rows[0]["source"])) if rows else DASH
    expect({"strike": _strike_cell(rows), "series": series}, strike=expected_strike, series=expected_series)
    if "403-refused" in answered:
        with then("the credential is not rejected: gateway_credentials_rejected{rail=opencode} = 0"):
            with quiet():
                text = (await gw.get("/metrics")).text
            line = next(x for x in text.splitlines() if x.startswith('gateway_credentials_rejected{rail="opencode"}'))
            check("gateway_credentials_rejected{rail=opencode}", float(line.split()[-1]), 0)


REFUTE_ROWS = [
    pytest.param("policy-default · upstream-500", "upstream-500, then upstream-ok on the same session",
                 "{opencode, opencode-go/deepseek-v4.1-flash, opencode, provider-5xx, cell, gateway}", DASH, id="a bare 2xx refutes nothing"),
    pytest.param("policy-default · upstream-500", "upstream-500, then the consumer reports clean", "none", 1, id="a clean outcome refutes the task's counted strikes"),
    pytest.param("policy-default", "the heavy model struck no-verdict; a standard-tier session of the task reports clean",
                 "{opencode, opencode-go/claude-haiku-5-5, claude, no-verdict, model, outcome}", 0, id="a clean outcome on another model refutes nothing there"),
]


@pytest.mark.parametrize(("world", "sequence", "expected_strikes", "expected_refuted"), REFUTE_ROWS)
async def test_refutation(gw, upstreams, store, world, sequence, expected_strikes, expected_refuted):
    enter_world(world)
    inputs(sequence=sequence)
    refuted = DASH
    if sequence.startswith("upstream-500"):
        with given("a worker session whose request answered upstream-500 (a gateway provider-5xx strike on its cell)"):
            doc = await open_session(gw, **WORKER)
            with quiet():
                await _act(gw, upstreams, doc, "ride", "upstream-500")
            attach_json("strikes before", _strikes(store))
        if sequence.endswith("same session"):
            with when("the same session's next request is answered upstream-ok"):
                await _act(gw, upstreams, doc, "ride", "upstream-ok")
        else:
            with when("POST /sessions/{id}/outcome {class: clean} — the ride recovered and did its job"):
                r = await _report(gw, doc["session"]["id"], {"class": "clean"}, None)
            refuted = r.json()["refuted"]
            attach_json("strikes after (all, refuted kept)", _strikes(store, counted=False))
    else:
        with given("a heavy-tier session (opencode-go/claude-haiku-5-5) struck no-verdict; a standard-tier session of the same task"):
            with quiet():
                h = await open_session(gw, **WORKER, tier="heavy")
                await _report(gw, h["session"]["id"], {"class": "no-verdict"}, None)
                s = await open_session(gw, **WORKER)
            attach_json("arranged sessions", {"heavy": h["model"], "standard": s["model"]})
        with when("POST /sessions/{standard}/outcome {class: clean}"):
            r = await _report(gw, s["session"]["id"], {"class": "clean"}, None)
        refuted = r.json()["refuted"]
    expect({"strikes": _strike_cell(_strikes(store)), "refuted": refuted}, strikes=expected_strikes, refuted=expected_refuted)


VIEW_ROWS = [
    pytest.param("policy-default", "report no-verdict (subclass rc=1), GET", "outcome {class no-verdict, subclass rc=1, reporter null}", id="GET shows the latest outcome"),
    pytest.param("policy-default", "OUTCOME_CLASSES vs outcome.input.properties.class (enum, x-scope)", "equal, class and scope", id="the code's vocabulary is the schema's"),
]


@pytest.mark.parametrize(("world", "sequence", "expected_result"), VIEW_ROWS)
async def test_one_vocabulary_one_view(gw, world, sequence, expected_result):
    enter_world(world)
    inputs(sequence=sequence)
    if sequence.startswith("report"):
        with given("a worker session with no-verdict (subclass rc=1) reported"):
            doc = await _admit(gw, who=None)
            await _report(gw, doc["session"]["id"], {"class": "no-verdict", "subclass": "rc=1"}, None)
        with when("GET /sessions/{id}"):
            got = (await gw.get(f"/sessions/{doc['session']['id']}")).json()["outcome"]
        result = f"outcome {{class {got['class']}, subclass {got['subclass']}, reporter {'null' if got['reporter'] is None else got['reporter']}}}"
    else:
        with when("read sessions.schema.json outcome.input.properties.class (enum + x-scope) and the code's OUTCOME_CLASSES"):
            schema = json.loads((ISLAND / "specs" / "endpoints" / "sessions.schema.json").read_text(encoding="utf-8"))
            cls = schema["outcome"]["input"]["properties"]["class"]
            attach_json("schema outcome.class", cls)
        result = "equal, class and scope" if sorted(cls["enum"]) == sorted(OUTCOME_CLASSES) and cls["x-scope"] == OUTCOME_CLASSES else f"schema {cls} vs code {OUTCOME_CLASSES}"
    expect({"result": result}, result=expected_result)


# -- the provider axis (GW-RAIL-OPENROUTER) -------------------------------------------------------------------
PROVIDER_PATH = "/openai/v1/chat/completions"
PROVIDER_M = "deepseek/deepseek-v4.1-flash"
FAILOVER = "deepinfra 500 → atlas-cloud 500 → morph 200"
PROVIDER_ROWS = [
    pytest.param("policy-default · openrouter-endpoints", "served by deepinfra", "harness-gave-up", "(harness-gave-up, deepinfra, no)",
                 id="a cell-scoped class lands on the provider the ride rode ⚖"),
    pytest.param("policy-default · openrouter-endpoints", FAILOVER, DASH, "(provider-5xx, deepinfra, no), (provider-5xx, atlas-cloud, no)",
                 id="a failed-over ride strikes each provider it tried, one per cell ⚖"),
    pytest.param("policy-default · openrouter-endpoints", FAILOVER, "clean", "(provider-5xx, deepinfra, no), (provider-5xx, atlas-cloud, no)",
                 id="a clean ride refutes only the cells it rode clean ⚖"),
]


def _provider_strikes(store, task: str) -> str:
    return ", ".join(f"({s['class']}, {s['provider']}, {'yes' if s['refuted_at'] else 'no'})" for s in store.strikes_for("platform", task, counted_only=False)) or "none"


@pytest.mark.parametrize(("world", "ride", "report", "expected_strikes"), PROVIDER_ROWS)
async def test_strikes_on_the_provider_axis(gw, app, store, upstreams, world, ride, report, expected_strikes):
    enter_world(world)
    inputs(ride=ride, report=report)
    task = "homelab-2741-oc-" + ("cell" if report == "harness-gave-up" else "failover" if report == DASH else "clean")
    behaviours = {"deepinfra": "upstream-500", "atlas-cloud": "upstream-500"} if ride == FAILOVER else {}
    with given(f"ride = {ride}: a worker session on rail openrouter, tier heavy ({PROVIDER_M}), task {task}, one ride (provider_behaviours {behaviours})"):
        seed_openrouter_endpoints(store, upstreams["openrouter"])
        app.state.providers.reload()
        upstreams["openrouter"].provider_behaviours.update(behaviours)
        with quiet():  # the session + ride exchanges fold into the one ride summary below
            doc = await open_session(gw, role="worker", rail="openrouter", tier="heavy", task=task)
            r = await gw.post(PROVIDER_PATH, json={"model": PROVIDER_M, "messages": []}, headers=bearer(doc))
        attach_json("the ride", {"status": r.status_code, "served_by": r.json().get("provider") if r.status_code == 200 else None})
    if report != DASH:
        with when(f"POST /sessions/{{id}}/outcome {{class: {report}}}"):
            r = await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": report})
            assert r.status_code == 200, r.text
            attach_json("the outcome answer", r.json())
    else:
        with when("no outcome is reported: the ride's own transport facts are the strikes"):
            pass
    expect({"strikes": _provider_strikes(store, task)}, strikes=expected_strikes)
