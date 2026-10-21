"""GW-SESSIONS-AUTH — the control plane's caller: its projected token, its `callers` entry, the knob (specs/endpoints/sessions.md).

Worlds `policy-default` (control_plane_auth observe) and `policy-enforce` (the same, enforce) — each
row names its world. The TokenReview is the fake `StaticTokenReviews` (the `reviews` fixture), the
same seam the env pull uses; each presented caller token reviews as the row's `presented` cell.

Who may call:

| description | world | presented | status | result |
|---|---|---|---|---|
| the platform loop admits a bound platform worker | policy-enforce | the platform loop | 200 | dispatch; row caller = the loop |
| no bearer, under enforce | policy-enforce | no bearer | 401 | caller-unauthenticated; admit/absent + 1 |
| a token the API does not authenticate, under enforce | policy-enforce | unauthenticated | 401 | caller-unauthenticated; admit/invalid + 1 |
| a token for another audience, under enforce | policy-enforce | the kube API audience | 401 | caller-unauthenticated; admit/invalid + 1 |
| the TokenReview API fails, under enforce | policy-enforce | (the review raises) | 503 | tokenreview-transient; admit/review-transient + 1 |
| the caller check precedes the body ⚖ | policy-enforce | no bearer, body not JSON | 401 | caller-unauthenticated |
| no bearer, under observe, is admitted and counted ⚖ | policy-default | no bearer | 200 | dispatch; caller null; admit/absent + 1 |
| an invalid token, under observe, is admitted and counted | policy-default | unauthenticated | 200 | dispatch; admit/invalid + 1 |
| a review the API cannot answer, under observe, is admitted and counted ⚖ | policy-default | (the review raises) | 200 | dispatch; admit/review-transient + 1 |
| an unlisted ServiceAccount, under enforce | policy-enforce | an unlisted ServiceAccount | 403 | caller-unknown |
| an unlisted ServiceAccount is refused under observe too ⚖ | policy-default | an unlisted ServiceAccount | 403 | caller-unknown; unauthenticated series unchanged |

What a caller may ask for (policy-default):

| description | presented | body | status | result |
|---|---|---|---|---|
| a stack outside the caller's entry | the platform loop | oracle worker + bind | 403 | caller-stack-denied |
| a role outside the caller's entry | the platform loop | platform reviewer + bind | 403 | caller-role-denied |
| the entry canary's role is inside the dispatcher's entry | the platform loop | platform prober, no bind | 200 | — |
| a bind namespace outside the caller's entry | the platform loop | bind oracle-agents | 403 | caller-bind-denied |
| a caller with no bind namespaces may not bind | the specs reviewer | platform reviewer + bind | 403 | caller-bind-denied |
| an unbound admission needs no bind namespace | the specs reviewer | platform reviewer, no bind | 200 | dispatch with token + env |
| a known caller's malformed body is still 400 | the platform loop | no task | 400 | malformed-body |

Lookup and release belong to the admitting caller:

| description | world | sequence | status | result |
|---|---|---|---|---|
| the admitting caller reads its session | policy-enforce | loop admits, GETs | 200 | caller = the loop |
| the admitting caller releases its session | policy-enforce | loop admits, DELETEs | 200 | released_at set |
| another listed caller may not read it | policy-enforce | loop admits; specs reviewer GETs | 403 | caller-not-owner |
| another listed caller may not release it | policy-enforce | loop admits; specs reviewer DELETEs | 403 | caller-not-owner; still active |
| a release without a bearer, under enforce | policy-enforce | loop admits; DELETE no bearer | 401 | caller-unauthenticated; release/absent + 1 |
| a lookup without a bearer, under observe, is served and counted | policy-default | loop admits; GET no bearer | 200 | lookup/absent + 1 |
| a session admitted with no caller is released by any listed caller ⚖ | policy-default | no-bearer admit; specs reviewer DELETEs | 200 | released_at set |
| an unknown id is 404 only after the caller check ⚖ | policy-enforce | loop GETs /sessions/nope | 404 | session-not-found |
| an unknown id without a bearer, under enforce ⚖ | policy-enforce | GET /sessions/nope, no bearer | 401 | caller-unauthenticated |

A judge finds a task's sessions (GET /sessions?task=, route `list`):

| description | world | sequence | status | result |
|---|---|---|---|---|
| the judge lists a task two callers admitted | policy-enforce | loop admits + releases, specs reviewer admits; the judge lists | 200 | both rows, oldest first (released, active) |
| the admitting caller lists only its own | policy-enforce | loop + specs reviewer admit; the loop lists | 200 | the loop's row |
| another listed caller sees an empty list, never a 403 | policy-enforce | loop admits; the specs reviewer lists | 200 | [] |
| the judge lists a task of a stack outside its entry ⚖ | policy-enforce | an oracle dispatcher's session; the judge lists | 200 | [] |
| an unknown task is an empty list | policy-enforce | loop admits; the judge lists task nope | 200 | [] |
| a list without a bearer, under observe, is served and counted ⚖ | policy-default | loop admits; list with no bearer | 200 | the row; list/absent + 1 |
| no task is 400 malformed-body | policy-enforce | the judge GETs /sessions | 400 | malformed-body |
| a list without a bearer, under enforce | policy-enforce | GET /sessions?task= with no bearer | 401 | caller-unauthenticated; list/absent + 1 |

One TokenReview path; the policy shape; the log: see the spec page's tables (one test each).
"""

