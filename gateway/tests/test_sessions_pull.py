"""GW-SESSIONS-PULL — a bound dispatch carries no credential; the bound pod pulls its env once (specs/endpoints/sessions.md).

World policy-default (every ref resolvable); the TokenReview is the fake `StaticTokenReviews`
(the `reviews` fixture), answering each presented token with the status the row states.

The bound dispatch answer:

| description | body | result |
|---|---|---|
| a bound dispatch carries the session's identity, not its credential ⚖ | worker, bind {platform-agents, agentstack-worker, fixer-1} | keys exactly decision, session (id, expires_at), rail, harness, model, env_keys, pull_url, context_tokens; no gws_ in the body |
| env_keys names the opencode env | worker (opencode) + bind | env_keys = [OPENCODE_CONFIG_CONTENT] |
| env_keys names the claude env | reviewer (claude) + bind | env_keys = [ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL] |
| env_keys names the goose env | worker, harness goose, rail openrouter + bind | env_keys = [OPENAI_BASE_URL, OPENAI_API_KEY, GOOSE_PROVIDER, GOOSE_MODEL] |
| pull_url is this gateway's pull path for the session | worker + bind | pull_url = <self>/sessions/<id>/env |
| without bind the dispatch answer is unchanged | worker, no bind | session.token + env; no env_keys, no pull_url |
| a bound session holds no token until its pull | worker + bind, read the DB | token_hash = unminted:<id> |
| a bind without a serviceaccount is malformed | bind {namespace: platform-agents} | 400 malformed-body |
| a bind namespace that is not a DNS label is malformed | bind {namespace: Platform_Agents, serviceaccount: agentstack-worker} | 400 malformed-body |

Who may pull (presented = the fake TokenReview's answer, one change from "the bound identity"):

| description | session | presented | status | code |
|---|---|---|---|---|
| the bound pod's projected token is served | bound to fixer-1 | the bound identity | 200 | — |
| no bearer token | bound to fixer-1 | no bearer | 403 | pull-identity-refused |
| a token the API does not authenticate | bound to fixer-1 | unauthenticated | 403 | pull-identity-refused |
| the bound identity without the gateway audience | bound to fixer-1 | the kube API audience | 403 | pull-identity-refused |
| another ServiceAccount of the bound namespace | bound to fixer-1 | system:serviceaccount:platform-agents:default | 403 | pull-identity-refused |
| the bound ServiceAccount name in another namespace | bound to fixer-1 | system:serviceaccount:oracle-agents:agentstack-worker | 403 | pull-identity-refused |
| another pod of the bound ServiceAccount | bound to fixer-1 | pod-name fixer-2 | 403 | pull-identity-refused |
| a token with no pod binding when the bind names a pod | bound to fixer-1 | no pod-name extra | 403 | pull-identity-refused |
| a bind without a pod admits any pod of its ServiceAccount ⚖ | bound, no pod | pod-name fixer-2 | 200 | — |
| an unbound session refuses every pull ⚖ | unbound | the bound identity | 403 | pull-identity-refused |
| an unknown id | — (POST /sessions/nope/env; no review is made) | the bound identity | 404 | session-not-found |
| the TokenReview API fails | bound to fixer-1 | (the review raises) | 503 | tokenreview-transient |
| the TokenReview API refuses the gateway itself ⚖ | bound to fixer-1 | (the API answers the gateway's review 403) | 503 | tokenreview-transient |

What a pull returns:

| description | sequence | result |
|---|---|---|
| the pull answers the opencode env GW-SESSIONS-ENV would have | worker (opencode) bound -> pull | env keys = env_keys; apiKey a fresh gws_ token; baseURL /openai/v1; model gateway/deepseek-v4.1-flash |
| the pull answers the claude env | reviewer (claude) bound -> pull | ANTHROPIC_AUTH_TOKEN gws_; ANTHROPIC_BASE_URL /anthropic; ANTHROPIC_MODEL sonnet |
| the pull answers the goose env | worker goose/openrouter bound -> pull | OPENAI_API_KEY gws_; OPENAI_BASE_URL /openai/v1; GOOSE_PROVIDER openai; GOOSE_MODEL deepseek/deepseek-v4-flash |
| the pulled token rides the data plane | pull -> POST /openai/v1/chat/completions | 200; requests = 1 |
| the row stores the pulled token's sha256 only | pull, read the DB | token_hash = sha256(token); token not in the dump |

Only once, and in order:

| description | sequence | result |
|---|---|---|
| a second pull by the same pod is refused ⚖ | pull, pull again | 409 env-already-delivered; the first token still served |
| a second pull by another pod is refused by identity first ⚖ | pull, then pod-name fixer-2 | 403 pull-identity-refused |
| a released session is refused as the data plane refuses it | DELETE, then pull | 401 session-released |
| an expired session is refused as the data plane refuses it | clock past expires_at, then pull | 401 session-expired |
| a wrong identity on a released session is refused by identity first ⚖ | DELETE, then a fixer-2 pull | 403 pull-identity-refused (not 401) |
"""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3

