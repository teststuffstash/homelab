"""GW-SESSIONS-AUTH — the control plane's caller: its projected token, its `callers` entry, the knob
(specs/endpoints/sessions.md §Cross-cutting → GW-SESSIONS-AUTH). Worlds `policy-default` (control_plane_auth
observe) and `policy-enforce` (the same, enforce). The TokenReview is the fake `StaticTokenReviews` (the
`reviews` fixture), the same seam the env pull uses; each presented caller token reviews as the row's
`presented` cell. Header == argnames, description == id (tests/_rows.py)."""

from __future__ import annotations

import copy
import json
import logging

import httpx
import pytest

from agent_gateway.app import create_app
from agent_gateway.config import Policy, PolicyError
from agent_gateway.pull import POD_NAME_EXTRA, KubeTokenReviews, Review

from ._rows import DASH, NULL, enter_world, expect, inputs
from .conftest import (
    POLICY_FIXTURE,
    ObservedAsyncClient,
    attach_json,
    check,
    err,
    given,
    quiet,
    rule,
    then,
    when,
)

pytestmark = rule("GW-SESSIONS-AUTH")

ISLAND = POLICY_FIXTURE.parent.parent.parent
DEPLOYED_POLICY = ISLAND.parent / "argocd" / "resources" / "agent-gateway" / "policy.json"
ENFORCE_POLICY = POLICY_FIXTURE.parent / "policy-enforce.json"

LOOP = "system:serviceaccount:platform-agents:agentstack-loop"
SPECS = "system:serviceaccount:agent-coordinator:agent-coordinator"   # the fixture world's specs reviewer
DEPLOYED_SPECS = "system:serviceaccount:agent-coordinator:specs-review"   # the deployed tick's own SA (#2685)
COORDINATOR_NS = "system:serviceaccount:agent-coordinator:agent-coordinator"   # the coordinator namespace's shared SA
JUDGE = "system:serviceaccount:agent-coordinator:outcome-judge"   # the fixture AND deployed judge (`outcome: any`, admits nothing)
ORACLE_LOOP = "system:serviceaccount:oracle-agents:agentstack-loop"   # not a fixture caller: an oracle session's recorded admitter
UNLISTED = "system:serviceaccount:platform-agents:default"
# Fixture caller tokens: plain strings, never JWT-shaped (the masking row lives in test_redact.py).
TOKENS = {
    "the platform loop": "fake-caller-token-platform-loop",
    "the specs reviewer": "fake-caller-token-specs-reviewer",
    "the judge": "fake-caller-token-judge",
    "an unlisted ServiceAccount": "fake-caller-token-unlisted",
    "unauthenticated": "fake-caller-token-unauthenticated",
    "the kube API audience": "fake-caller-token-kube-audience",
}
RAISES = "(the review raises)"
NO_BEARER = "no bearer"
NOT_JSON = "no bearer, the body not JSON"
BIND = {"namespace": "platform-agents", "serviceaccount": "agentstack-worker", "pod": "fixer-1"}
TASK = "homelab-2588-r1"
WORKER = {"stack": "platform", "role": "worker", "task": TASK, "round": 1, "bind": BIND}
REVIEWER = {"stack": "platform", "role": "reviewer", "task": TASK, "round": 0}   # the specs reviewer's unbound body
REASONS = ("absent", "invalid", "review-transient")


def _review(user: str, audiences=("agent-gateway",)) -> Review:
    return Review(True, user, tuple(audiences), {})


@pytest.fixture(autouse=True)
def _callers(reviews):
    """The fake TokenReview's answer per presented caller token (the spec's `presented` cells)."""
    reviews.tokens.update({
        TOKENS["the platform loop"]: _review(LOOP),
        TOKENS["the specs reviewer"]: _review(SPECS),
        TOKENS["the judge"]: _review(JUDGE),
        TOKENS["an unlisted ServiceAccount"]: _review(UNLISTED),
        TOKENS["unauthenticated"]: Review(False),
        TOKENS["the kube API audience"]: _review(LOOP, ("https://kubernetes.default.svc",)),
    })