from __future__ import annotations

import copy
import json
import logging

import httpx
import pytest

from agent_gateway.app import create_app
from agent_gateway.config import Policy, PolicyError
from agent_gateway.pull import POD_NAME_EXTRA, KubeTokenReviews, Review

from .conftest import (
    POLICY_FIXTURE,
    ObservedAsyncClient,
    check,
    err,
    given,
    quiet,
    rule,
    then,
    then_eq,
    when,
    world,
)

pytestmark = rule("GW-SESSIONS-AUTH")

ISLAND = POLICY_FIXTURE.parent.parent.parent
DEPLOYED_POLICY = ISLAND.parent / "argocd" / "resources" / "agent-gateway" / "policy.json"
ENFORCE_POLICY = POLICY_FIXTURE.parent / "policy-enforce.json"

LOOP = "system:serviceaccount:platform-agents:agentstack-loop"
SPECS = "system:serviceaccount:agent-coordinator:agent-coordinator"   # the fixture world's specs reviewer
DEPLOYED_SPECS = "system:serviceaccount:agent-coordinator:specs-review"   # the deployed tick's own SA (#2685)
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
BIND = {"namespace": "platform-agents", "serviceaccount": "agentstack-worker", "pod": "fixer-1"}
TASK = "homelab-2588-r1"
WORKER = {"stack": "platform", "role": "worker", "task": TASK, "round": 1, "bind": BIND}
REVIEWER = {"stack": "platform", "role": "reviewer", "task": TASK, "round": 0}   # the specs reviewer's unbound body


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
    if presented in (None, "no bearer", "(the review raises)"):
        return {} if presented in (None, "no bearer") else {"authorization": "Bearer fake-caller-token-review-raises"}
    return {"authorization": f"Bearer {TOKENS[presented]}"}


async def unauth(gw, route: str, reason: str) -> float:
    with quiet():
        text = (await gw.get("/metrics")).text
    series = f'gateway_control_plane_unauthenticated_total{{route="{route}",reason="{reason}"}}'
    for line in text.splitlines():
        if line.startswith(series + " "):
            return float(line.split()[-1])
    raise AssertionError(f"{series} not rendered")


async def admitted(gw, presented: str | None, body: dict | None = None) -> dict:
    """Given: an admitted session (arrange — muted, one summary line in the step name)."""
    with quiet():
        r = await gw.post("/sessions", json=body or WORKER, headers=as_(presented))
    assert r.status_code == 200 and r.json()["decision"] == "dispatch", r.text
    return r.json()


# -- who may call ---------------------------------------------------------------------------------