import httpx
import pytest

from agent_gateway.pull import POD_NAME_EXTRA, KubeTokenReviews, Review

from .conftest import (
    SELF_URL,
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

pytestmark = rule("GW-SESSIONS-PULL")

TOKEN_RE = re.compile(r"^gws_[A-Za-z0-9_-]{32}$")
NS, SA, POD = "platform-agents", "agentstack-worker", "fixer-1"
BIND = {"namespace": NS, "serviceaccount": SA, "pod": POD}
USER = f"system:serviceaccount:{NS}:{SA}"
# Fixture projected tokens: obviously fake (the JWT-shaped one lives in test_redact.py).
SA_TOKEN = "fake-projected-sa-token-for-pod-fixer-1"


def bound_review(user: str = USER, pod: str | None = POD, audiences=("agent-gateway",), authenticated: bool = True) -> Review:
    return Review(authenticated, user if authenticated else None, tuple(audiences) if authenticated else (),
                  {POD_NAME_EXTRA: (pod,)} if pod else {})


def sa(token: str = SA_TOKEN) -> dict[str, str]:
    return {"authorization": f"Bearer {token}"}


async def pull(gw, sid: str, headers: dict | None = None):
    return await gw.post(f"/sessions/{sid}/env", headers=sa() if headers is None else headers)


# -- the bound dispatch answer --------------------------------------------------------------------

async def test_bound_answer_has_no_credential(gw):
    """row: a bound dispatch carries the session's identity, not its credential ⚖"""
    world()
    with when(f"POST /sessions (platform worker) with bind {BIND}"):
        r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "t", "bind": BIND})
    doc = r.json()
    with then("status 200, keys exactly decision, session, rail, harness, model, env_keys, pull_url, context_tokens"):
        check("(status, keys)", (r.status_code, sorted(doc)),
              (200, sorted(["decision", "session", "rail", "harness", "model", "env_keys", "pull_url", "context_tokens"])))
    with then("session carries exactly id + expires_at (no token)"):
        check("session keys", sorted(doc["session"]), ["expires_at", "id"])
    with then("no gws_ anywhere in the body"):
        check("gws_ in body", "gws_" in r.text, False)