@pytest.fixture
async def enforce_app(settings, secrets, store, transport, clock, reviews):
    client = httpx.AsyncClient(transport=transport)
    a = create_app(settings, policy=Policy.load(ENFORCE_POLICY), source=secrets, store=store, client=client,
                   clock=clock, reviewer=reviews)
    yield a
    await client.aclose()


@pytest.fixture
async def enforce_gw(enforce_app):
    async with ObservedAsyncClient(transport=httpx.ASGITransport(app=enforce_app), base_url="http://gw") as c:
        yield c


@pytest.fixture
def gws(gw, enforce_gw):
    return {"policy-default": gw, "policy-enforce": enforce_gw}


def as_(presented: str | None) -> dict[str, str]:
    """The caller's headers: its projected token as the bearer, or none."""
    if presented in (None, NO_BEARER, NOT_JSON):
        return {}
    if presented == RAISES:
        return {"authorization": "Bearer fake-caller-token-review-raises"}
    return {"authorization": f"Bearer {TOKENS[presented]}"}


async def unauth(gw, route: str, reason: str) -> float:
    with quiet():
        text = (await gw.get("/metrics")).text
    series = f'gateway_control_plane_unauthenticated_total{{route="{route}",reason="{reason}"}}'
    for line in text.splitlines():
        if line.startswith(series + " "):
            return float(line.split()[-1])
    raise AssertionError(f"{series} not rendered")


async def counted(gw, route: str, before: dict[str, float]) -> str:
    """The `counted?` cell: which `gateway_control_plane_unauthenticated_total{route,reason}` series moved."""
    moved = {k: await unauth(gw, route, k) - v for k, v in before.items()}
    up = [f"{route}/{k} +{int(n)}" for k, n in moved.items() if n]
    return ", ".join(up) if up else "none"


async def admitted(gw, presented: str | None, body: dict | None = None) -> dict:
    """Given: an admitted session (arrange — muted, one summary line in the step name)."""
    with quiet():
        r = await gw.post("/sessions", json=body or WORKER, headers=as_(presented))
    assert r.status_code == 200 and r.json()["decision"] == "dispatch", r.text
    return r.json()


# -- who may call ------------------------------------------------------------------------------------------
ENFORCE_ROWS = [
    pytest.param("policy-enforce", "the platform loop", 200, DASH, LOOP, "none", id="the platform loop admits a bound platform worker"),
    pytest.param("policy-enforce", NO_BEARER, 401, "caller-unauthenticated", DASH, "admit/absent +1", id="no bearer, under enforce"),
    pytest.param("policy-enforce", "unauthenticated", 401, "caller-unauthenticated", DASH, "admit/invalid +1", id="a token the API does not authenticate, under enforce"),
    pytest.param("policy-enforce", "the kube API audience", 401, "caller-unauthenticated", DASH, "admit/invalid +1", id="a token for another audience, under enforce"),
    pytest.param("policy-enforce", RAISES, 503, "tokenreview-transient", DASH, "admit/review-transient +1", id="the TokenReview API fails, under enforce"),
    pytest.param("policy-enforce", NOT_JSON, 401, "caller-unauthenticated", DASH, "admit/absent +1", id="the caller check precedes the body ⚖"),
    pytest.param("policy-enforce", "an unlisted ServiceAccount", 403, "caller-unknown", DASH, "none", id="an unlisted ServiceAccount, under enforce"),
]
OBSERVE_ROWS = [
    pytest.param("policy-default", NO_BEARER, 200, DASH, NULL, "admit/absent +1", id="no bearer, under observe, is admitted and counted ⚖"),
    pytest.param("policy-default", "unauthenticated", 200, DASH, NULL, "admit/invalid +1", id="an invalid token, under observe, is admitted and counted"),
    pytest.param("policy-default", RAISES, 200, DASH, NULL, "admit/review-transient +1", id="a review the API cannot answer, under observe, is admitted and counted ⚖"),
    pytest.param("policy-default", "an unlisted ServiceAccount", 403, "caller-unknown", DASH, "none", id="an unlisted ServiceAccount is refused under observe too ⚖"),
]


