"""GW-SESSIONS-LIVENESS — a session whose pod is gone is reaped; GET says what state a session is in
(specs/endpoints/sessions.md).

World policy-default. The pods API is the fake `StaticPods` (every pod running unless the row says
otherwise); the reaper pass is `sessions.reap()`, driven by the app's background loop in production
and called directly here. A BOUND session's pod is the one whose projected token pulled its env (the
fake TokenReview names pod `fixer-1`, uid `uid-1`); an UNBOUND session's pod is its CALLER's, when the
caller's token is pod-bound (the specs reviewer's tick pod `specs-review-tick`, uid `uid-c`).

| description | session | the pods API answers || after the pass | state | release_reason |
|---|---|---||---|---|---|
| a bound session whose pod is gone is reaped | bound, pulled by fixer-1 | fixer-1: 404 || released; its token refused (401 session-released); the slot freed | released | pod-gone |
| a terminal pod is reaped | bound, pulled by fixer-1 | fixer-1: phase Succeeded || released | released | pod-gone |
| a re-created pod under the same name is reaped | bound, pulled by fixer-1 (uid-1) | fixer-1: running, uid-2 || released | released | pod-gone |
| a running pod keeps its session | bound, pulled by fixer-1 | fixer-1: running, uid-1 || active | active | null |
| a pod the API cannot answer for is left to the TTL | bound, pulled by fixer-1 | fixer-1: unknown (5xx / no Role) || active | active | null |
| a bound session not yet pulled is not checked | bound, never pulled | (no call) || active; 0 pods API calls | active | null |
| an unbound session lives in its caller's pod | unbound, caller token pod-bound to specs-review-tick | specs-review-tick: 404 || released | released | pod-gone |
| a caller token with no pod binding is left to the TTL | unbound, caller token not pod-bound (a minted token) | (no call) || active; 0 pods API calls | active | null |

| description | sequence || GET state | release_reason | released_at |
|---|---||---|---|---|
| an active session says active | admit, GET || active | null | null |
| a released session says why | admit, DELETE, GET || released | released | set |
| an expired session says expired, not a null release | admit, the clock past expires_at, GET || expired | null | null |
| a superseded session says so | admit attempt 1 twice (same caller, unbound), GET the first || released | superseded | set |

| description | sequence || result |
|---|---||---|
| a reap is counted on its rail | a bound opencode session reaped (pod gone) || gateway_sessions_reaped_total{rail="opencode"} = 1 |
| one pods API call per live session per pass | three pulled bound sessions, one pass || 3 calls |
"""

from __future__ import annotations

import pytest

from agent_gateway.liveness import PodState
from agent_gateway.pull import POD_NAME_EXTRA, POD_UID_EXTRA, Review

