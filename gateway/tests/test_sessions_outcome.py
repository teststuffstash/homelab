"""GW-SESSIONS-OUTCOME — the consumer's outcome and the strike store (specs/endpoints/sessions.md).

Worlds `policy-enforce` (the caller rows: every call presents a caller token, reviewed by the fake
TokenReview) and `policy-default` (the rest). Fixture callers: the platform loop (admits platform
workers), the specs reviewer (another listed caller) and the judge (`outcome: any`, admits nothing).
A "worker session" = the platform loop admitted `{platform, worker, task homelab-2700, round 1}` on
the policy walk (opencode, `opencode-go/deepseek-v4.1-flash`).

Who may report:

| description | world | reporter | body || status | result |
|---|---|---|---||---|---|
| the admitting caller reports an outcome | policy-enforce | the platform loop | no-verdict || 200 | strike {no-verdict, model} |
| another listed caller may not | policy-enforce | the specs reviewer | no-verdict || 403 | caller-not-owner |
| a judge may report on a session it did not admit | policy-enforce | the judge | wrong-verdict || 200 | strike {wrong-verdict, model} |
| wrong-verdict is a judge's call | policy-enforce | the platform loop | wrong-verdict || 403 | outcome-judge-only |
| no bearer, under enforce | policy-enforce | no bearer | no-verdict || 401 | caller-unauthenticated; outcome/absent + 1 |
| an unknown id after the caller check | policy-enforce | the platform loop | POST /sessions/nope/outcome || 404 | session-not-found |

What an outcome may say (policy-default):

| description | body || status | result |
|---|---||---|---|
| a logic failure is not an outcome class | class changes-requested || 400 | outcome-class-unknown |
| a class outside the vocabulary | class flaky || 400 | outcome-class-unknown |
| a missing class | {} || 400 | malformed-body |
| an unknown key | class no-verdict, verdict APPROVE || 400 | malformed-body |
| a credential-shaped evidence value is refused | class no-verdict, evidence {log: sk-or-v1-FAKE…} || 400 | outcome-evidence-refused |
| evidence over 4096 bytes | class no-verdict, evidence {log: 5000 × x} || 400 | malformed-body |

When (policy-default; the window = outcome_window_s 86400 after the session's end):

| description | sequence || status | result |
|---|---||---|---|
| an outcome before release is accepted | report, then DELETE || 200 | outcome stored |
| an outcome after release, inside the window | DELETE, +3600 s, report || 200 | outcome stored |
| an outcome after the window | DELETE, +86401 s, report || 409 | outcome-window-closed |
| the same outcome twice is a replay | report no-verdict twice || 200, 200 | one strike; replay = true |
| a different outcome from the same reporter | report no-verdict, then repetition || 409 | outcome-conflict |

The store (policy-default):

| description | sequence || strikes on task homelab-2700 (counted) | gateway_strikes_total |
|---|---||---|---|
| a model-scoped class strikes the model | report no-verdict || [{opencode, opencode-go/deepseek-v4.1-flash, no-verdict, model, outcome}] | {class=no-verdict,source=outcome} 1 |
| a serving-scoped class strikes the cell | report harness-gave-up || [{…, harness-gave-up, cell, outcome}] | {class=harness-gave-up,source=outcome} 1 |
| a harness-scoped class strikes the harness | report harness-fault || [{…, harness-fault, harness, outcome}] with harness opencode | {class=harness-fault,source=outcome} 1 |
| the gateway writes its own transport class | the session's request answered upstream-401 || [{…, auth-storm, cell, gateway}] | {class=auth-storm,source=gateway} 1 |
| one transport strike per session and class | three upstream-500 answers on one session || one provider-5xx strike | {class=provider-5xx,source=gateway} 1 |
| a 429 is a cooldown, not a strike | the session's request answered upstream-429 || [] | — |
| a consumer outcome after a relayed 429 strikes nothing | upstream-429, then the consumer reports unknown || none; the outcome stored (GET → unknown) | — |
| a harness that gave up on a 429 strikes nothing | upstream-429, then the consumer reports harness-gave-up || none | — |
| a 429 followed by a 2xx is no capacity death | upstream-429, then upstream-ok on the same session, then the consumer reports unknown || {…, unknown, model, outcome} | {class="unknown",source="outcome"} 1 |
| a clean outcome after a 429 still refutes | an earlier session's counted no-verdict on the task; this session upstream-429, then the consumer reports clean || the earlier strike refuted (refuted: 1) | — |
| a read timeout is a transport strike | upstream-slow (504) on the session || [{…, timeout, cell, gateway}] | {class=timeout,source=gateway} 1 |
| an unreachable upstream is a transport strike | upstream-down (502) on the session || [{…, provider-5xx, cell, gateway}] | {class=provider-5xx,source=gateway} 1 |
| a policy refusal is a transport strike, not a rejected credential | upstream-403-refused on the session || [{…, refused, cell, gateway}] | {class=refused,source=gateway} 1 |
| a cut stream is a transport strike | upstream-stream-truncated on the session || [{…, stream-incomplete, cell, gateway}] | {class=stream-incomplete,source=gateway} 1 |
| a clean outcome refutes the task's counted strikes | the session's request answered upstream-500 (a gateway provider-5xx), then the consumer reports clean || [] (refuted 1) | — |
| a bare 2xx refutes nothing | upstream-500, then upstream-ok on the same session || [provider-5xx] | — |
| a clean outcome on another model refutes nothing there | heavy-tier session struck no-verdict; standard-tier session clean || [no-verdict on the heavy model] | — |
| GET shows the latest outcome | report no-verdict, GET || — | outcome {class no-verdict, reporter the loop} |

The vocabulary:

| description | input || result |
|---|---||---|
| the code's vocabulary is the schema's | OUTCOME_CLASSES vs sessions.schema.json outcome.class enum + x-scope || equal, class and scope |

The provider axis (world policy-default · openrouter-endpoints — GW-RAIL-OPENROUTER; a worker session on
rail openrouter, tier heavy, rides deepseek/deepseek-v4.1-flash pinned):

| description | sequence || strikes on the task (class, provider, refuted) |
|---|---||---|
| a cell-scoped class lands on the provider the ride rode | the ride served by deepinfra; the consumer reports harness-gave-up || [(harness-gave-up, deepinfra, no)] |
| a failed-over ride strikes each provider it tried, one per cell | deepinfra 500 → atlas-cloud 500 → morph 200 || [(provider-5xx, deepinfra, no), (provider-5xx, atlas-cloud, no)] |
| a clean ride refutes only the cells it rode clean | the same, then the consumer reports clean || [(provider-5xx, deepinfra, no), (provider-5xx, atlas-cloud, no)] — morph served it, the two failed cells stay counted |
"""

