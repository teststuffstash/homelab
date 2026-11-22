"""GW-SESSIONS-PULL — a bound dispatch carries no credential; the bound pod pulls its env once
(specs/endpoints/sessions.md §The session → GW-SESSIONS-PULL). The TokenReview is the fake
`StaticTokenReviews` (the `reviews` fixture), answering each presented token with the status the
row states. Header == argnames, description == id (tests/_rows.py)."""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3

import httpx
import pytest

from agent_gateway.pull import POD_NAME_EXTRA, KubeTokenReviews, Review

from ._rows import DASH, POLICY, body_of, enter_world, expect, inputs
from .conftest import SELF_URL, attach_json, err, given, open_session, quiet, rule, when

pytestmark = rule("GW-SESSIONS-PULL")

TOKEN_RE = re.compile(r"^gws_[A-Za-z0-9_-]{32}$")
NS, SA, POD = "platform-agents", "agentstack-worker", "fixer-1"
BIND = {"namespace": NS, "serviceaccount": SA, "pod": POD}
USER = f"system:serviceaccount:{NS}:{SA}"
SA_TOKEN = "fake-projected-sa-token-for-pod-fixer-1"  # obviously fake (the JWT-shaped one lives in test_redact.py)
FIXER_2 = "fake-projected-sa-token-for-pod-fixer-2"
BOUND = "platform-agents/agentstack-worker/fixer-1"


def bound_review(user: str = USER, pod: str | None = POD, audiences=("agent-gateway",), authenticated: bool = True) -> Review:
    return Review(authenticated, user if authenticated else None, tuple(audiences) if authenticated else (),
                  {POD_NAME_EXTRA: (pod,)} if pod else {})


def sa(token: str = SA_TOKEN) -> dict[str, str]:
    return {"authorization": f"Bearer {token}"}


async def pull(gw, sid: str, headers: dict | None = None):
    return await gw.post(f"/sessions/{sid}/env", headers=sa() if headers is None else headers)


# -- the bound answer -------------------------------------------------------------------------------------
ANSWER_ROWS = [
    pytest.param("policy-default", BOUND, "keys decision, session (id, expires_at), rail, harness, model, env_keys, pull_url, context_tokens, rail_choice; no gws_ in the body",
                 id="a bound dispatch carries the session's identity, not its credential ⚖"),
    pytest.param("policy-default", BOUND, f"{SELF_URL}/sessions/«id»/env", id="pull_url is this gateway's pull path for the session"),
    pytest.param("policy-default", DASH, "session.token a gws_ token; env present; no env_keys, no pull_url", id="without bind the dispatch answer is unchanged"),
    pytest.param("policy-default", BOUND, "token_hash = unminted:«id»; the bind recorded", id="a bound session holds no token until its pull"),
]
KEYS = ["decision", "session", "rail", "harness", "model", "env_keys", "pull_url", "context_tokens", "rail_choice"]


@pytest.mark.parametrize(("world", "bind", "expected_answer"), ANSWER_ROWS)
async def test_the_bound_answer(gw, store, world, bind, expected_answer):
    enter_world(world)
    inputs(bind=bind)
    body = {"stack": "platform", "role": "worker", "task": "t", **({"bind": BIND} if bind != DASH else {})}
    with when(f"POST /sessions {body}"):
        r = await gw.post("/sessions", json=body)
    doc = r.json()
    sid = doc["session"]["id"]
    if expected_answer.startswith("keys "):
        answer = (f"keys {', '.join(k if k != 'session' else 'session (id, expires_at)' for k in KEYS)}; no gws_ in the body"
                  if sorted(doc) == sorted(KEYS) and sorted(doc["session"]) == ["expires_at", "id"] and "gws_" not in r.text
                  else f"keys {sorted(doc)}; session {sorted(doc['session'])}; gws_ in body: {'gws_' in r.text}")
    elif expected_answer.endswith("/env"):
        answer = doc["pull_url"].replace(sid, "«id»")
    elif bind == DASH:
        answer = ("session.token a gws_ token; env present; no env_keys, no pull_url"
                  if TOKEN_RE.match(doc["session"].get("token", "")) and "env" in doc and "env_keys" not in doc and "pull_url" not in doc
                  else f"keys {sorted(doc)}")
    else:
        row = store.get_session(sid)
        answer = (f"token_hash = {row.token_hash.replace(sid, '«id»')}"
                  + ("; the bind recorded" if (row.bind_namespace, row.bind_serviceaccount, row.bind_pod) == (NS, SA, POD) else "; the bind NOT recorded"))
    expect({"answer": answer}, answer=expected_answer)