WHO_ROWS = [
    ("the platform loop admits a bound platform worker", "policy-enforce", "the platform loop", 200, "—", None),
    ("no bearer, under enforce", "policy-enforce", "no bearer", 401, "caller-unauthenticated", "absent"),
    ("a token the API does not authenticate, under enforce", "policy-enforce", "unauthenticated", 401, "caller-unauthenticated", "invalid"),
    ("a token for another audience, under enforce", "policy-enforce", "the kube API audience", 401, "caller-unauthenticated", "invalid"),
    ("the TokenReview API fails, under enforce", "policy-enforce", "(the review raises)", 503, "tokenreview-transient", "review-transient"),
    ("no bearer, under observe, is admitted and counted ⚖", "policy-default", "no bearer", 200, "—", "absent"),
    ("an invalid token, under observe, is admitted and counted", "policy-default", "unauthenticated", 200, "—", "invalid"),
    ("a review the API cannot answer, under observe, is admitted and counted ⚖", "policy-default", "(the review raises)", 200, "—", "review-transient"),
    ("an unlisted ServiceAccount, under enforce", "policy-enforce", "an unlisted ServiceAccount", 403, "caller-unknown", None),
    ("an unlisted ServiceAccount is refused under observe too ⚖", "policy-default", "an unlisted ServiceAccount", 403, "caller-unknown", None),
]


@pytest.mark.parametrize(("world_name", "presented", "status", "code", "reason"), [r[1:] for r in WHO_ROWS], ids=[r[0] for r in WHO_ROWS])
async def test_who_may_call(gws, reviews, store, world_name, presented, status, code, reason):
    world(world_name)
    gw = gws[world_name]
    with given(f"the caller presents {presented}" + (" — the fake TokenReview raises" if presented == "(the review raises)" else "")):
        reviews.transient = presented == "(the review raises)"
        before = {r: await unauth(gw, "admit", r) for r in ("absent", "invalid", "review-transient")}
    with when(f"POST /sessions (platform worker, bind {BIND['namespace']}/{BIND['serviceaccount']}) presenting {presented}"):
        r = await gw.post("/sessions", json=WORKER, headers=as_(presented))
    then_eq("status", r.status_code, status)
    then_eq("code", err(r) if r.status_code >= 400 else "—", code, claim=f"error code = {code}")
    if status == 503:
        then_eq("retry-after", r.headers.get("retry-after"), "5", claim="status 503 carries retry-after = 5")
    if status == 200:
        want = LOOP if presented == "the platform loop" else None
        with then(f"the row's caller = {want}"):
            check("caller", store.get_session(r.json()["session"]["id"]).caller, want)
    with then(f"gateway_control_plane_unauthenticated_total{{route=admit}}: reason={reason} + 1, every other reason + 0" if reason
              else "gateway_control_plane_unauthenticated_total{route=admit}: reason=none — every reason + 0 (the caller was identified)"):
        after = {k: await unauth(gw, "admit", k) for k in before}
        check("admit increments", {k: after[k] - before[k] for k in before},
              {k: (1.0 if k == reason else 0.0) for k in before})


async def test_check_precedes_body(enforce_gw):
    """row: the caller check precedes the body ⚖"""
    world("policy-enforce")
    with when("POST /sessions with no bearer and a body that is not JSON"):
        r = await enforce_gw.post("/sessions", content=b"not json", headers={"content-type": "application/json"})
    then_eq("status", r.status_code, 401)
    then_eq("code", err(r), "caller-unauthenticated", claim="error code = caller-unauthenticated (not malformed-body)")


# -- what a caller may ask for --------------------------------------------------------------------