from __future__ import annotations

import json

import pytest

from agent_gateway.outcomes import OUTCOME_CLASSES
from agent_gateway.pull import Review

from .conftest import (
    ISLAND,
    attach_json,
    bearer,
    check,
    err,
    given,
    open_session,
    quiet,
    rule,
    then,
    then_eq,
    when,
    world,
)

pytestmark = rule("GW-SESSIONS-OUTCOME")

LOOP = "system:serviceaccount:platform-agents:agentstack-loop"
SPECS = "system:serviceaccount:agent-coordinator:agent-coordinator"
JUDGE = "system:serviceaccount:agent-coordinator:outcome-judge"
TOKENS = {"the platform loop": "fake-caller-token-platform-loop", "the specs reviewer": "fake-caller-token-specs-reviewer",
          "the judge": "fake-caller-token-judge"}
TASK = "homelab-2700"
WORKER = {"stack": "platform", "role": "worker", "task": TASK, "round": 1}


@pytest.fixture(autouse=True)
def _callers(reviews):
    reviews.tokens.update({TOKENS["the platform loop"]: Review(True, LOOP, ("agent-gateway",), {}),
                           TOKENS["the specs reviewer"]: Review(True, SPECS, ("agent-gateway",), {}),
                           TOKENS["the judge"]: Review(True, JUDGE, ("agent-gateway",), {})})


def as_(who: str | None) -> dict[str, str]:
    return {} if who in (None, "no bearer") else {"authorization": f"Bearer {TOKENS[who]}"}