ENV_KEY_ROWS = [
    pytest.param("policy-default", "worker", "opencode", POLICY, "OPENCODE_CONFIG_CONTENT", id="env_keys names the opencode env"),
    pytest.param("policy-default", "reviewer", "claude", POLICY, "ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL", id="env_keys names the claude env"),
    pytest.param("policy-default", "worker", "goose", "openrouter", "OPENAI_BASE_URL, OPENAI_API_KEY, GOOSE_PROVIDER, GOOSE_MODEL", id="env_keys names the goose env"),
]


@pytest.mark.parametrize(("world", "role", "harness", "rail", "expected_env_keys"), ENV_KEY_ROWS)
async def test_env_keys_names_the_harnesss_env(gw, world, role, harness, rail, expected_env_keys):
    enter_world(world)
    inputs(role=role, harness=harness, rail=rail)
    body = body_of(role=role, harness=harness, rail=rail)
    with when(f"POST /sessions {body} + bind {BIND} → dispatch"):
        doc = await open_session(gw, **body, bind=BIND)
    expect({"env_keys": ", ".join(doc["env_keys"])}, env_keys=expected_env_keys)


MALFORMED_ROWS = [
    pytest.param("policy-default", "{namespace: platform-agents}", 400, "malformed-body", id="a bind without a serviceaccount is malformed"),
    pytest.param("policy-default", "{namespace: Platform_Agents, serviceaccount: agentstack-worker}", 400, "malformed-body",
                 id="a bind namespace that is not a DNS label is malformed"),
]
BINDS = {"{namespace: platform-agents}": {"namespace": NS}, "{namespace: Platform_Agents, serviceaccount: agentstack-worker}": {"namespace": "Platform_Agents", "serviceaccount": SA}}


@pytest.mark.parametrize(("world", "bind", "expected_status", "expected_code"), MALFORMED_ROWS)
async def test_a_malformed_bind(gw, world, bind, expected_status, expected_code):
    enter_world(world)
    inputs(bind=bind)
    with when(f"POST /sessions (platform worker) with bind {BINDS[bind]}"):
        r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "t", "bind": BINDS[bind]})
    expect({"status": r.status_code, "code": err(r)}, status=expected_status, code=expected_code)


# -- who may pull ------------------------------------------------------------------------------------------
# `presented` = what the fake TokenReview answers for the presented token, ONE thing changed from the bound
# identity (authenticated · audiences [agent-gateway] · system:serviceaccount:platform-agents:agentstack-worker · pod-name fixer-1).
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
SESSIONS = {"bound to fixer-1": BIND, "bound, no pod": {"namespace": NS, "serviceaccount": SA}, "unbound": None}
RAISES = "(the review raises)"
REFUSES = "(the API answers the gateway's review 403)"