from .conftest import (
    attach_json,
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

pytestmark = rule("GW-SESSIONS-LIVENESS")

NS, SA = "platform-agents", "agentstack-worker"
SA_TOKEN = "fake-projected-sa-token-liveness"
SPECS = "system:serviceaccount:agent-coordinator:agent-coordinator"
CALLER_TOKENS = {"pod-bound": "fake-caller-token-specs-tick", "minted": "fake-caller-token-minted"}


def _pod_review(pod: str, uid: str) -> Review:
    return Review(True, f"system:serviceaccount:{NS}:{SA}", ("agent-gateway",), {POD_NAME_EXTRA: (pod,), POD_UID_EXTRA: (uid,)})


async def _bound_pulled(gw, reviews, pod="fixer-1", uid="uid-1", task="t-live", pull=True) -> dict:
    with quiet():
        doc = await open_session(gw, task=task, bind={"namespace": NS, "serviceaccount": SA, "pod": pod})
        if pull:
            reviews.tokens[SA_TOKEN + pod] = _pod_review(pod, uid)
            r = await gw.post(f"/sessions/{doc['session']['id']}/env", headers={"authorization": f"Bearer {SA_TOKEN + pod}"})
            assert r.status_code == 200, r.text
            doc["pulled_token"] = r.json()["env"]["OPENCODE_CONFIG_CONTENT"]
    attach_json(f"arranged: a bound session on {doc['rail']}", {"session": doc["session"]["id"], "pod": pod, "uid": uid, "pulled": pull})
    return doc


async def _get(gw, sid: str) -> dict:
    with quiet():
        return (await gw.get(f"/sessions/{sid}")).json()


BOUND_ROWS = [
    ("a bound session whose pod is gone is reaped", PodState("gone"), "released", "pod-gone"),
    ("a terminal pod is reaped", PodState("terminal", "uid-1"), "released", "pod-gone"),
    ("a re-created pod under the same name is reaped", PodState("running", "uid-2"), "released", "pod-gone"),
    ("a running pod keeps its session", PodState("running", "uid-1"), "active", None),
    ("a pod the API cannot answer for is left to the TTL", PodState("unknown"), "active", None),
]


@pytest.mark.parametrize(("answer", "state", "reason"), [r[1:] for r in BOUND_ROWS], ids=[r[0] for r in BOUND_ROWS])
async def test_bound_reap(gw, app, reviews, pods, answer, state, reason):
    world()
    with given("a bound worker session, pulled by fixer-1 (uid-1)"):
        doc = await _bound_pulled(gw, reviews)
    with given(f"answer = {answer!r}: the pods API's answer for {NS}/fixer-1"):
        pods.pods[(NS, "fixer-1")] = answer
    with when("the reaper pass runs"):
        n = await app.state.sessions.reap()
        attach_json("the pass", {"reaped": n, "pods API calls": pods.calls})
    g = await _get(gw, doc["session"]["id"])
    then_eq("state", g["state"], state, claim=f"state = {state!r}")
    then_eq("release_reason", g["release_reason"], reason, claim=f"reason (release_reason) = {reason!r}")


async def test_reaped_token_refused_and_slot_freed(gw, app, reviews, pods):
    """row: a bound session whose pod is gone is reaped"""
    world(note="the reaped session's token and slot")
    with given("a bound opencode session pulled by fixer-1; the pods API answers fixer-1: 404"):
        doc = await _bound_pulled(gw, reviews)
        pods.pods[(NS, "fixer-1")] = PodState("gone")
    with when("the reaper pass runs"):
        await app.state.sessions.reap()
    with then("the pulled token is refused 401 session-released; gateway_sessions_active{rail=opencode} = 0"):
        import json as _json
        tok = _json.loads(doc["pulled_token"])["provider"]["gateway"]["options"]["apiKey"]
        with quiet():
            r = await gw.post("/openai/v1/chat/completions", headers={"authorization": f"Bearer {tok}"}, json={"messages": []})
            text = (await gw.get("/metrics")).text
        active = next(line for line in text.splitlines() if line.startswith('gateway_sessions_active{rail="opencode"}'))
        attach_json("observed", {"data plane": [r.status_code, err(r)], "gauge": active})
        check("data plane", (r.status_code, err(r)), (401, "session-released"))
        check("gauge", active.split()[-1], "0")


async def test_unpulled_not_checked(gw, app, reviews, pods):
    """row: a bound session not yet pulled is not checked"""
    world()
    with given("a bound worker session never pulled"):
        doc = await _bound_pulled(gw, reviews, pull=False)
    with when("the reaper pass runs"):
        await app.state.sessions.reap()
    then_eq("pods API calls", len(pods.calls), 0)
    then_eq("state", (await _get(gw, doc["session"]["id"]))["state"], "active")


CALLER_ROWS = [
    ("an unbound session lives in its caller's pod", "pod-bound", 1, "released", "pod-gone"),
    ("a caller token with no pod binding is left to the TTL", "minted", 0, "active", None),
]


@pytest.mark.parametrize(("token", "calls", "state", "reason"), [r[1:] for r in CALLER_ROWS], ids=[r[0] for r in CALLER_ROWS])
async def test_caller_pod(gw, app, reviews, pods, token, calls, state, reason):
    world()
    with given(f"token = {token!r}: the specs reviewer admits an unbound reviewer session; its pod specs-review-tick is gone"):
        extra = {POD_NAME_EXTRA: ("specs-review-tick",), POD_UID_EXTRA: ("uid-c",)} if token == "pod-bound" else {}
        reviews.tokens[CALLER_TOKENS[token]] = Review(True, SPECS, ("agent-gateway",), extra)
        pods.pods[("agent-coordinator", "specs-review-tick")] = PodState("gone")
        with quiet():
            r = await gw.post("/sessions", headers={"authorization": f"Bearer {CALLER_TOKENS[token]}"},
                              json={"stack": "platform", "role": "reviewer", "task": "specs-review homelab#1", "round": 0})
        doc = r.json()
    with when("the reaper pass runs"):
        await app.state.sessions.reap()
        attach_json("pods API calls", pods.calls)
    then_eq("calls", len(pods.calls), calls, claim=f"calls = {calls!r}")
    with quiet():
        g = (await gw.get(f"/sessions/{doc['session']['id']}", headers={"authorization": f"Bearer {CALLER_TOKENS[token]}"})).json()
    then_eq("state", g["state"], state, claim=f"state = {state!r}")
    then_eq("release_reason", g["release_reason"], reason, claim=f"reason = {reason!r}")


async def _supersede(gw):
    first = await open_session(gw, task="t-sup")
    await open_session(gw, task="t-sup")
    return first


STATE_ROWS = [
    ("an active session says active", "active", ("active", None, False)),
    ("a released session says why", "release", ("released", "released", True)),
    ("an expired session says expired, not a null release", "expire", ("expired", None, False)),
    ("a superseded session says so", "supersede", ("released", "superseded", True)),
]


@pytest.mark.parametrize(("seq", "expected"), [r[1:] for r in STATE_ROWS], ids=[r[0] for r in STATE_ROWS])
async def test_get_state(gw, clock, seq, expected):
    world()
    with given(f"seq = {seq!r}"):
        with quiet():
            doc = await (_supersede(gw) if seq == "supersede" else open_session(gw, task="t-state"))
            if seq == "release":
                await gw.delete(f"/sessions/{doc['session']['id']}")
            if seq == "expire":
                clock.advance(14401)
    with when("GET /sessions/{id}"):
        g = (await gw.get(f"/sessions/{doc['session']['id']}")).json()
    got = (g["state"], g["release_reason"], g["released_at"] is not None)
    then_eq("expected", got, expected, claim=f"expected (state, release_reason, released) = {expected!r}")


async def test_reap_counted(gw, app, reviews, pods):
    """row: a reap is counted on its rail"""
    world()
    with given("a bound opencode session pulled by fixer-1; fixer-1 gone"):
        await _bound_pulled(gw, reviews)
        pods.pods[(NS, "fixer-1")] = PodState("gone")
    with when("the reaper pass runs"):
        await app.state.sessions.reap()
    with then("gateway_sessions_reaped_total{rail=opencode} = 1"):
        with quiet():
            text = (await gw.get("/metrics")).text
        line = next(x for x in text.splitlines() if x.startswith('gateway_sessions_reaped_total{rail="opencode"}'))
        check("series", line.split()[-1], "1")


async def test_one_call_per_session(gw, app, reviews, pods):
    """row: one pods API call per live session per pass"""
    world()
    with given("three bound sessions pulled by fixer-1, fixer-2, fixer-3"):
        for i in (1, 2, 3):
            await _bound_pulled(gw, reviews, pod=f"fixer-{i}", uid=f"uid-{i}", task=f"t-{i}")
    with when("one reaper pass"):
        await app.state.sessions.reap()
        attach_json("pods API calls", pods.calls)
    then_eq("calls", len(pods.calls), 3)