ASK_ROWS = [
    ("a stack outside the caller's entry", "the platform loop",
     {**WORKER, "stack": "oracle", "bind": {"namespace": "platform-agents", "serviceaccount": "agentstack-worker"}}, 403, "caller-stack-denied"),
    ("a role outside the caller's entry", "the platform loop", {**WORKER, "role": "reviewer"}, 403, "caller-role-denied"),
    ("the entry canary's role is inside the dispatcher's entry", "the platform loop",
     {"stack": "platform", "role": "prober", "task": "canary-deepseek-v4-1-flash-atlas-cloud-fp8", "round": 0}, 200, "—"),
    ("a bind namespace outside the caller's entry", "the platform loop",
     {**WORKER, "bind": {"namespace": "oracle-agents", "serviceaccount": "agentstack-worker"}}, 403, "caller-bind-denied"),
    ("a caller with no bind namespaces may not bind", "the specs reviewer",
     {**WORKER, "role": "reviewer", "bind": {"namespace": "platform-agents", "serviceaccount": "agentstack-worker"}}, 403, "caller-bind-denied"),
    ("an unbound admission needs no bind namespace", "the specs reviewer",
     {"stack": "platform", "role": "reviewer", "task": "homelab-2640-specs", "round": 0}, 200, "—"),
    ("a known caller's malformed body is still 400", "the platform loop",
     {k: v for k, v in WORKER.items() if k != "task"}, 400, "malformed-body"),
]


@pytest.mark.parametrize(("presented", "body", "status", "code"), [r[1:] for r in ASK_ROWS], ids=[r[0] for r in ASK_ROWS])
async def test_what_a_caller_may_ask(gw, presented, body, status, code):
    world()
    with when(f"POST /sessions body {body} presenting {presented}"):
        r = await gw.post("/sessions", json=body, headers=as_(presented))
    then_eq("status", r.status_code, status)
    then_eq("code", err(r) if r.status_code >= 400 else "—", code, claim=f"error code = {code}")
    if status == 200:
        with then("the dispatch carries session.token and env (GW-SESSIONS-ENV)"):
            doc = r.json()
            check("(token, env)", ("token" in doc["session"], "env" in doc), (True, True))


# -- lookup and release ---------------------------------------------------------------------------

OWNER_ROWS = [
    ("the admitting caller reads its session", "policy-enforce", "the platform loop", "GET", "the platform loop", 200, "—"),
    ("the admitting caller releases its session", "policy-enforce", "the platform loop", "DELETE", "the platform loop", 200, "—"),
    ("another listed caller may not read it", "policy-enforce", "the platform loop", "GET", "the specs reviewer", 403, "caller-not-owner"),
    ("another listed caller may not release it", "policy-enforce", "the platform loop", "DELETE", "the specs reviewer", 403, "caller-not-owner"),
    ("a release without a bearer, under enforce", "policy-enforce", "the platform loop", "DELETE", "no bearer", 401, "caller-unauthenticated"),
    ("a lookup without a bearer, under observe, is served and counted", "policy-default", "the platform loop", "GET", "no bearer", 200, "—"),
    ("a session admitted with no caller is released by any listed caller ⚖", "policy-default", "no bearer", "DELETE", "the specs reviewer", 200, "—"),
]


@pytest.mark.parametrize(("world_name", "admitter", "method", "presented", "status", "code"), [r[1:] for r in OWNER_ROWS], ids=[r[0] for r in OWNER_ROWS])
async def test_lookup_and_release(gws, world_name, admitter, method, presented, status, code):
    world(world_name)
    gw = gws[world_name]
    route = "lookup" if method == "GET" else "release"
    with given(f"a session admitted by {admitter}"):
        sid = (await admitted(gw, admitter))["session"]["id"]
        before = await unauth(gw, route, "absent")
    with when(f"{method} /sessions/{sid} presenting {presented}"):
        r = await gw.request(method, f"/sessions/{sid}", headers=as_(presented))
    then_eq("status", r.status_code, status)
    then_eq("code", err(r) if r.status_code >= 400 else "—", code, claim=f"error code = {code}")
    if status == 200 and method == "GET":
        with then(f"the row's caller = {LOOP}"):
            check("caller", r.json()["caller"], LOOP)
    if status == 200 and method == "DELETE":
        with then("released_at is set"):
            check("released_at set", bool(r.json().get("released_at")), True)
    if code == "caller-not-owner" and method == "DELETE":
        with then("the session stays active: GET by its owner shows released_at = null"):
            with quiet():
                row = (await gw.get(f"/sessions/{sid}", headers=as_(admitter))).json()
            check("released_at", row["released_at"], None)
    if presented == "no bearer":
        with then(f"{route}/absent moved by 1"):
            check(f"{route}/absent increment", await unauth(gw, route, "absent") - before, 1.0)