IDENTITY_ROWS = [
    pytest.param("policy-default", "bound to fixer-1", "the bound identity", 200, DASH, id="the bound pod's projected token is served"),
    pytest.param("policy-default", "bound to fixer-1", "no bearer", 403, "pull-identity-refused", id="no bearer token"),
    pytest.param("policy-default", "bound to fixer-1", "unauthenticated", 403, "pull-identity-refused", id="a token the API does not authenticate"),
    pytest.param("policy-default", "bound to fixer-1", "the kube API audience", 403, "pull-identity-refused", id="the bound identity without the gateway audience"),
    pytest.param("policy-default", "bound to fixer-1", f"system:serviceaccount:{NS}:default", 403, "pull-identity-refused", id="another ServiceAccount of the bound namespace"),
    pytest.param("policy-default", "bound to fixer-1", f"system:serviceaccount:oracle-agents:{SA}", 403, "pull-identity-refused", id="the bound ServiceAccount name in another namespace"),
    pytest.param("policy-default", "bound to fixer-1", "pod-name fixer-2", 403, "pull-identity-refused", id="another pod of the bound ServiceAccount"),
    pytest.param("policy-default", "bound to fixer-1", "no pod-name extra", 403, "pull-identity-refused", id="a token with no pod binding when the bind names a pod"),
]
SHAPE_ROWS = [
    pytest.param("policy-default", "bound, no pod", "pod-name fixer-2", 200, DASH, id="a bind without a pod admits any pod of its ServiceAccount ⚖"),
    pytest.param("policy-default", "unbound", "the bound identity", 403, "pull-identity-refused", id="an unbound session refuses every pull ⚖"),
    pytest.param("policy-default", DASH, "the bound identity", 404, "session-not-found", id="an unknown id"),
    pytest.param("policy-default", "bound to fixer-1", RAISES, 503, "tokenreview-transient", id="the TokenReview API fails"),
    pytest.param("policy-default", "bound to fixer-1", REFUSES, 503, "tokenreview-transient", id="the TokenReview API refuses the gateway itself ⚖"),
]


async def _who_may_pull(gw, app, reviews, tmp_path, session, presented):
    seen: list[dict] = []
    with given(f"session = {session}; presented = {presented}"):
        if presented == RAISES:
            reviews.tokens[SA_TOKEN] = bound_review()
            reviews.transient = True
        elif presented == REFUSES:
            def api(request: httpx.Request) -> httpx.Response:
                seen.append(json.loads(request.content))
                return httpx.Response(403, json={"kind": "Status", "reason": "Forbidden", "code": 403})
            (tmp_path / "token").write_text("gateway-own-sa-token-fixture")
            kube = KubeTokenReviews(sa_dir=str(tmp_path))
            kube._client = httpx.AsyncClient(transport=httpx.MockTransport(api), base_url="https://kubernetes.default.svc")
            app.state.sessions.reviewer = kube
        else:
            review = REVIEWS[presented]
            reviews.tokens[SA_TOKEN] = review
            attach_json(f"the fake TokenReview's answer for the presented token: {presented}",
                        {"authenticated": review.authenticated, "user": review.username, "audiences": list(review.audiences),
                         "pod-name": list(review.extra.get(POD_NAME_EXTRA, ()))})
        if session == DASH:
            sid = "nope"
        else:
            bind = SESSIONS[session]
            sid = (await open_session(gw, **({"bind": bind} if bind else {})))["session"]["id"]
    headers = {} if presented == "no bearer" else sa()
    with when(f"POST /sessions/{sid}/env presenting {presented}"):
        r = await pull(gw, sid, headers)
    return r, seen


@pytest.mark.parametrize(("world", "session", "presented", "expected_status", "expected_code"), IDENTITY_ROWS)
async def test_the_bound_identity_one_thing_changed(gw, app, reviews, tmp_path, world, session, presented, expected_status, expected_code):
    enter_world(world)
    inputs(session=session, presented=presented)
    r, _ = await _who_may_pull(gw, app, reviews, tmp_path, session, presented)
    expect({"status": r.status_code, "code": err(r) if r.status_code >= 400 else None}, status=expected_status, code=expected_code)
    if r.status_code >= 400:
        assert "gws_" not in r.text, r.text