async def _who_may_call(gws, reviews, store, world, presented, expected):
    enter_world(world)
    inputs(presented=presented)
    gw = gws[world]
    with given(f"presented = {presented}" + (" — the fake TokenReview raises" if presented == RAISES else "")):
        reviews.transient = presented == RAISES
        before = {r: await unauth(gw, "admit", r) for r in REASONS}
    with when(f"POST /sessions (platform worker, bind {BIND['namespace']}/{BIND['serviceaccount']}) presenting {presented}"):
        if presented == NOT_JSON:
            r = await gw.post("/sessions", content=b"not json", headers={"content-type": "application/json"})
        else:
            r = await gw.post("/sessions", json=WORKER, headers=as_(presented))
    caller = DASH if r.status_code != 200 else (store.get_session(r.json()["session"]["id"]).caller or NULL)
    view = {"status": r.status_code, "code": err(r) if r.status_code >= 400 else None, "caller": caller, "counted": await counted(gw, "admit", before)}
    expect(view, **expected)
    if r.status_code == 503:
        assert r.headers.get("retry-after") == "5", r.headers


@pytest.mark.parametrize(("world", "presented", "expected_status", "expected_code", "expected_caller", "expected_counted"), ENFORCE_ROWS)
async def test_who_may_call_under_enforce(gws, reviews, store, world, presented, expected_status, expected_code, expected_caller, expected_counted):
    await _who_may_call(gws, reviews, store, world, presented,
                        {"status": expected_status, "code": expected_code, "caller": expected_caller, "counted": expected_counted})


@pytest.mark.parametrize(("world", "presented", "expected_status", "expected_code", "expected_caller", "expected_counted"), OBSERVE_ROWS)
async def test_who_may_call_under_observe(gws, reviews, store, world, presented, expected_status, expected_code, expected_caller, expected_counted):
    await _who_may_call(gws, reviews, store, world, presented,
                        {"status": expected_status, "code": expected_code, "caller": expected_caller, "counted": expected_counted})


# -- what a caller may ask for ------------------------------------------------------------------------------
BODIES = {
    "stack oracle, worker, bind platform-agents/agentstack-worker": {**WORKER, "stack": "oracle", "bind": {"namespace": "platform-agents", "serviceaccount": "agentstack-worker"}},
    "platform reviewer, bind platform-agents/agentstack-worker/fixer-1": {**WORKER, "role": "reviewer"},
    "platform prober, no bind": {"stack": "platform", "role": "prober", "task": "canary-deepseek-v4-1-flash-atlas-cloud-fp8", "round": 0},
    "platform worker, bind oracle-agents/agentstack-worker": {**WORKER, "bind": {"namespace": "oracle-agents", "serviceaccount": "agentstack-worker"}},
    "platform reviewer, bind platform-agents/agentstack-worker": {**WORKER, "role": "reviewer", "bind": {"namespace": "platform-agents", "serviceaccount": "agentstack-worker"}},
    "platform reviewer, no bind": {"stack": "platform", "role": "reviewer", "task": "homelab-2640-specs", "round": 0},
    "platform worker, bind platform-agents/agentstack-worker/fixer-1, no task": {k: v for k, v in WORKER.items() if k != "task"},
}
ASK_ROWS = [
    pytest.param("policy-default", "the platform loop", "stack oracle, worker, bind platform-agents/agentstack-worker", 403, "caller-stack-denied",
                 id="a stack outside the caller's entry"),
    pytest.param("policy-default", "the platform loop", "platform reviewer, bind platform-agents/agentstack-worker/fixer-1", 403, "caller-role-denied",
                 id="a role outside the caller's entry"),
    pytest.param("policy-default", "the platform loop", "platform prober, no bind", 200, DASH,
                 id="the entry canary's role is inside the dispatcher's entry ⚖"),
    pytest.param("policy-default", "the platform loop", "platform worker, bind oracle-agents/agentstack-worker", 403, "caller-bind-denied",
                 id="a bind namespace outside the caller's entry"),
    pytest.param("policy-default", "the specs reviewer", "platform reviewer, bind platform-agents/agentstack-worker", 403, "caller-bind-denied",
                 id="a caller with no bind namespaces may not bind"),
    pytest.param("policy-default", "the specs reviewer", "platform reviewer, no bind", 200, DASH,
                 id="an unbound admission needs no bind namespace"),
    pytest.param("policy-default", "the platform loop", "platform worker, bind platform-agents/agentstack-worker/fixer-1, no task", 400, "malformed-body",
                 id="a known caller's malformed body is still 400"),
]