UNKNOWN_ROWS = [
    ("an unknown id is 404 only after the caller check ⚖", "the platform loop", 404, "session-not-found"),
    ("an unknown id without a bearer, under enforce ⚖", "no bearer", 401, "caller-unauthenticated"),
]


@pytest.mark.parametrize(("presented", "status", "code"), [r[1:] for r in UNKNOWN_ROWS], ids=[r[0] for r in UNKNOWN_ROWS])
async def test_unknown_id(enforce_gw, presented, status, code):
    world("policy-enforce")
    with when(f"GET /sessions/nope presenting {presented}"):
        r = await enforce_gw.get("/sessions/nope", headers=as_(presented))
    then_eq("status", r.status_code, status)
    then_eq("code", err(r), code, claim=f"error code = {code}")


# -- a judge finds a task's sessions ---------------------------------------------------------------

LIST_ROWS = [
    ("the judge lists a task two callers admitted", "policy-enforce", "the platform loop (released) + the specs reviewer", "the judge", TASK,
     [(LOOP, "released"), (SPECS, "active")]),
    ("the admitting caller lists only its own", "policy-enforce", "the platform loop + the specs reviewer", "the platform loop", TASK,
     [(LOOP, "active")]),
    ("another listed caller sees an empty list, never a 403", "policy-enforce", "the platform loop", "the specs reviewer", TASK, []),
    ("the judge lists a task of a stack outside its entry ⚖", "policy-enforce", "an oracle dispatcher", "the judge", TASK, []),
    ("an unknown task is an empty list", "policy-enforce", "the platform loop", "the judge", "nope", []),
    ("a list without a bearer, under observe, is served and counted ⚖", "policy-default", "the platform loop", "no bearer", TASK, [(LOOP, "active")]),
]


async def _task_sessions(gw, store, clock, admitted_by: str) -> None:
    """Given: the task's sessions, one per named admitter, one clock second apart (created_at
    orders the list); `(released)` = the admitter DELETEs its own; an oracle dispatcher's session
    is stored directly (no fixture caller may admit stack oracle), recorded as that SA's."""
    for who in admitted_by.split(" + "):
        if who == "an oracle dispatcher":
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


@pytest.mark.parametrize(("world_name", "admitted_by", "presented", "task", "expected"), [r[1:] for r in LIST_ROWS], ids=[r[0] for r in LIST_ROWS])
async def test_judge_lists_a_task(gws, store, clock, world_name, admitted_by, presented, task, expected):
    world(world_name)
    gw = gws[world_name]
    with given(f"task {TASK} has sessions admitted by {admitted_by}, oldest first"):
        await _task_sessions(gw, store, clock, admitted_by)
        before = await unauth(gw, "list", "absent")
    with when(f"GET /sessions?task={task} presenting {presented}"):
        r = await gw.get("/sessions", params={"task": task}, headers=as_(presented))
    then_eq("status", r.status_code, 200)
    with then(f"the rows (caller, state), oldest first = {expected} — every row the GET /sessions/{{id}} shape incl. outcome"):
        rows = r.json()["sessions"]
        check("(caller, state)", [(row["caller"], row["state"]) for row in rows], expected)
        assert all({"task", "state", "outcome", "caller"} <= set(row) and "token" not in row for row in rows), rows
    if presented == "no bearer":
        with then("list/absent moved by 1"):
            check("list/absent increment", await unauth(gw, "list", "absent") - before, 1.0)


LIST_REFUSED_ROWS = [
    ("no task is 400 malformed-body", "the judge", {}, 400, "malformed-body", None),
    ("a list without a bearer, under enforce", "no bearer", {"task": TASK}, 401, "caller-unauthenticated", "absent"),
]