@pytest.fixture
async def enforce_gw(settings, secrets, store, transport, clock, reviews):
    import httpx

    from agent_gateway.app import create_app
    from agent_gateway.config import Policy

    from .conftest import POLICY_FIXTURE, ObservedAsyncClient

    client = httpx.AsyncClient(transport=transport)
    a = create_app(settings, policy=Policy.load(POLICY_FIXTURE.parent / "policy-enforce.json"), source=secrets, store=store,
                   client=client, clock=clock, reviewer=reviews)
    async with ObservedAsyncClient(transport=httpx.ASGITransport(app=a), base_url="http://gw") as c:
        yield c
    await client.aclose()


async def _admit(gw, who: str = "the platform loop", **body) -> dict:
    with quiet():
        r = await gw.post("/sessions", json={**WORKER, **body}, headers=as_(who))
    assert r.status_code == 200 and r.json()["decision"] == "dispatch", r.text
    doc = r.json()
    attach_json(f"admitted: {doc['session']['id']} on {doc['rail']} {doc['model']}", {"by": who, "rail": doc["rail"], "model": doc["model"]})
    return doc


async def _report(gw, sid: str, body: dict, who: str = "the platform loop"):
    return await gw.post(f"/sessions/{sid}/outcome", json=body, headers=as_(who))


def _strikes(store, counted: bool = True, attach: bool = True) -> list[dict]:
    rows = store.strikes_for("platform", TASK, counted_only=counted)
    out = [{k: r[k] for k in ("rail", "model", "harness", "class", "scope", "source")} for r in rows]
    if attach:
        attach_json("strikes on task " + TASK + (" (counted)" if counted else " (all)"), out)
    return out


async def _strike_series(gw, klass: str, source: str) -> float:
    with quiet():
        text = (await gw.get("/metrics")).text
    series = f'gateway_strikes_total{{class="{klass}",source="{source}"}}'
    for line in text.splitlines():
        if line.startswith(series + " "):
            return float(line.split()[-1])
    return 0.0


# -- who may report --------------------------------------------------------------------------------
WHO_ROWS = [
    ("the admitting caller reports an outcome", "the platform loop", {"class": "no-verdict"}, 200, {"class": "no-verdict", "scope": "model"}),
    ("another listed caller may not", "the specs reviewer", {"class": "no-verdict"}, 403, "caller-not-owner"),
    ("a judge may report on a session it did not admit", "the judge", {"class": "wrong-verdict"}, 200, {"class": "wrong-verdict", "scope": "model"}),
    ("wrong-verdict is a judge's call", "the platform loop", {"class": "wrong-verdict"}, 403, "outcome-judge-only"),
    ("no bearer, under enforce", "no bearer", {"class": "no-verdict"}, 401, "caller-unauthenticated"),
]


@pytest.mark.parametrize(("who", "body", "status", "result"), [r[1:] for r in WHO_ROWS], ids=[r[0] for r in WHO_ROWS])
async def test_who_may_report(enforce_gw, who, body, status, result):
    world("policy-enforce")
    with given("a worker session the platform loop admitted"):
        doc = await _admit(enforce_gw)
    with when(f"POST /sessions/{{id}}/outcome body = {body!r} presenting who = {who!r}"):
        r = await _report(enforce_gw, doc["session"]["id"], body, who)
    then_eq("status", r.status_code, status, claim=f"status = {status!r}")
    if status == 200:
        then_eq("result", r.json()["strike"], result, claim=f"result (the strike) = {result!r}")
    else:
        then_eq("result", err(r), result, claim=f"result (the error code) = {result!r}")


async def test_unknown_id_after_caller(enforce_gw):
    """row: an unknown id after the caller check"""
    world("policy-enforce")
    with when("POST /sessions/nope/outcome {class: no-verdict} presenting the platform loop"):
        r = await _report(enforce_gw, "nope", {"class": "no-verdict"})
    then_eq("status", r.status_code, 404)
    then_eq("code", err(r), "session-not-found", claim="error code = session-not-found")


# -- what an outcome may say -----------------------------------------------------------------------
BODY_ROWS = [
    ("a logic failure is not an outcome class", {"class": "changes-requested"}, "outcome-class-unknown"),
    ("a class outside the vocabulary", {"class": "flaky"}, "outcome-class-unknown"),
    ("a missing class", {}, "malformed-body"),
    ("an unknown key", {"class": "no-verdict", "verdict": "APPROVE"}, "malformed-body"),
    ("a credential-shaped evidence value is refused", {"class": "no-verdict", "evidence": {"log": "auth sk-or-v1-FAKE0000"}}, "outcome-evidence-refused"),
    # the 5000-byte value is built in the case (EVIDENCE_5000): the row's parameter stays its short name
    ("evidence over 4096 bytes", {"class": "no-verdict", "evidence": "EVIDENCE_5000"}, "malformed-body"),
]
EVIDENCE_5000 = {"log": "x" * 5000}