ENV_KEY_ROWS = [
    ("env_keys names the opencode env", {"role": "worker", "harness": "opencode"}, ["OPENCODE_CONFIG_CONTENT"]),
    ("env_keys names the claude env", {"role": "reviewer", "harness": "claude"}, ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL"]),
    ("env_keys names the goose env", {"role": "worker", "harness": "goose", "rail": "openrouter"},
     ["OPENAI_BASE_URL", "OPENAI_API_KEY", "GOOSE_PROVIDER", "GOOSE_MODEL"]),
]


@pytest.mark.parametrize(("req", "keys"), [r[1:] for r in ENV_KEY_ROWS], ids=[r[0] for r in ENV_KEY_ROWS])
async def test_env_keys(gw, req, keys):
    world()
    with when(f"POST /sessions body {req} + bind → dispatch"):
        doc = await open_session(gw, **req, bind=BIND)
    with then(f"env_keys = {keys}"):
        check("env_keys", doc["env_keys"], keys)


async def test_pull_url(gw):
    """row: pull_url is this gateway's pull path for the session"""
    world()
    with when("POST /sessions (platform worker) + bind → dispatch"):
        doc = await open_session(gw, bind=BIND)
    with then("pull_url = <self>/sessions/<id>/env"):
        check("pull_url", doc["pull_url"], f"{SELF_URL}/sessions/{doc['session']['id']}/env")


async def test_unbound_answer_unchanged(gw):
    """row: without bind the dispatch answer is unchanged"""
    world()
    with when("POST /sessions (platform worker), no bind → dispatch"):
        doc = await open_session(gw)
    with then("session.token is a gws_ token and env is present (GW-SESSIONS-ENV)"):
        check("(token shape, env keys)", (bool(TOKEN_RE.match(doc["session"]["token"])), sorted(doc["env"])),
              (True, ["OPENCODE_CONFIG_CONTENT"]))
    with then("no env_keys, no pull_url"):
        check("(env_keys, pull_url) present", ("env_keys" in doc, "pull_url" in doc), (False, False))


async def test_bound_row_unminted(gw, store):
    """row: a bound session holds no token until its pull"""
    world()
    with when("POST /sessions (platform worker) + bind → dispatch"):
        doc = await open_session(gw, bind=BIND)
    sid = doc["session"]["id"]
    with then(f"the row's token_hash = unminted:{sid}, and its bind is recorded"):
        row = store.get_session(sid)
        check("(token_hash, bind)", (row.token_hash, row.bind_namespace, row.bind_serviceaccount, row.bind_pod),
              (f"unminted:{sid}", NS, SA, POD))


MALFORMED_ROWS = [
    ("a bind without a serviceaccount is malformed", {"namespace": NS}),
    ("a bind namespace that is not a DNS label is malformed", {"namespace": "Platform_Agents", "serviceaccount": SA}),
]


@pytest.mark.parametrize("bind", [r[1] for r in MALFORMED_ROWS], ids=[r[0] for r in MALFORMED_ROWS])
async def test_malformed_bind(gw, bind):
    world()
    with when(f"POST /sessions (platform worker) with bind {bind}"):
        r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "t", "bind": bind})
    with then("status 400 with code malformed-body"):
        check("(status, code)", (r.status_code, err(r)), (400, "malformed-body"))


# -- who may pull ---------------------------------------------------------------------------------

# The fake TokenReview's answer per presented-token kind (the spec table's left column).
REVIEWS = {
    "the bound identity": bound_review(),
    "no bearer": bound_review(),
    "unauthenticated": bound_review(authenticated=False),
    "the kube API audience": bound_review(audiences=("https://kubernetes.default.svc",)),
    f"system:serviceaccount:{NS}:default": bound_review(user=f"system:serviceaccount:{NS}:default"),
    f"system:serviceaccount:oracle-agents:{SA}": bound_review(user=f"system:serviceaccount:oracle-agents:{SA}"),
    "pod-name fixer-2": bound_review(pod="fixer-2"),
    "no pod-name extra": bound_review(pod=None),
}
BINDS = {"bound to fixer-1": BIND, "bound, no pod": {"namespace": NS, "serviceaccount": SA}, "unbound": None}

IDENTITY_ROWS = [
    ("the bound pod's projected token is served", "bound to fixer-1", "the bound identity", 200, "—"),
    ("no bearer token", "bound to fixer-1", "no bearer", 403, "pull-identity-refused"),
    ("a token the API does not authenticate", "bound to fixer-1", "unauthenticated", 403, "pull-identity-refused"),
    ("the bound identity without the gateway audience", "bound to fixer-1", "the kube API audience", 403, "pull-identity-refused"),
    ("another ServiceAccount of the bound namespace", "bound to fixer-1", f"system:serviceaccount:{NS}:default", 403, "pull-identity-refused"),
    ("the bound ServiceAccount name in another namespace", "bound to fixer-1", f"system:serviceaccount:oracle-agents:{SA}", 403, "pull-identity-refused"),
    ("another pod of the bound ServiceAccount", "bound to fixer-1", "pod-name fixer-2", 403, "pull-identity-refused"),
    ("a token with no pod binding when the bind names a pod", "bound to fixer-1", "no pod-name extra", 403, "pull-identity-refused"),
    ("a bind without a pod admits any pod of its ServiceAccount ⚖", "bound, no pod", "pod-name fixer-2", 200, "—"),
    ("an unbound session refuses every pull ⚖", "unbound", "the bound identity", 403, "pull-identity-refused"),
]