@pytest.mark.parametrize(("world", "session", "presented", "expected_status", "expected_code"), SHAPE_ROWS)
async def test_the_binds_shape_the_id_the_api(gw, app, reviews, tmp_path, world, session, presented, expected_status, expected_code):
    enter_world(world)
    inputs(session=session, presented=presented)
    r, seen = await _who_may_pull(gw, app, reviews, tmp_path, session, presented)
    expect({"status": r.status_code, "code": err(r) if r.status_code >= 400 else None}, status=expected_status, code=expected_code)
    if session == DASH:
        assert reviews.calls == [], reviews.calls  # no review is made for an unknown id
    if presented == REFUSES:
        assert [b["spec"]["audiences"] for b in seen] == [["agent-gateway"]], seen
    if presented == RAISES:
        assert r.headers.get("retry-after") == "5" and reviews.calls == [["agent-gateway"]], (r.headers, reviews.calls)


# -- what a pull returns -----------------------------------------------------------------------------------
RETURNS_ROWS = [
    pytest.param("policy-default", "worker", "opencode", POLICY,
                 "env keys = env_keys; apiKey a fresh gws_ token; baseURL …/openai/v1; model gateway/deepseek-v4.1-flash",
                 id="the pull answers the opencode env GW-SESSIONS-ENV would have"),
    pytest.param("policy-default", "reviewer", "claude", POLICY,
                 "ANTHROPIC_AUTH_TOKEN a fresh gws_ token; ANTHROPIC_BASE_URL …/anthropic; ANTHROPIC_MODEL sonnet",
                 id="the pull answers the claude env"),
    pytest.param("policy-default", "worker", "goose", "openrouter",
                 "OPENAI_API_KEY a fresh gws_ token; OPENAI_BASE_URL …/openai/v1; GOOSE_PROVIDER openai; GOOSE_MODEL deepseek/deepseek-v4-flash",
                 id="the pull answers the goose env"),
    pytest.param("policy-default · upstream-ok", "worker", "opencode", POLICY, "200; the row's requests = 1",
                 id="the pulled token rides the data plane"),
    pytest.param("policy-default", "worker", "opencode", POLICY, "token_hash = sha256(token); the token nowhere in the sqlite dump",
                 id="the row stores the pulled token's sha256 only"),
]


def _fresh(tok: str) -> str:
    return "a fresh gws_ token" if TOKEN_RE.match(tok or "") else f"{tok!r}"


@pytest.mark.parametrize(("world", "role", "harness", "rail", "expected_pulled"), RETURNS_ROWS)
async def test_what_a_pull_returns(gw, reviews, settings, store, world, role, harness, rail, expected_pulled):
    enter_world(world)
    inputs(role=role, harness=harness, rail=rail)
    body = body_of(role=role, harness=harness, rail=rail)
    with given(f"a bound session {body} + bind {BIND}; the fake TokenReview answers the bound identity"):
        reviews.tokens[SA_TOKEN] = bound_review()
        doc = await open_session(gw, **body, bind=BIND)
    sid = doc["session"]["id"]
    with when(f"POST /sessions/{sid}/env with the bound pod's token"):
        env = (await pull(gw, sid)).json()["env"]
    if expected_pulled.startswith("200;"):
        token = json.loads(env["OPENCODE_CONFIG_CONTENT"])["provider"]["gateway"]["options"]["apiKey"]
        with quiet():
            r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers={"authorization": f"Bearer {token}"})
            requests = (await gw.get(f"/sessions/{sid}")).json()["requests"]
        pulled = f"{r.status_code}; the row's requests = {requests}"
    elif expected_pulled.startswith("token_hash"):
        token = json.loads(env["OPENCODE_CONFIG_CONTENT"])["provider"]["gateway"]["options"]["apiKey"]
        dump = "\n".join(sqlite3.connect(settings.db_path).iterdump())
        pulled = ("token_hash = sha256(token)" if store.get_session(sid).token_hash == hashlib.sha256(token.encode()).hexdigest() else "token_hash ≠ sha256(token)") \
            + ("; the token nowhere in the sqlite dump" if token not in dump else "; the token IS in the dump")
    elif harness == "opencode":
        cfg = json.loads(env["OPENCODE_CONFIG_CONTENT"])
        pulled = (("env keys = env_keys" if list(env) == doc["env_keys"] else f"env keys {list(env)} ≠ env_keys {doc['env_keys']}")
                  + f"; apiKey {_fresh(cfg['provider']['gateway']['options']['apiKey'])}"
                  + f"; baseURL {cfg['provider']['gateway']['options']['baseURL'].replace(SELF_URL, '…')}; model {cfg['model']}")
    elif harness == "claude":
        pulled = f"ANTHROPIC_AUTH_TOKEN {_fresh(env.get('ANTHROPIC_AUTH_TOKEN'))}; ANTHROPIC_BASE_URL {env['ANTHROPIC_BASE_URL'].replace(SELF_URL, '…')}; ANTHROPIC_MODEL {env['ANTHROPIC_MODEL']}"
    else:
        pulled = (f"OPENAI_API_KEY {_fresh(env.get('OPENAI_API_KEY'))}; OPENAI_BASE_URL {env['OPENAI_BASE_URL'].replace(SELF_URL, '…')}; "
                  f"GOOSE_PROVIDER {env['GOOSE_PROVIDER']}; GOOSE_MODEL {env['GOOSE_MODEL']}")
    expect({"pulled": pulled}, pulled=expected_pulled)