@pytest.mark.parametrize(("body", "code"), [r[1:] for r in BODY_ROWS], ids=[r[0] for r in BODY_ROWS])
async def test_outcome_body(gw, store, body, code):
    world()
    with given("a worker session"):
        doc = await _admit(gw, who=None)
    sent = {**body, "evidence": EVIDENCE_5000} if body.get("evidence") == "EVIDENCE_5000" else body
    with when(f"POST /sessions/{{id}}/outcome body = {body!r}" + (" (EVIDENCE_5000 = {log: 5000 × 'x'})" if sent is not body else "")):
        r = await _report(gw, doc["session"]["id"], sent, None)
    then_eq("status", r.status_code, 400)
    then_eq("code", err(r), code, claim=f"code = {code!r}")
    with then("nothing stored: no strike on the task"):
        check("strikes", _strikes(store), [])


# -- when --------------------------------------------------------------------------------------------
WHEN_ROWS = [
    ("an outcome before release is accepted", "before", 0, 200, None),
    ("an outcome after release, inside the window", "after", 3600, 200, None),
    ("an outcome after the window", "after", 86401, 409, "outcome-window-closed"),
]


@pytest.mark.parametrize(("order", "advance", "status", "code"), [r[1:] for r in WHEN_ROWS], ids=[r[0] for r in WHEN_ROWS])
async def test_outcome_window(gw, clock, order, advance, status, code):
    world()
    with given("a worker session"):
        doc = await _admit(gw, who=None)
    sid = doc["session"]["id"]
    with given(f"order = {order!r}, advance = {advance!r}: " + ("the session stays active" if order == "before"
                                                                 else f"it is released, then {advance} s pass")):
        if order == "after":
            with quiet():
                await gw.delete(f"/sessions/{sid}")
            clock.advance(advance)
    with when("POST /sessions/{id}/outcome {class: no-verdict}"):
        r = await _report(gw, sid, {"class": "no-verdict"}, None)
    then_eq("status", r.status_code, status, claim=f"status = {status!r}")
    then_eq("code", err(r) if r.status_code >= 400 else None, code, claim=f"code = {code!r}")


async def test_same_outcome_twice_is_replay(gw, store):
    """row: the same outcome twice is a replay"""
    world()
    with given("a worker session with no-verdict reported once"):
        with quiet():
            doc = await _admit(gw, who=None)
            first = await _report(gw, doc["session"]["id"], {"class": "no-verdict"}, None)
    with when("POST /sessions/{id}/outcome {class: no-verdict} again"):
        with quiet():
            r = await _report(gw, doc["session"]["id"], {"class": "no-verdict"}, None)
        attach_json("the two replies", {"first": first.json(), "again": r.json()})
    then_eq("statuses", (first.status_code, r.status_code), (200, 200))
    then_eq("replay", r.json()["replay"], True)
    with then("one strike"):
        check("strikes", len(_strikes(store)), 1)


async def test_different_outcome_conflicts(gw):
    """row: a different outcome from the same reporter"""
    world()
    with given("a worker session with no-verdict reported"):
        doc = await _admit(gw, who=None)
        await _report(gw, doc["session"]["id"], {"class": "no-verdict"}, None)
    with when("POST /sessions/{id}/outcome {class: repetition}"):
        r = await _report(gw, doc["session"]["id"], {"class": "repetition"}, None)
    then_eq("status", r.status_code, 409)
    then_eq("code", err(r), "outcome-conflict", claim="error code = outcome-conflict")