@pytest.mark.parametrize(("world", "presented", "body", "expected_status", "expected_code"), ASK_ROWS)
async def test_what_a_caller_may_ask_for(gw, world, presented, body, expected_status, expected_code):
    enter_world(world)
    inputs(presented=presented, body=body)
    with when(f"POST /sessions {BODIES[body]} presenting {presented}"):
        r = await gw.post("/sessions", json=BODIES[body], headers=as_(presented))
    expect({"status": r.status_code, "code": err(r) if r.status_code >= 400 else None}, status=expected_status, code=expected_code)
    if r.status_code == 200:
        with then("the dispatch carries session.token and env (GW-SESSIONS-ENV)"):
            doc = r.json()
            check("(token, env)", ("token" in doc["session"], "env" in doc), (True, True))


# -- lookup and release -------------------------------------------------------------------------------------
OWNER_ROWS = [
    pytest.param("policy-enforce", "the platform loop", "GET", "the platform loop", 200, DASH, "none", id="the admitting caller reads its session"),
    pytest.param("policy-enforce", "the platform loop", "DELETE", "the platform loop", 200, DASH, "none", id="the admitting caller releases its session"),
    pytest.param("policy-enforce", "the platform loop", "GET", "the specs reviewer", 403, "caller-not-owner", "none", id="another listed caller may not read it"),
    pytest.param("policy-enforce", "the platform loop", "DELETE", "the specs reviewer", 403, "caller-not-owner", "none", id="another listed caller may not release it"),
    pytest.param("policy-enforce", "the platform loop", "DELETE", NO_BEARER, 401, "caller-unauthenticated", "release/absent +1", id="a release without a bearer, under enforce"),
    pytest.param("policy-default", "the platform loop", "GET", NO_BEARER, 200, DASH, "lookup/absent +1", id="a lookup without a bearer, under observe, is served and counted"),
    pytest.param("policy-default", NO_BEARER, "DELETE", "the specs reviewer", 200, DASH, "none", id="a session admitted with no caller is released by any listed caller ⚖"),
]


