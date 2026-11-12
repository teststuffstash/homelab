"""GW-SESSIONS-LIVENESS — a session whose pod is gone is reaped; GET says what state a session is in
(specs/endpoints/sessions.md §The session → GW-SESSIONS-LIVENESS). The pods API is the fake `StaticPods`
(every pod running unless the row says otherwise); the reaper pass is `sessions.reap()`, driven by the
app's background loop in production and called directly here. A BOUND session's pod is the one whose
projected token pulled its env (the fake TokenReview names pod `fixer-1`, uid `uid-1`); an UNBOUND
session's pod is its CALLER's, when the caller's token is pod-bound (the specs reviewer's tick pod
`specs-review-tick`, uid `uid-c`). Header == argnames, description == id (tests/_rows.py)."""

from __future__ import annotations

import json

import pytest

from agent_gateway.liveness import PodState
from agent_gateway.pull import POD_NAME_EXTRA, POD_UID_EXTRA, Review

from ._rows import DASH, NULL, enter_world, expect, inputs
from .conftest import attach_json, check, err, given, open_session, quiet, rule, then, when

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
            doc["pulled_token"] = json.loads(r.json()["env"]["OPENCODE_CONFIG_CONTENT"])["provider"]["gateway"]["options"]["apiKey"]
    attach_json(f"arranged: a bound session on {doc['rail']}", {"session": doc["session"]["id"], "pod": pod, "uid": uid, "pulled": pull})
    return doc


async def _get(gw, sid: str, headers: dict | None = None) -> dict:
    with quiet():
        return (await gw.get(f"/sessions/{sid}", headers=headers or {})).json()


def _null(value) -> str:
    return NULL if value is None else value


# -- the reaper pass --------------------------------------------------------------------------------------
PODS = {
    "fixer-1: 404": PodState("gone"),
    "fixer-1: phase Succeeded": PodState("terminal", "uid-1"),
    "fixer-1: running, uid-2": PodState("running", "uid-2"),
    "fixer-1: running, uid-1": PodState("running", "uid-1"),
    "fixer-1: unknown (5xx / no Role)": PodState("unknown"),
    "specs-review-tick: 404": PodState("gone"),
}
BOUND = "bound, pulled by fixer-1"
BOUND_UID = "bound, pulled by fixer-1 (uid-1)"
UNPULLED = "bound, never pulled"
CALLER_POD = "unbound, the caller's token pod-bound to specs-review-tick"
CALLER_MINTED = "unbound, the caller's token not pod-bound (minted)"

REAP_ROWS = [
    pytest.param("policy-default", BOUND, "fixer-1: 404", 1, "released", "pod-gone", id="a bound session whose pod is gone is reaped"),
    pytest.param("policy-default", BOUND, "fixer-1: phase Succeeded", 1, "released", "pod-gone", id="a terminal pod is reaped"),
    pytest.param("policy-default", BOUND_UID, "fixer-1: running, uid-2", 1, "released", "pod-gone", id="a re-created pod under the same name is reaped ⚖"),
    pytest.param("policy-default", BOUND, "fixer-1: running, uid-1", 1, "active", NULL, id="a running pod keeps its session"),
    pytest.param("policy-default", BOUND, "fixer-1: unknown (5xx / no Role)", 1, "active", NULL, id="a pod the API cannot answer for is left to the TTL ⚖"),
    pytest.param("policy-default", UNPULLED, DASH, 0, "active", NULL, id="a bound session not yet pulled is not checked ⚖"),
    pytest.param("policy-default", CALLER_POD, "specs-review-tick: 404", 1, "released", "pod-gone", id="an unbound session lives in its caller's pod ⚖"),
    pytest.param("policy-default", CALLER_MINTED, DASH, 0, "active", NULL, id="a caller token with no pod binding is left to the TTL ⚖"),
]