# -- the store ---------------------------------------------------------------------------------------
CELL = {"rail": "opencode", "model": "opencode-go/deepseek-v4.1-flash", "harness": "opencode"}
STORE_ROWS = [
    ("a model-scoped class strikes the model", [("report", "no-verdict")], [{**CELL, "class": "no-verdict", "scope": "model", "source": "outcome"}],
     ("no-verdict", "outcome", 1)),
    ("a serving-scoped class strikes the cell", [("report", "harness-gave-up")],
     [{**CELL, "class": "harness-gave-up", "scope": "cell", "source": "outcome"}], ("harness-gave-up", "outcome", 1)),
    ("a harness-scoped class strikes the harness", [("report", "harness-fault")],
     [{**CELL, "class": "harness-fault", "scope": "harness", "source": "outcome"}], ("harness-fault", "outcome", 1)),
    ("the gateway writes its own transport class", [("ride", "upstream-401")], [{**CELL, "class": "auth-storm", "scope": "cell", "source": "gateway"}],
     ("auth-storm", "gateway", 1)),
    ("one transport strike per session and class", [("ride", "upstream-500"), ("ride", "upstream-500"), ("ride", "upstream-500")],
     [{**CELL, "class": "provider-5xx", "scope": "cell", "source": "gateway"}], ("provider-5xx", "gateway", 1)),
    ("a 429 is a cooldown, not a strike", [("ride", "upstream-429")], [], None),
    ("a consumer outcome after a relayed 429 strikes nothing ⚖", [("ride", "upstream-429"), ("report", "unknown")], [], ("unknown", "outcome", 0)),
    ("a harness that gave up on a 429 strikes nothing ⚖", [("ride", "upstream-429"), ("report", "harness-gave-up")], [],
     ("harness-gave-up", "outcome", 0)),
    ("a 429 followed by a 2xx is no capacity death ⚖", [("ride", "upstream-429"), ("ride", "upstream-ok"), ("report", "unknown")],
     [{**CELL, "class": "unknown", "scope": "model", "source": "outcome"}], ("unknown", "outcome", 1)),
    ("a read timeout is a transport strike", [("ride", "upstream-slow")], [{**CELL, "class": "timeout", "scope": "cell", "source": "gateway"}],
     ("timeout", "gateway", 1)),
    ("an unreachable upstream is a transport strike", [("ride", "upstream-down")],
     [{**CELL, "class": "provider-5xx", "scope": "cell", "source": "gateway"}], ("provider-5xx", "gateway", 1)),
    ("a policy refusal is a transport strike, not a rejected credential", [("ride", "upstream-403-refused")],
     [{**CELL, "class": "refused", "scope": "cell", "source": "gateway"}], ("refused", "gateway", 1)),
    ("a cut stream is a transport strike", [("stream", "upstream-stream-truncated")],
     [{**CELL, "class": "stream-incomplete", "scope": "cell", "source": "gateway"}], ("stream-incomplete", "gateway", 1)),
    ("a bare 2xx refutes nothing", [("ride", "upstream-500"), ("ride", "upstream-ok")],
     [{**CELL, "class": "provider-5xx", "scope": "cell", "source": "gateway"}], None),
]


async def _act(gw, upstreams, doc, step, transport=None):
    kind, what = step
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


@pytest.mark.parametrize(("steps", "strikes", "series"), [r[1:] for r in STORE_ROWS], ids=[r[0] for r in STORE_ROWS])
async def test_store(gw, upstreams, transport, store, steps, strikes, series):
    world(upstream=next((w for k, w in steps if k != "report"), "upstream-ok"))
    with given(f"steps = {steps!r}: a worker session (opencode, opencode-go/deepseek-v4.1-flash)"
               + (f", arranged: {steps[:-1]!r}" if steps[:-1] else "")):
        with quiet():
            doc = await open_session(gw, **WORKER)
            statuses = [(await _act(gw, upstreams, doc, step, transport)).status_code for step in steps[:-1]]
        attach_json("arranged", {"session": doc["session"]["id"], "model": doc["model"], "arranged statuses": statuses})
    with when(f"{steps[-1][0]} {steps[-1][1]}"):
        await _act(gw, upstreams, doc, steps[-1], transport)
    with then(f"strikes = {strikes!r} (the counted strikes on task {TASK})"):
        check("strikes", _strikes(store), strikes)
    with then(f"series = {series!r} (gateway_strikes_total{{class, source}} = n)"):
        if series:
            check("series", await _strike_series(gw, series[0], series[1]), series[2])
    if any(w == "upstream-403-refused" for _, w in steps):
        with then("the credential is not rejected: gateway_credentials_rejected{rail=opencode} = 0"):
            with quiet():
                text = (await gw.get("/metrics")).text
            line = next(x for x in text.splitlines() if x.startswith('gateway_credentials_rejected{rail="opencode"}'))
            check("gateway_credentials_rejected{rail=opencode}", float(line.split()[-1]), 0)