@pytest.mark.parametrize(("session", "presented", "status", "code"), [r[1:] for r in IDENTITY_ROWS], ids=[r[0] for r in IDENTITY_ROWS])
async def test_identity(gw, reviews, session, presented, status, code):
    world()
    review, bind = REVIEWS[presented], BINDS[session]
    with given(f"session {session}; presented {presented} — the fake TokenReview answers authenticated={review.authenticated} "
               f"user={review.username} audiences={list(review.audiences)} pod-name={list(review.extra.get(POD_NAME_EXTRA, ()))}"):
        reviews.tokens[SA_TOKEN] = review
        doc = await open_session(gw, **({"bind": bind} if bind else {}))
    headers = {} if presented == "no bearer" else sa()
    with when(f"POST /sessions/{doc['session']['id']}/env presenting {presented}"):
        r = await pull(gw, doc["session"]["id"], headers)
    then_eq("status", r.status_code, status)
    then_eq("code", err(r) if r.status_code >= 400 else "—", code, claim=f"error code = {code}")
    with then("the answer carries no gws_ token" if code != "—" else "the answer is {id, expires_at, env}"):
        if code != "—":
            check("gws_ in body", "gws_" in r.text, False)
        else:
            check("keys", sorted(r.json()), ["env", "expires_at", "id"])


async def test_unknown_id(gw, reviews):
    """row: an unknown id"""
    world()
    with when("POST /sessions/nope/env with a bearer ServiceAccount token"):
        r = await pull(gw, "nope")
    then_eq("status", r.status_code, 404)
    then_eq("code", err(r), "session-not-found", claim="error code = session-not-found")
    with then("no TokenReview was made"):
        check("reviews made", len(reviews.calls), 0)


async def test_tokenreview_transient(gw, reviews):
    """row: the TokenReview API fails"""
    world()
    with given("a bound session; the fake TokenReview raises (the API is away)"):
        doc = await open_session(gw, bind=BIND)
        reviews.transient = True
    with when(f"POST /sessions/{doc['session']['id']}/env"):
        r = await pull(gw, doc["session"]["id"])
    then_eq("status", r.status_code, 503)
    then_eq("code", err(r), "tokenreview-transient", claim="error code = tokenreview-transient")
    then_eq("retry-after", r.headers.get("retry-after"), "5", claim="status 503 carries retry-after = 5")
    with then("the review asked for audience agent-gateway"):
        check("audiences", reviews.calls, [["agent-gateway"]])


# -- what a pull returns, and only once -----------------------------------------------------------

async def _bound_and_pulled(gw, reviews, **body):
    reviews.tokens[SA_TOKEN] = bound_review()
    doc = await open_session(gw, **body, bind=BIND)
    r = await pull(gw, doc["session"]["id"])
    assert r.status_code == 200, r.text
    return doc, r.json()


async def test_pull_opencode_env(gw, reviews):
    """row: the pull answers the opencode env GW-SESSIONS-ENV would have"""
    world()
    with given("a bound opencode session (platform worker); the fake TokenReview answers the bound identity"):
        reviews.tokens[SA_TOKEN] = bound_review()
        doc = await open_session(gw, bind=BIND)
    with when(f"POST /sessions/{doc['session']['id']}/env with the bound pod's token"):
        r = await pull(gw, doc["session"]["id"])
    env = r.json()["env"]
    cfg = json.loads(env["OPENCODE_CONFIG_CONTENT"])
    with then("env keys = the dispatch's env_keys"):
        check("env keys", list(env), doc["env_keys"])
    with then("the provider apiKey is a fresh gws_ token"):
        check("apiKey shape", bool(TOKEN_RE.match(cfg["provider"]["gateway"]["options"]["apiKey"])), True)
    with then("baseURL = <self>/openai/v1, model = gateway/deepseek-v4.1-flash"):
        check("(baseURL, model)", (cfg["provider"]["gateway"]["options"]["baseURL"], cfg["model"]),
              (f"{SELF_URL}/openai/v1", "gateway/deepseek-v4.1-flash"))