@pytest.mark.parametrize(("presented", "query", "status", "code", "reason"), [r[1:] for r in LIST_REFUSED_ROWS], ids=[r[0] for r in LIST_REFUSED_ROWS])
async def test_list_refused(enforce_gw, presented, query, status, code, reason):
    world("policy-enforce")
    with given("no session is needed: the check refuses before any row is read"):
        before = await unauth(enforce_gw, "list", "absent")
    with when(f"GET /sessions with query {query} presenting {presented}"):
        r = await enforce_gw.get("/sessions", params=query, headers=as_(presented))
    then_eq("status", r.status_code, status)
    then_eq("code", err(r), code, claim=f"error code = {code}")
    with then(f"list/absent moved by {1 if reason else 0} (reason = {reason})"):
        check("list/absent increment", await unauth(enforce_gw, "list", "absent") - before, 1.0 if reason else 0.0)


# -- one TokenReview path, and the pull stays the pod's -------------------------------------------

async def test_same_reviewer_as_pull(enforce_gw, enforce_app, tmp_path):
    """row: the caller's token is reviewed by the pull's reviewer, for audience agent-gateway"""
    world("policy-enforce")
    seen: list[dict] = []
    auth_headers: list[str] = []

    def api(request: httpx.Request) -> httpx.Response:
        seen.append(json.loads(request.content))
        auth_headers.append(request.headers.get("authorization", ""))
        return httpx.Response(201, json={"status": {"authenticated": True, "audiences": ["agent-gateway"],
                                                    "user": {"username": LOOP}}})

    with given("the gateway's reviewer is the kube one (KubeTokenReviews — the pull's) on a fake API answering the platform loop"):
        (tmp_path / "token").write_text("gateway-own-sa-token-fixture")
        kube = KubeTokenReviews(sa_dir=str(tmp_path))
        kube._client = httpx.AsyncClient(transport=httpx.MockTransport(api), base_url="https://kubernetes.default.svc")
        enforce_app.state.sessions.reviewer = kube
    with when("POST /sessions (platform worker + bind) with the caller's bearer"):
        r = await enforce_gw.post("/sessions", json=WORKER, headers=as_("the platform loop"))
    then_eq("status", r.status_code, 200)
    with then("the API received exactly one TokenReview, spec.audiences [agent-gateway], sent with the gateway's own token"):
        check("(reviews, audiences, own bearer)", (len(seen), [b["spec"]["audiences"] for b in seen], auth_headers),
              (1, [["agent-gateway"]], ["Bearer gateway-own-sa-token-fixture"]))


async def test_pull_not_caller_checked(enforce_gw, reviews):
    """row: the env pull is not caller-checked"""
    world("policy-enforce")
    pod_token = "fake-projected-sa-token-for-pod-fixer-1"
    with given("the platform loop admitted a bound worker; the pod's token reviews as the bind (not a caller)"):
        reviews.tokens[pod_token] = Review(True, "system:serviceaccount:platform-agents:agentstack-worker", ("agent-gateway",),
                                           {POD_NAME_EXTRA: ("fixer-1",)})
        sid = (await admitted(enforce_gw, "the platform loop"))["session"]["id"]
    with when(f"POST /sessions/{sid}/env with the bound pod's token"):
        r = await enforce_gw.post(f"/sessions/{sid}/env", headers={"authorization": f"Bearer {pod_token}"})
    then_eq("status", r.status_code, 200)
    with then("the answer is {id, expires_at, env}"):
        check("keys", sorted(r.json()), ["env", "expires_at", "id"])


# -- the policy shape ------------------------------------------------------------------------------

def _raw() -> dict:
    return json.loads(POLICY_FIXTURE.read_text(encoding="utf-8"))


def _mutate(kind: str) -> dict:
    d = copy.deepcopy(_raw())
    if kind == "wildcard":
        d["callers"]["system:serviceaccount:platform-agents:*"] = d["callers"].pop(LOOP)
    elif kind == "unknown stack":
        d["callers"][LOOP]["stacks"] = ["nope"]
    elif kind == "missing key":
        del d["callers"][LOOP]["bind_namespaces"]
    elif kind == "no knob":
        del d["control_plane_auth"]
    elif kind == "no callers":
        del d["callers"]
    return d