async def test_clean_refutes(gw, upstreams, store):
    """row: a clean outcome refutes the task's counted strikes"""
    world(upstream="upstream-500")
    with given("a worker session whose request answered upstream-500 (a gateway provider-5xx strike on its cell)"):
        with quiet():
            a1 = await open_session(gw, **WORKER)
            await _act(gw, upstreams, a1, ("ride", "upstream-500"))
        before = _strikes(store, attach=False)
    with when("POST /sessions/{id}/outcome {class: clean} — the ride recovered and did its job"):
        with quiet():
            r = await _report(gw, a1["session"]["id"], {"class": "clean"}, None)
        attach_json("the outcome answer", r.json())
    after_counted, after_all = _strikes(store, attach=False), _strikes(store, counted=False, attach=False)
    attach_json("strikes on task " + TASK + ": before / after clean", {"before (counted)": before, "after (counted)": after_counted,
                                                                      "after (all, refuted kept)": after_all})
    with then("refuted = 1; no counted strike is left on the task (the strike is kept, refuted)"):
        assert r.json()["refuted"] == 1 and after_counted == [] and len(after_all) == 1, (r.json(), after_counted, after_all)


async def test_clean_after_429_still_refutes(gw, upstreams, store):
    """row: a clean outcome after a 429 still refutes ⚖"""
    world(upstream="upstream-ok")
    with given("two worker sessions on the task, both admitted on the same model (round 2 does not supersede round 1)"):
        with quiet():
            a1 = await open_session(gw, **WORKER)
            a2 = await open_session(gw, **{**WORKER, "round": 2})
    with given("the earlier session's no-verdict is counted (model-scoped, so it excludes that model for the task)"):
        with quiet():
            await _report(gw, a1["session"]["id"], {"class": "no-verdict"}, None)
        before = _strikes(store, attach=False)
    with given("this session's request answered upstream-429"):
        with quiet():
            await _act(gw, upstreams, a2, ("ride", "upstream-429"))
    with when("POST /sessions/{id}/outcome {class: clean}"):
        with quiet():
            r = await _report(gw, a2["session"]["id"], {"class": "clean"}, None)
        attach_json("the outcome answer", r.json())
    then_eq("refuted", r.json()["refuted"], 1)
    with then("the earlier no-verdict is no longer counted"):
        check("strikes before / after", (len(before), _strikes(store)), (1, []))


async def test_clean_elsewhere_refutes_nothing(gw, store):
    """row: a clean outcome on another model refutes nothing there"""
    world()
    with given("a heavy-tier session (opencode-go/claude-haiku-5-5) struck no-verdict; a standard-tier session (opencode-go/deepseek-v4.1-flash) of the same task"):
        with quiet():
            h = await open_session(gw, **WORKER, tier="heavy")
            await _report(gw, h["session"]["id"], {"class": "no-verdict"}, None)
            s = await open_session(gw, **WORKER)
        attach_json("arranged sessions", {"heavy": h["model"], "standard": s["model"]})
    with when("POST /sessions/{standard}/outcome {class: clean}"):
        with quiet():
            r = await _report(gw, s["session"]["id"], {"class": "clean"}, None)
        attach_json("the outcome answer", r.json())
    then_eq("refuted", r.json()["refuted"], 0)
    with then("the heavy model's no-verdict still counts"):
        check("strikes", _strikes(store), [{"rail": "opencode", "model": "opencode-go/claude-haiku-5-5", "harness": "claude",
                                            "class": "no-verdict", "scope": "model", "source": "outcome"}])


async def test_get_shows_outcome(gw):
    """row: GET shows the latest outcome"""
    world()
    with given("a worker session with no-verdict reported"):
        doc = await _admit(gw, who=None)
        await _report(gw, doc["session"]["id"], {"class": "no-verdict", "subclass": "rc=1"}, None)
    with when("GET /sessions/{id}"):
        r = await gw.get(f"/sessions/{doc['session']['id']}")
    with then("outcome = {class no-verdict, subclass rc=1, reporter null (admitted under observe)}"):
        got = r.json()["outcome"]
        check("outcome", {k: got[k] for k in ("class", "subclass", "reporter")}, {"class": "no-verdict", "subclass": "rc=1", "reporter": None})