async def test_pull_claude_env(gw, reviews):
    """row: the pull answers the claude env"""
    world()
    with given("a bound claude session (platform reviewer); the fake TokenReview answers the bound identity"):
        reviews.tokens[SA_TOKEN] = bound_review()
        doc = await open_session(gw, role="reviewer", harness="claude", bind=BIND)
    with when(f"POST /sessions/{doc['session']['id']}/env with the bound pod's token"):
        env = (await pull(gw, doc["session"]["id"])).json()["env"]
    with then("ANTHROPIC_AUTH_TOKEN is a fresh gws_ token"):
        check("token shape", bool(TOKEN_RE.match(env["ANTHROPIC_AUTH_TOKEN"])), True)
    with then("ANTHROPIC_BASE_URL = <self>/anthropic, ANTHROPIC_MODEL = sonnet"):
        check("(base, model)", (env["ANTHROPIC_BASE_URL"], env["ANTHROPIC_MODEL"]), (f"{SELF_URL}/anthropic", "sonnet"))


async def test_pull_goose_env(gw, reviews):
    """row: the pull answers the goose env"""
    world()
    with given("a bound goose session on openrouter (platform worker); the fake TokenReview answers the bound identity"):
        reviews.tokens[SA_TOKEN] = bound_review()
        doc = await open_session(gw, harness="goose", rail="openrouter", bind=BIND)
    with when(f"POST /sessions/{doc['session']['id']}/env with the bound pod's token"):
        env = (await pull(gw, doc["session"]["id"])).json()["env"]
    with then("OPENAI_API_KEY is a fresh gws_ token"):
        check("token shape", bool(TOKEN_RE.match(env["OPENAI_API_KEY"])), True)
    with then("OPENAI_BASE_URL, GOOSE_PROVIDER, GOOSE_MODEL as GW-SESSIONS-ENV"):
        check("(base, provider, model)", (env["OPENAI_BASE_URL"], env["GOOSE_PROVIDER"], env["GOOSE_MODEL"]),
              (f"{SELF_URL}/openai/v1", "openai", "deepseek/deepseek-v4-flash"))


async def test_pulled_token_on_data_plane(gw, reviews):
    """row: the pulled token rides the data plane"""
    world(upstream="upstream-ok")
    with given("a bound opencode session, pulled by the bound pod"):
        doc, pulled = await _bound_and_pulled(gw, reviews)
        token = json.loads(pulled["env"]["OPENCODE_CONFIG_CONTENT"])["provider"]["gateway"]["options"]["apiKey"]
    with when("POST /openai/v1/chat/completions with the pulled token"):
        r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers={"authorization": f"Bearer {token}"})
    with then("status 200"):
        check("status", r.status_code, 200)
    with then("the row's requests = 1"):
        check("requests", (await gw.get(f"/sessions/{doc['session']['id']}")).json()["requests"], 1)


async def test_pulled_token_hash_only(gw, reviews, settings, store):
    """row: the row stores the pulled token's sha256 only"""
    world()
    with given("a bound opencode session"):
        reviews.tokens[SA_TOKEN] = bound_review()
        doc = await open_session(gw, bind=BIND)
    with when(f"POST /sessions/{doc['session']['id']}/env with the bound pod's token"):
        env = (await pull(gw, doc["session"]["id"])).json()["env"]
    token = json.loads(env["OPENCODE_CONFIG_CONTENT"])["provider"]["gateway"]["options"]["apiKey"]
    with then("the row's token_hash = sha256(token)"):
        check("token_hash", store.get_session(doc["session"]["id"]).token_hash, hashlib.sha256(token.encode()).hexdigest())
    with then("the token appears nowhere in the sqlite dump"):
        check("token in dump", token in "\n".join(sqlite3.connect(settings.db_path).iterdump()), False)


async def test_second_pull_same_pod(gw, reviews):
    """row: a second pull by the same pod is refused ⚖"""
    world(upstream="upstream-ok")
    with given("a bound opencode session, pulled once by the bound pod"):
        with quiet():
            doc, pulled = await _bound_and_pulled(gw, reviews)
        token = json.loads(pulled["env"]["OPENCODE_CONFIG_CONTENT"])["provider"]["gateway"]["options"]["apiKey"]
        attach_json("arranged: bound dispatch + first pull", {"session": doc["session"]["id"], "first pull": 200, "env keys": list(pulled["env"])})
    with when(f"POST /sessions/{doc['session']['id']}/env again with the same pod's token"):
        r = await pull(gw, doc["session"]["id"])
    with then("status 409 with code env-already-delivered, no gws_ in the body"):
        check("(status, code, gws_ in body)", (r.status_code, err(r), "gws_" in r.text), (409, "env-already-delivered", False))
    with then("the first token is still served on the data plane"):
        r2 = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers={"authorization": f"Bearer {token}"})
        check("status", r2.status_code, 200)