@pytest.mark.parametrize(("world", "admitter", "verb", "presented", "expected_status", "expected_code", "expected_counted"), OWNER_ROWS)
async def test_lookup_and_release_belong_to_the_admitting_caller(gws, world, admitter, verb, presented, expected_status, expected_code, expected_counted):
    enter_world(world)
    inputs(admitter=admitter, verb=verb, presented=presented)
    gw = gws[world]
    route = "lookup" if verb == "GET" else "release"
    with given(f"admitter = {admitter}: a session it admitted"):
        sid = (await admitted(gw, admitter))["session"]["id"]
        before = {r: await unauth(gw, route, r) for r in REASONS}
    with when(f"{verb} /sessions/{sid} presenting {presented}"):
        r = await gw.request(verb, f"/sessions/{sid}", headers=as_(presented))
    expect({"status": r.status_code, "code": err(r) if r.status_code >= 400 else None, "counted": await counted(gw, route, before)},
           status=expected_status, code=expected_code, counted=expected_counted)
    if r.status_code == 200 and verb == "GET":
        with then(f"the row's caller = {LOOP}"):
            check("caller", r.json()["caller"], LOOP)
    if r.status_code == 200 and verb == "DELETE":
        with then("released_at is set"):
            check("released_at set", bool(r.json().get("released_at")), True)
    if expected_code == "caller-not-owner" and verb == "DELETE":
        with then("the session stays active: GET by its owner shows released_at = null"):
            with quiet():
                row = (await gw.get(f"/sessions/{sid}", headers=as_(admitter))).json()
            check("released_at", row["released_at"], None)


UNKNOWN_ROWS = [
    pytest.param("policy-enforce", "the platform loop", 404, "session-not-found", id="an unknown id is 404 only after the caller check ⚖"),
    pytest.param("policy-enforce", NO_BEARER, 401, "caller-unauthenticated", id="an unknown id without a bearer, under enforce ⚖"),
]


@pytest.mark.parametrize(("world", "presented", "expected_status", "expected_code"), UNKNOWN_ROWS)
async def test_an_unknown_id(enforce_gw, world, presented, expected_status, expected_code):
    enter_world(world)
    inputs(presented=presented)
    with when(f"GET /sessions/nope presenting {presented}"):
        r = await enforce_gw.get("/sessions/nope", headers=as_(presented))
    expect({"status": r.status_code, "code": err(r)}, status=expected_status, code=expected_code)


# -- a judge finds a task's sessions --------------------------------------------------------------------------
LOOP_RELEASED = "the platform loop (released) + the specs reviewer"
BOTH = "the platform loop + the specs reviewer"
ORACLE = "an oracle dispatcher"
LIST_ROWS = [
    pytest.param("policy-enforce", LOOP_RELEASED, "the judge", "T", 200, "(the platform loop, released), (the specs reviewer, active)", "none",
                 id="the judge lists a task two callers admitted"),
    pytest.param("policy-enforce", BOTH, "the platform loop", "T", 200, "(the platform loop, active)", "none", id="the admitting caller lists only its own"),
    pytest.param("policy-enforce", "the platform loop", "the specs reviewer", "T", 200, "[]", "none", id="another listed caller sees an empty list, never a 403"),
    pytest.param("policy-enforce", ORACLE, "the judge", "T", 200, "[]", "none", id="the judge lists a task of a stack outside its entry ⚖"),
    pytest.param("policy-enforce", "the platform loop", "the judge", "nope", 200, "[]", "none", id="an unknown task is an empty list"),
    pytest.param("policy-default", "the platform loop", NO_BEARER, "T", 200, "(the platform loop, active)", "list/absent +1",
                 id="a list without a bearer, under observe, is served and counted ⚖"),
    pytest.param("policy-enforce", DASH, "the judge", "(none)", 400, "malformed-body", "none", id="no task is 400 malformed-body"),
    pytest.param("policy-enforce", DASH, NO_BEARER, "T", 401, "caller-unauthenticated", "list/absent +1", id="a list without a bearer, under enforce"),
]
NAMES = {LOOP: "the platform loop", SPECS: "the specs reviewer", JUDGE: "the judge", ORACLE_LOOP: "an oracle dispatcher"}