async def test_vocabulary_is_the_schemas():
    """row: the code's vocabulary is the schema's"""
    world()
    with when("read sessions.schema.json outcome.class (enum + x-scope)"):
        schema = json.loads((ISLAND / "specs" / "endpoints" / "sessions.schema.json").read_text(encoding="utf-8"))
        cls = schema["outcome"]["input"]["properties"]["class"]
        attach_json("schema outcome.class", cls)
    with then("equal, class and scope"):
        check("classes", sorted(cls["enum"]), sorted(OUTCOME_CLASSES))
        check("scopes", cls["x-scope"], OUTCOME_CLASSES)


# -- the provider axis (GW-RAIL-OPENROUTER) -------------------------------------------------------
PROVIDER_PATH = "/openai/v1/chat/completions"
PROVIDER_M = "deepseek/deepseek-v4.1-flash"


def _provider_strikes(store, task: str) -> list[tuple[str, str, str]]:
    return [(s["class"], s["provider"], "yes" if s["refuted_at"] else "no") for s in store.strikes_for("platform", task, counted_only=False)]


async def _provider_ride(gw, app, store, upstreams, task: str, behaviours: dict | None = None) -> dict:
    from .conftest import seed_openrouter_endpoints

    seed_openrouter_endpoints(store, upstreams["openrouter"])
    app.state.providers.reload()
    upstreams["openrouter"].provider_behaviours.update(behaviours or {})
    with given(f"a worker session on rail openrouter, tier heavy ({PROVIDER_M}), task {task}; one ride (provider_behaviours {behaviours or {}})"):
        doc = await open_session(gw, role="worker", harness="opencode", rail="openrouter", tier="heavy", task=task)
        r = await gw.post(PROVIDER_PATH, json={"model": PROVIDER_M, "messages": []}, headers=bearer(doc))
        attach_json("the ride", {"status": r.status_code, "served_by": r.json().get("provider") if r.status_code == 200 else None})
    return doc


async def test_cell_class_lands_on_provider(gw, app, store, upstreams):
    """row: a cell-scoped class lands on the provider the ride rode"""
    world(upstream="upstream-ok", note="openrouter-endpoints")
    task = "homelab-2741-oc-cell"
    doc = await _provider_ride(gw, app, store, upstreams, task)
    with when("POST /sessions/{id}/outcome class harness-gave-up"):
        r = await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": "harness-gave-up"})
    then_eq("status", r.status_code, 200)
    then_eq("strikes (class, provider, refuted)", _provider_strikes(store, task), [("harness-gave-up", "deepinfra", "no")])


async def test_failed_over_ride_strikes_each_cell(gw, app, store, upstreams):
    """row: a failed-over ride strikes each provider it tried, one per cell"""
    world(upstream="upstream-ok", note="openrouter-endpoints; deepinfra and atlas-cloud answer 500")
    task = "homelab-2741-oc-failover"
    with when("one ride: deepinfra 500 → atlas-cloud 500 → morph 200"):
        await _provider_ride(gw, app, store, upstreams, task, {"deepinfra": "upstream-500", "atlas-cloud": "upstream-500"})
    then_eq("strikes (class, provider, refuted)", _provider_strikes(store, task),
            [("provider-5xx", "deepinfra", "no"), ("provider-5xx", "atlas-cloud", "no")])


async def test_clean_refutes_only_ridden_cells(gw, app, store, upstreams):
    """row: a clean ride refutes only the cells it rode clean"""
    world(upstream="upstream-ok", note="openrouter-endpoints; deepinfra and atlas-cloud answer 500")
    task = "homelab-2741-oc-clean"
    doc = await _provider_ride(gw, app, store, upstreams, task, {"deepinfra": "upstream-500", "atlas-cloud": "upstream-500"})
    with when("POST /sessions/{id}/outcome class clean"):
        r = await gw.post(f"/sessions/{doc['session']['id']}/outcome", json={"class": "clean"})
    then_eq("status · refuted", (r.status_code, r.json()["refuted"]), (200, 0))
    then_eq("strikes (class, provider, refuted)", _provider_strikes(store, task),
            [("provider-5xx", "deepinfra", "no"), ("provider-5xx", "atlas-cloud", "no")])