SHAPE_ROWS = [
    ("a caller key that is not a ServiceAccount username refuses the load", "wildcard"),
    ("a caller naming a stack the policy does not hold refuses the load", "unknown stack"),
    ("a caller entry missing a key refuses the load", "missing key"),
    ("a policy without control_plane_auth refuses the load ⚖", "no knob"),
    ("a policy without callers refuses the load ⚖", "no callers"),
]


@pytest.mark.parametrize("kind", [r[1] for r in SHAPE_ROWS], ids=[r[0] for r in SHAPE_ROWS])
async def test_policy_shape(kind):
    world()
    d = _mutate(kind)
    with when(f"Policy.from_dict(policy-default with {kind}) — callers: {sorted(d.get('callers', {}))}, control_plane_auth: {d.get('control_plane_auth')}"):
        try:
            Policy.from_dict(d)
            got = "loaded"
        except PolicyError as e:
            got = f"PolicyError: {e}"
    with then("the load refuses with PolicyError"):
        check("refused", got.startswith("PolicyError"), True)


async def test_deployed_callers():
    """row: the deployed callers are today's two dispatchers and the judge, under enforce"""
    world(note="the DEPLOYED policy is read, not the world's")
    with when(f"Policy.from_dict({DEPLOYED_POLICY.relative_to(ISLAND.parent)})"):
        p = Policy.from_dict(json.loads(DEPLOYED_POLICY.read_text(encoding="utf-8")))
        got = {k: {"stacks": sorted(c.stacks), "roles": sorted(c.roles), "bind_namespaces": sorted(c.bind_namespaces), "outcome": c.outcome}
               for k, c in p.callers.items()}
    with then("control_plane_auth = enforce"):
        check("control_plane_auth", p.control_plane_auth, "enforce")
    with then("callers = exactly the platform loop, the specs-review tick and the outcome judge, with today's scopes"):
        check("callers", got, {
            LOOP: {"stacks": ["platform"], "roles": ["prober", "worker"], "bind_namespaces": ["agent-runtime", "homelab", "openrouter-operator"], "outcome": "own"},
            DEPLOYED_SPECS: {"stacks": ["platform"], "roles": ["reviewer", "worker"], "bind_namespaces": [], "outcome": "own"},
            JUDGE: {"stacks": ["platform"], "roles": [], "bind_namespaces": [], "outcome": "any"},
        })


# -- what the log says -----------------------------------------------------------------------------

async def test_dispatch_log_names_caller(enforce_gw, caplog):
    """row: a dispatch line names the caller, never its token"""
    world("policy-enforce")
    caplog.set_level(logging.INFO)
    with when("POST /sessions (platform worker + bind) presenting the platform loop"):
        r = await enforce_gw.post("/sessions", json=WORKER, headers=as_("the platform loop"))
    assert r.status_code == 200, r.text
    lines = [rec.getMessage() for rec in caplog.records if rec.name == "gateway.sessions" and "dispatch id=" in rec.getMessage()]
    with then(f"the dispatch line holds caller={LOOP}"):
        check("caller in line", [f"caller={LOOP}" in line for line in lines], [True])
    with then("no line holds the presented token"):
        check("token in log", any(TOKENS["the platform loop"] in rec.getMessage() for rec in caplog.records), False)


async def test_unauthenticated_log_line(gw, caplog):
    """row: an unauthenticated call is one line naming the route and the reason"""
    world()
    caplog.set_level(logging.INFO)
    with when("POST /sessions (platform worker + bind) with no bearer"):
        r = await gw.post("/sessions", json=WORKER)
    assert r.status_code == 200, r.text
    lines = [rec.getMessage() for rec in caplog.records if rec.name == "gateway.control"]
    with then("exactly one control-plane line: admit unauthenticated (absent), admitted under observe"):
        check("lines", lines, ["control-plane: admit unauthenticated (absent) — ADMITTED under control_plane_auth=observe"])