# -- only once, and in order ---------------------------------------------------------------------------------
ONCE_ROWS = [
    pytest.param("policy-default · upstream-ok", "pull, pull again (the same identity)", 409, "env-already-delivered", id="a second pull by the same pod is refused ⚖"),
    pytest.param("policy-default", "pull, then a pull whose token reviews as pod-name fixer-2", 403, "pull-identity-refused",
                 id="a second pull by another pod is refused by identity first ⚖"),
    pytest.param("policy-default", "DELETE, then pull", 401, "session-released", id="a released session is refused as the data plane refuses it"),
    pytest.param("policy-default", "the clock past expires_at, then pull", 401, "session-expired", id="an expired session is refused as the data plane refuses it"),
    pytest.param("policy-default", "DELETE, then a pull whose token reviews as pod-name fixer-2", 403, "pull-identity-refused",
                 id="a wrong identity on a released session is refused by identity first ⚖"),
]


@pytest.mark.parametrize(("world", "sequence", "expected_status", "expected_code"), ONCE_ROWS)
async def test_only_once_and_in_order(gw, reviews, policy, clock, world, sequence, expected_status, expected_code):
    enter_world(world)
    inputs(sequence=sequence)
    with given(f"a bound session (platform worker, bind {BIND}); the fake TokenReview answers the bound identity for the pod's token"
               + (" and pod-name fixer-2 for a second token" if "fixer-2" in sequence else "")):
        reviews.tokens[SA_TOKEN] = bound_review()
        reviews.tokens[FIXER_2] = bound_review(pod="fixer-2")
        doc = await open_session(gw, bind=BIND)
        sid = doc["session"]["id"]
        first_token = None
        if sequence.startswith("pull"):
            with quiet():
                first = (await pull(gw, sid)).json()
            first_token = json.loads(first["env"]["OPENCODE_CONFIG_CONTENT"])["provider"]["gateway"]["options"]["apiKey"]
            attach_json("the first pull: 200", {"env keys": list(first["env"])})
        elif sequence.startswith("DELETE"):
            await gw.delete(f"/sessions/{sid}")
        else:
            clock.advance(policy.session_ttl_s + 1)
    headers = sa(FIXER_2) if "fixer-2" in sequence else sa()
    with when(f"POST /sessions/{sid}/env — {sequence.split(', then ')[-1] if ', then ' in sequence else 'again, the same identity'}"):
        r = await pull(gw, sid, headers)
    expect({"status": r.status_code, "code": err(r)}, status=expected_status, code=expected_code)
    assert "gws_" not in r.text, r.text
    if first_token and expected_status == 409:
        with quiet():
            r2 = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers={"authorization": f"Bearer {first_token}"})
        assert r2.status_code == 200, r2.text  # the first token is still served