async def test_second_pull_other_pod(gw, reviews):
    """row: a second pull by another pod is refused by identity first ⚖"""
    world()
    other = "fake-projected-sa-token-for-pod-fixer-2"
    with given("a bound opencode session, pulled once; a second token reviews as the bound SA on pod fixer-2"):
        doc, _ = await _bound_and_pulled(gw, reviews)
        reviews.tokens[other] = bound_review(pod="fixer-2")
    with when(f"POST /sessions/{doc['session']['id']}/env with the fixer-2 token"):
        r = await pull(gw, doc["session"]["id"], sa(other))
    with then("status 403 with code pull-identity-refused (not 409)"):
        check("(status, code)", (r.status_code, err(r)), (403, "pull-identity-refused"))


async def test_released_session_pull(gw, reviews):
    """row: a released session is refused as the data plane refuses it"""
    world()
    with given("a bound session, released by DELETE before any pull"):
        reviews.tokens[SA_TOKEN] = bound_review()
        doc = await open_session(gw, bind=BIND)
        await gw.delete(f"/sessions/{doc['session']['id']}")
    with when(f"POST /sessions/{doc['session']['id']}/env with the bound pod's token"):
        r = await pull(gw, doc["session"]["id"])
    with then("status 401 with code session-released"):
        check("(status, code)", (r.status_code, err(r)), (401, "session-released"))


async def test_expired_session_pull(gw, reviews, policy, clock):
    """row: an expired session is refused as the data plane refuses it"""
    world()
    with given(f"a bound session, then the clock passes expires_at (+{policy.session_ttl_s + 1} s)"):
        reviews.tokens[SA_TOKEN] = bound_review()
        doc = await open_session(gw, bind=BIND)
        clock.advance(policy.session_ttl_s + 1)
    with when(f"POST /sessions/{doc['session']['id']}/env with the bound pod's token"):
        r = await pull(gw, doc["session"]["id"])
    with then("status 401 with code session-expired"):
        check("(status, code)", (r.status_code, err(r)), (401, "session-expired"))


async def test_tokenreview_refuses_gateway(gw, app, tmp_path):
    """row: the TokenReview API refuses the gateway itself ⚖"""
    world()
    seen: list[dict] = []

    def api(request: httpx.Request) -> httpx.Response:
        seen.append(json.loads(request.content))
        return httpx.Response(403, json={"kind": "Status", "reason": "Forbidden", "code": 403})

    with given("a bound session; the gateway's reviewer is the kube one, whose API answers its TokenReview 403 (RBAC missing)"):
        (tmp_path / "token").write_text("gateway-own-sa-token-fixture")
        kube = KubeTokenReviews(sa_dir=str(tmp_path))
        kube._client = httpx.AsyncClient(transport=httpx.MockTransport(api), base_url="https://kubernetes.default.svc")
        app.state.sessions.reviewer = kube
        doc = await open_session(gw, bind=BIND)
    with when(f"POST /sessions/{doc['session']['id']}/env with the bound pod's token"):
        r = await pull(gw, doc["session"]["id"])
    then_eq("status", r.status_code, 503)
    then_eq("code", err(r), "tokenreview-transient", claim="error code = tokenreview-transient")
    with then("the review the gateway sent asked for audience agent-gateway"):
        check("spec.audiences", [b["spec"]["audiences"] for b in seen], [["agent-gateway"]])


async def test_wrong_identity_on_released(gw, reviews):
    """row: a wrong identity on a released session is refused by identity first ⚖"""
    world()
    other = "fake-projected-sa-token-for-pod-fixer-2"
    with given("a bound session, released by DELETE; the presented token reviews as the bound SA on pod fixer-2"):
        reviews.tokens[other] = bound_review(pod="fixer-2")
        doc = await open_session(gw, bind=BIND)
        await gw.delete(f"/sessions/{doc['session']['id']}")
    with when(f"POST /sessions/{doc['session']['id']}/env with the fixer-2 token"):
        r = await pull(gw, doc["session"]["id"], sa(other))
    then_eq("status", r.status_code, 403)
    then_eq("code", err(r), "pull-identity-refused", claim="error code = pull-identity-refused (not session-released)")