async def _task_sessions(gw, store, clock, admitted_by: str) -> None:
    """Given: the task's sessions, one per named admitter, one clock second apart (created_at
    orders the list); `(released)` = the admitter DELETEs its own; an oracle dispatcher's session
    is stored directly (no fixture caller may admit stack oracle), recorded as that SA's."""
    for who in admitted_by.split(" + "):
        if who == ORACLE:
            store.create_session(id="s-oracle-fixture", token_hash="unminted:s-oracle-fixture", stack="oracle", role="worker", task=TASK,
                                 round=1, rail="openrouter", harness="goose", model="deepseek/deepseek-v4-flash",
                                 created_at=clock(), expires_at=clock() + 3600, caller=ORACLE_LOOP)
        else:
            name = who.removesuffix(" (released)")
            doc = await admitted(gw, name, REVIEWER if name == "the specs reviewer" else WORKER)
            if who.endswith("(released)"):
                with quiet():
                    await gw.delete(f"/sessions/{doc['session']['id']}", headers=as_(name))
        clock.advance(1)


@pytest.mark.parametrize(("world", "admitted_by", "presented", "task", "expected_status", "expected_rows", "expected_counted"), LIST_ROWS)
async def test_a_judge_finds_a_tasks_sessions(gws, store, clock, world, admitted_by, presented, task, expected_status, expected_rows, expected_counted):
    enter_world(world)
    inputs(admitted_by=admitted_by, presented=presented, task=task)
    gw = gws[world]
    with given(f"admitted_by = {admitted_by}: task {TASK}'s sessions, oldest first" if admitted_by != DASH else "no session is needed: the check refuses before any row is read"):
        if admitted_by != DASH:
            await _task_sessions(gw, store, clock, admitted_by)
        before = {r: await unauth(gw, "list", r) for r in REASONS}
    query = {} if task == "(none)" else {"task": TASK if task == "T" else task}
    with when(f"GET /sessions with query {query} presenting {presented}"):
        r = await gw.get("/sessions", params=query, headers=as_(presented))
    if r.status_code == 200:
        rows = r.json()["sessions"]
        assert all({"task", "state", "outcome", "caller"} <= set(row) and "token" not in row for row in rows), rows
        listed = ", ".join(f"({NAMES.get(row['caller'], row['caller'])}, {row['state']})" for row in rows) or "[]"
    else:
        listed = err(r)  # a refused list: the `rows?` cell is the error code
    expect({"status": r.status_code, "rows": listed, "counted": await counted(gw, "list", before)},
           status=expected_status, rows=expected_rows, counted=expected_counted)


# -- one TokenReview path, and the pull stays the pod's --------------------------------------------------------
PATH_ROWS = [
    pytest.param("policy-enforce", "the gateway's reviewer is the kube one on a fake API that answers the platform loop's username; POST /sessions with the loop's bearer",
                 "200 dispatch; one TokenReview, spec.audiences [agent-gateway], sent with the gateway's own ServiceAccount token",
                 id="the caller's token is reviewed by the pull's reviewer, for audience agent-gateway"),
    pytest.param("policy-enforce", "the platform loop admits a bound worker; the bound pod (not in callers) pulls",
                 "200 {id, expires_at, env}", id="the env pull is not caller-checked"),
]