@pytest.mark.parametrize(("world", "session", "pods_api", "expected_calls", "expected_state", "expected_release_reason"), REAP_ROWS)
async def test_the_reaper_pass(gw, app, reviews, pods, world, session, pods_api, expected_calls, expected_state, expected_release_reason):
    enter_world(world)
    inputs(session=session, pods_api=pods_api)
    headers = {}
    with given(f"session = {session}"):
        if session.startswith("bound"):
            doc = await _bound_pulled(gw, reviews, pull=session != UNPULLED)
        else:
            token = "pod-bound" if session == CALLER_POD else "minted"
            extra = {POD_NAME_EXTRA: ("specs-review-tick",), POD_UID_EXTRA: ("uid-c",)} if token == "pod-bound" else {}
            reviews.tokens[CALLER_TOKENS[token]] = Review(True, SPECS, ("agent-gateway",), extra)
            headers = {"authorization": f"Bearer {CALLER_TOKENS[token]}"}
            with quiet():
                r = await gw.post("/sessions", headers=headers, json={"stack": "platform", "role": "reviewer", "task": "specs-review homelab#1", "round": 0})
            doc = r.json()
            attach_json("arranged: an unbound reviewer session admitted by the specs reviewer", {"session": doc["session"]["id"], "caller token": token})
    with given(f"pods_api = {pods_api}: the pods API's answer"):
        if pods_api != DASH:
            name = pods_api.split(":")[0]
            pods.pods[("agent-coordinator" if name == "specs-review-tick" else NS, name)] = PODS[pods_api]
    with when("the reaper pass runs (sessions.reap())"):
        n = await app.state.sessions.reap()
        attach_json("the pass", {"reaped": n, "pods API calls": pods.calls})
    g = await _get(gw, doc["session"]["id"], headers)
    expect({"calls": len(pods.calls), "state": g["state"], "release_reason": _null(g["release_reason"])},
           calls=expected_calls, state=expected_state, release_reason=expected_release_reason)
    if session == BOUND and pods_api == "fixer-1: 404":
        with then("the pulled token is refused 401 session-released and gateway_sessions_active{rail=opencode} = 0"):
            with quiet():
                r = await gw.post("/openai/v1/chat/completions", headers={"authorization": f"Bearer {doc['pulled_token']}"}, json={"messages": []})
                text = (await gw.get("/metrics")).text
            active = next(line for line in text.splitlines() if line.startswith('gateway_sessions_active{rail="opencode"}'))
            check("data plane", (r.status_code, err(r)), (401, "session-released"))
            check("gauge", active.split()[-1], "0")


# -- what GET says ----------------------------------------------------------------------------------------
STATE_ROWS = [
    pytest.param("policy-default", "admit, GET", "active", NULL, NULL, id="an active session says active"),
    pytest.param("policy-default", "admit, DELETE, GET", "released", "released", "set", id="a released session says why"),
    pytest.param("policy-default", "admit, the clock past expires_at, GET", "expired", NULL, NULL, id="an expired session says expired, not a null release"),
    pytest.param("policy-default", "admit attempt 1 twice (the same caller, unbound), GET the first", "released", "superseded", "set", id="a superseded session says so"),
]


@pytest.mark.parametrize(("world", "sequence", "expected_state", "expected_release_reason", "expected_released_at"), STATE_ROWS)
async def test_what_get_says(gw, policy, clock, world, sequence, expected_state, expected_release_reason, expected_released_at):
    enter_world(world)
    inputs(sequence=sequence)
    with given(f"sequence = {sequence}: everything before the GET"):
        with quiet():
            doc = await open_session(gw, task="t-state")
            if "twice" in sequence:
                await open_session(gw, task="t-state")
            elif "DELETE" in sequence:
                await gw.delete(f"/sessions/{doc['session']['id']}")
            elif "expires_at" in sequence:
                clock.advance(policy.session_ttl_s + 1)
    with when(f"GET /sessions/{doc['session']['id']}"):
        g = (await gw.get(f"/sessions/{doc['session']['id']}")).json()
    expect({"state": g["state"], "release_reason": _null(g["release_reason"]), "released_at": "set" if g["released_at"] else NULL},
           state=expected_state, release_reason=expected_release_reason, released_at=expected_released_at)


# -- counted ----------------------------------------------------------------------------------------------
COUNT_ROWS = [
    pytest.param("policy-default", "a bound opencode session reaped (its pod gone)", 'gateway_sessions_reaped_total{rail="opencode"} 1',
                 id="a reap is counted on its rail"),
    pytest.param("policy-default", "three pulled bound sessions, one pass", "3 calls", id="one pods API call per live session per pass"),
]


@pytest.mark.parametrize(("world", "sequence", "expected_result"), COUNT_ROWS)
async def test_counted(gw, app, reviews, pods, world, sequence, expected_result):
    enter_world(world)
    inputs(sequence=sequence)
    with given(f"sequence = {sequence}: everything before the pass"):
        if sequence.startswith("a bound"):
            await _bound_pulled(gw, reviews)
            pods.pods[(NS, "fixer-1")] = PodState("gone")
        else:
            for i in (1, 2, 3):
                await _bound_pulled(gw, reviews, pod=f"fixer-{i}", uid=f"uid-{i}", task=f"t-{i}")
    with when("the reaper pass runs (sessions.reap())"):
        await app.state.sessions.reap()
        attach_json("pods API calls", pods.calls)
    if sequence.startswith("a bound"):
        with quiet():
            text = (await gw.get("/metrics")).text
        line = next(x for x in text.splitlines() if x.startswith('gateway_sessions_reaped_total{rail="opencode"}'))
        result = line
    else:
        result = f"{len(pods.calls)} calls"
    expect({"result": result}, result=expected_result)