@pytest.mark.parametrize(("world", "sequence", "expected_result"), PATH_ROWS)
async def test_one_tokenreview_path(enforce_gw, enforce_app, reviews, tmp_path, world, sequence, expected_result):
    enter_world(world)
    inputs(sequence=sequence)
    if sequence.startswith("the gateway's reviewer"):
        seen: list[dict] = []
        auth_headers: list[str] = []

        def api(request: httpx.Request) -> httpx.Response:
            seen.append(json.loads(request.content))
            auth_headers.append(request.headers.get("authorization", ""))
            return httpx.Response(201, json={"status": {"authenticated": True, "audiences": ["agent-gateway"], "user": {"username": LOOP}}})

        with given("the gateway's reviewer is the kube one (KubeTokenReviews — the pull's) on a fake API answering the platform loop"):
            (tmp_path / "token").write_text("gateway-own-sa-token-fixture")
            kube = KubeTokenReviews(sa_dir=str(tmp_path))
            kube._client = httpx.AsyncClient(transport=httpx.MockTransport(api), base_url="https://kubernetes.default.svc")
            enforce_app.state.sessions.reviewer = kube
        with when("POST /sessions (platform worker + bind) with the caller's bearer"):
            r = await enforce_gw.post("/sessions", json=WORKER, headers=as_("the platform loop"))
        ok = (len(seen), [b["spec"]["audiences"] for b in seen], auth_headers) == (1, [["agent-gateway"]], ["Bearer gateway-own-sa-token-fixture"])
        result = (f"{r.status_code} {r.json().get('decision')}; " + ("one TokenReview, spec.audiences [agent-gateway], sent with the gateway's own ServiceAccount token"
                                                                     if ok else f"reviews {seen}, bearers {auth_headers}"))
    else:
        pod_token = "fake-projected-sa-token-for-pod-fixer-1"
        with given("the platform loop admitted a bound worker; the pod's token reviews as the bind (not a caller)"):
            reviews.tokens[pod_token] = Review(True, "system:serviceaccount:platform-agents:agentstack-worker", ("agent-gateway",), {POD_NAME_EXTRA: ("fixer-1",)})
            sid = (await admitted(enforce_gw, "the platform loop"))["session"]["id"]
        with when(f"POST /sessions/{sid}/env with the bound pod's token"):
            r = await enforce_gw.post(f"/sessions/{sid}/env", headers={"authorization": f"Bearer {pod_token}"})
        result = f"{r.status_code} {{{', '.join(sorted(r.json(), key=['id', 'expires_at', 'env'].index) if r.status_code == 200 else err(r))}}}"
    expect({"result": result}, result=expected_result)


# -- the policy shape --------------------------------------------------------------------------------------------
def _raw() -> dict:
    return json.loads(POLICY_FIXTURE.read_text(encoding="utf-8"))


MUTATIONS = {
    "callers key system:serviceaccount:platform-agents:*": lambda d: d["callers"].__setitem__("system:serviceaccount:platform-agents:*", d["callers"].pop(LOOP)),
    "the platform loop's stacks: [nope]": lambda d: d["callers"][LOOP].__setitem__("stacks", ["nope"]),
    "the platform loop without bind_namespaces": lambda d: d["callers"][LOOP].pop("bind_namespaces"),
    "control_plane_auth absent": lambda d: d.pop("control_plane_auth"),
    "callers absent": lambda d: d.pop("callers"),
}
DEPLOYED = "argocd/resources/agent-gateway/policy.json"
DEPLOYED_LOAD = ("loads: control_plane_auth enforce; callers = the platform loop, the oracle prober, the specs-review tick, "
                 "the coordinator namespace's shared SA, the outcome judge")
SHAPE_ROWS = [
    pytest.param("policy-default", "callers key system:serviceaccount:platform-agents:*", "PolicyError", id="a caller key that is not a ServiceAccount username refuses the load"),
    pytest.param("policy-default", "the platform loop's stacks: [nope]", "PolicyError", id="a caller naming a stack the policy does not hold refuses the load"),
    pytest.param("policy-default", "the platform loop without bind_namespaces", "PolicyError", id="a caller entry missing a key refuses the load"),
    pytest.param("policy-default", "control_plane_auth absent", "PolicyError", id="a policy without control_plane_auth refuses the load ⚖"),
    pytest.param("policy-default", "callers absent", "PolicyError", id="a policy without callers refuses the load ⚖"),
    pytest.param("policy-default", DEPLOYED, DEPLOYED_LOAD, id="the deployed callers are today's four dispatchers and the judge, under enforce ⚖"),
]
DEPLOYED_CALLERS = {
    LOOP: {"stacks": ["platform"], "roles": ["coordinator", "prober", "researcher", "reviewer", "worker"],
           "bind_namespaces": ["agent-runtime", "homelab", "openrouter-operator", "platform-agents"], "outcome": "own"},
    ORACLE_LOOP: {"stacks": ["oracle"], "roles": ["prober"], "bind_namespaces": [], "outcome": "own"},
    DEPLOYED_SPECS: {"stacks": ["platform"], "roles": ["reviewer", "worker"], "bind_namespaces": [], "outcome": "own"},
    COORDINATOR_NS: {"stacks": ["platform"], "roles": ["coordinator", "responder", "retro"], "bind_namespaces": ["openrouter-operator"], "outcome": "own"},
    JUDGE: {"stacks": ["platform"], "roles": [], "bind_namespaces": [], "outcome": "any"},
}


@pytest.mark.parametrize(("world", "policy", "expected_load"), SHAPE_ROWS)
def test_the_policy_shape(world, policy, expected_load):
    enter_world(world)
    inputs(policy=policy)
    if policy == DEPLOYED:
        with when(f"Policy.from_dict({DEPLOYED}) — the DEPLOYED policy, not the world's"):
            p = Policy.from_dict(json.loads(DEPLOYED_POLICY.read_text(encoding="utf-8")))
            got = {k: {"stacks": sorted(c.stacks), "roles": sorted(c.roles), "bind_namespaces": sorted(c.bind_namespaces), "outcome": c.outcome}
                   for k, c in p.callers.items()}
            attach_json("the deployed callers", got)
        load = DEPLOYED_LOAD if p.control_plane_auth == "enforce" and got == DEPLOYED_CALLERS else f"loads: {p.control_plane_auth}; callers {got}"
    else:
        d = copy.deepcopy(_raw())
        MUTATIONS[policy](d)
        with when(f"Policy.from_dict(policy-default with {policy}) — callers: {sorted(d.get('callers', {}))}, control_plane_auth: {d.get('control_plane_auth')}"):
            try:
                Policy.from_dict(d)
                load = "loaded"
            except PolicyError as e:
                load = "PolicyError"
                attach_json("PolicyError", {"message": str(e)})
    expect({"load": load}, load=expected_load)


# -- what the log says -----------------------------------------------------------------------------------------
LOG_ROWS = [
    pytest.param("policy-enforce", "the platform loop admits", f"caller={LOOP}", "the presented token", id="a dispatch line names the caller, never its token"),
    pytest.param("policy-default", "POST /sessions with no bearer", "exactly one line: control-plane: admit unauthenticated (absent) — ADMITTED under control_plane_auth=observe", DASH,
                 id="an unauthenticated call is one line naming the route and the reason"),
]


@pytest.mark.parametrize(("world", "sequence", "expected_holds", "expected_never_holds"), LOG_ROWS)
async def test_what_the_log_says(gws, caplog, world, sequence, expected_holds, expected_never_holds):
    enter_world(world)
    inputs(sequence=sequence)
    gw = gws[world]
    caplog.set_level(logging.INFO)
    presented = "the platform loop" if world == "policy-enforce" else NO_BEARER
    with when(f"POST /sessions (platform worker + bind) presenting {presented}"):
        r = await gw.post("/sessions", json=WORKER, headers=as_(presented))
    assert r.status_code == 200, r.text
    if world == "policy-enforce":
        lines = [rec.getMessage() for rec in caplog.records if rec.name == "gateway.sessions" and "dispatch id=" in rec.getMessage()]
        holds = f"caller={LOOP}" if lines and all(f"caller={LOOP}" in line for line in lines) else f"dispatch lines: {lines}"
        leaked = any(TOKENS["the platform loop"] in rec.getMessage() for rec in caplog.records)
        never = "the presented token" if not leaked else "the presented token IS in a line"
    else:
        lines = [rec.getMessage() for rec in caplog.records if rec.name == "gateway.control"]
        holds = ("exactly one line: " + lines[0]) if len(lines) == 1 else f"{len(lines)} control-plane lines: {lines}"
        never = DASH
    expect({"holds": holds, "never_holds": never}, holds=expected_holds, never_holds=expected_never_holds)
