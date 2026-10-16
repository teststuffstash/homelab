"""GW-SESSIONS-ADMIT — POST /sessions: may this unit run now, and on which rail (specs/endpoints/sessions.md).

Which rail, or why not (world policy-default, every ref resolvable unless the row says otherwise):

| description | role | harness | tier | active on rails (anthropic / opencode / openrouter) | credential state | decision | rail | model | reason |
|---|---|---|---|---|---|---|---|---|---|
| a worker takes the first rail in its list | worker | (policy: opencode) | (policy: standard) | 0 / 0 / 0 | all resolve | dispatch | opencode | opencode-go/deepseek-v4-flash | — |
| the first rail is full, the second is taken | worker | (policy) | (policy) | 0 / 3 / 0 | all resolve | dispatch | openrouter | deepseek/deepseek-v4-flash | — |
| every allowed rail is full | worker | (policy) | (policy) | 0 / 3 / 20 | all resolve | defer | — | — | rail-capacity |
| a reviewer rides the subscription first | reviewer | (policy: claude) | (policy: heavy) | 0 / 0 / 0 | all resolve | dispatch | anthropic | claude/sonnet | — |
| the subscription is full, the reviewer takes Go | reviewer | (policy) | (policy) | 5 / 0 / 0 | all resolve | dispatch | opencode | opencode-go/claude-sonnet-4-6 | — |
| the stack's anthropic ref does not resolve, the walk continues | reviewer | (policy) | (policy) | 0 / 0 / 0 | anthropic_ref definitive miss | dispatch | opencode | opencode-go/claude-sonnet-4-6 | — |
| the only allowed rail's credential does not resolve | prober | (policy) | (policy) | 0 / 0 / 0 | anthropic_ref definitive miss | defer | — | — | credential-unresolved |
| an explicit tier picks the model inside the rail | worker | (policy) | heavy | 0 / 0 / 0 | all resolve | dispatch | opencode | opencode-go/claude-sonnet-4-6 | — |
| an explicit harness narrows the walk to its dialect | worker | goose | (policy) | 0 / 0 / 0 | all resolve | dispatch | opencode | opencode-go/deepseek-v4-flash | — |
| a harness that cannot speak the role's only rail | prober | opencode | (policy) | 0 / 0 / 0 | all resolve | defer | — | — | role-rail-denied |
| an explicit rail the role is not allowed | worker | (policy) | (policy) | 0 / 0 / 0 | all resolve, rail: anthropic | defer | — | — | role-rail-denied |
| an explicit rail the role is allowed is taken even when later in the list | worker | (policy) | (policy) | 0 / 0 / 0 | all resolve, rail: openrouter | dispatch | openrouter | deepseek/deepseek-v4-flash | — |
| an unknown stack | worker (stack nope) | (policy) | (policy) | 0 / 0 / 0 | — | defer | — | — | stack-unknown |

What is an HTTP error, and what is not:

| description | body | status | error code |
|---|---|---|---|
| a well-formed request that must wait | worker, every rail full | 200 | — (decision: defer) |
| a missing required field | no task | 400 | malformed-body |
| a role outside the enum | role: janitor | 400 | malformed-body |
| a tier outside the enum | tier: enormous | 400 | malformed-body |
| a negative round | round: -1 | 400 | malformed-body |
| a body that is not JSON | not json | 400 | malformed-body |
| an explicit harness and rail that cannot speak | harness: claude, rail: openrouter — wait, claude speaks anthropic and openrouter serves it; the spec's cell is goose x anthropic | 400 | harness-rail-mismatch |
| an explicit harness and rail that can speak | harness: claude, rail: opencode (reviewer) | 200 | — (decision: dispatch) |
| the kube API is away while resolving the credential | reviewer; FakeSecrets transient fault | 503 | credential-transient |
| codex where no allowed rail serves responses | harness: codex (worker; policy-default has no codex rail) | 200 | — (decision: defer, role-rail-denied) |
| codex against a rail that does not serve responses | harness: codex, rail: openrouter | 400 | harness-rail-mismatch |

Counting:

| description | before | active after | gateway_sessions_active{rail} |
|---|---|---|---|
| a dispatch counts on its rail | opencode 0 -> worker dispatched | opencode 1 | opencode = 1 |
| a release frees the slot | opencode 1 -> DELETE it | opencode 0 | opencode = 0 |
| an expiry frees the slot without a DELETE | opencode 1, expires_at passed | opencode 0 | opencode = 0 |
| a defer counts nothing | opencode 3 -> worker deferred | opencode 3 | opencode = 3 |
"""

from __future__ import annotations

import pytest

from .conftest import attach_json, check, err, given, open_session, quiet, rule, then, then_eq, when, world

pytestmark = rule("GW-SESSIONS-ADMIT")

MODELS = {"opencode": {"standard": "opencode-go/deepseek-v4-flash", "heavy": "opencode-go/claude-sonnet-4-6"},
          "openrouter": {"standard": "deepseek/deepseek-v4-flash"}, "anthropic": {"heavy": "claude/sonnet"}}

WALK_ROWS = [
    ("a worker takes the first rail in its list", {}, {}, {"decision": "dispatch", "rail": "opencode", "model": "opencode-go/deepseek-v4-flash"}),
    ("the first rail is full, the second is taken", {}, {"fill": {"opencode": 3}}, {"decision": "dispatch", "rail": "openrouter", "model": "deepseek/deepseek-v4-flash"}),
    ("every allowed rail is full", {}, {"fill": {"opencode": 3, "openrouter": 20}}, {"decision": "defer", "reason": "rail-capacity"}),
    ("a reviewer rides the subscription first", {"role": "reviewer"}, {}, {"decision": "dispatch", "rail": "anthropic", "model": "claude/sonnet", "harness": "claude"}),
    ("the subscription is full, the reviewer takes Go", {"role": "reviewer"}, {"fill": {"anthropic": 5}}, {"decision": "dispatch", "rail": "opencode", "model": "opencode-go/claude-sonnet-4-6"}),
    ("the stack's anthropic ref does not resolve, the walk continues", {"role": "reviewer"}, {"miss": "platform-agents/claude-session"}, {"decision": "dispatch", "rail": "opencode", "model": "opencode-go/claude-sonnet-4-6"}),
    ("the only allowed rail's credential does not resolve", {"role": "prober"}, {"miss": "platform-agents/claude-session"}, {"decision": "defer", "reason": "credential-unresolved"}),
    ("an explicit tier picks the model inside the rail", {"tier": "heavy"}, {}, {"decision": "dispatch", "rail": "opencode", "model": "opencode-go/claude-sonnet-4-6"}),
    ("an explicit harness narrows the walk to its dialect", {"harness": "goose"}, {}, {"decision": "dispatch", "rail": "opencode", "model": "opencode-go/deepseek-v4-flash"}),
    ("a harness that cannot speak the role's only rail", {"role": "prober", "harness": "opencode"}, {}, {"decision": "defer", "reason": "role-rail-denied"}),
    ("an explicit rail the role is not allowed", {"rail": "anthropic", "harness": "claude"}, {}, {"decision": "defer", "reason": "role-rail-denied"}),
    ("an explicit rail the role is allowed is taken even when later in the list", {"rail": "openrouter"}, {}, {"decision": "dispatch", "rail": "openrouter", "model": "deepseek/deepseek-v4-flash"}),
    ("an unknown stack", {"stack": "nope"}, {}, {"decision": "defer", "reason": "stack-unknown"}),
]


async def _fill(gw, rail: str, n: int):
    """Arrange only: n active sessions on `rail` (muted — one summary attachment instead of n)."""
    with quiet():
        for i in range(n):
            await open_session(gw, role="worker" if rail != "anthropic" else "reviewer", task=f"fill-{rail}-{i}", rail=rail, harness="claude")
    attach_json(f"filled: {rail} × {n}", {"rail": rail, "active_sessions_opened": n})


async def _arrange(gw, app, secrets, clock, state: dict):
    if not state:
        with given("state: no rail holds a session, every credential ref resolves"):
            pass
    for rail, n in state.get("fill", {}).items():
        with given(f"state: rail {rail} holds {n} active sessions"):
            await _fill(gw, rail, n)
    if "miss" in state:
        with given(f"state: credential ref {state['miss']} is a definitive miss"):
            secrets.secrets.pop(state["miss"])
            app.state.resolver.forget()
            attach_json(f"secrets after: {state['miss']} removed", sorted(secrets.secrets))
    if "transient" in state:
        with given(f"state: credential ref {state['transient']} answers a transient fault (kube API away)"):
            secrets.transient.add(state["transient"])
            app.state.resolver.forget()
            attach_json(f"secrets transient: {state['transient']}", sorted(secrets.transient))


def _req(body: dict) -> dict:
    return {"stack": "platform", "role": "worker", "task": "homelab-2588-r1", **body}


@pytest.mark.parametrize(("body", "state", "expected"), [r[1:] for r in WALK_ROWS], ids=[r[0] for r in WALK_ROWS])
async def test_walk(gw, app, secrets, clock, body, state, expected):
    world()
    await _arrange(gw, app, secrets, clock, state)
    with when(f"POST /sessions body {body or '(defaults: platform worker)'}"):
        r = await gw.post("/sessions", json=_req(body))
    then_eq("status", r.status_code, 200)
    doc = r.json()
    claim = "expected " + ", ".join(f"{k} = {v}" for k, v in expected.items())
    with then(claim, **{k: {"expected": v, "actual": doc.get(k)} for k, v in expected.items()}):  # one verdict attachment per claim
        for k, v in expected.items():
            assert doc.get(k) == v, f"{k}: expected {v!r}, got {doc.get(k)!r}"
    if doc["decision"] == "defer":
        with then("a defer carries exactly decision, reason, retry_after_s ≥ 1",
                  keys={"expected": ["decision", "reason", "retry_after_s"], "actual": sorted(doc)}, retry_after_s=doc.get("retry_after_s")):
            assert set(doc) == {"decision", "reason", "retry_after_s"} and doc["retry_after_s"] >= 1
    else:
        want = ["context_tokens", "decision", "env", "harness", "model", "rail", "session"]
        with then("a dispatch carries exactly decision, session, rail, harness, model, env, context_tokens",
                  keys={"expected": want, "actual": sorted(doc)}):
            assert set(doc) == set(want)


HTTP_ROWS = [
    ("a well-formed request that must wait", {}, {"fill": {"opencode": 3, "openrouter": 20}}, 200, None),
    ("a missing required field", {"task": None}, {}, 400, "malformed-body"),
    ("a role outside the enum", {"role": "janitor"}, {}, 400, "malformed-body"),
    ("a tier outside the enum", {"tier": "enormous"}, {}, 400, "malformed-body"),
    ("a negative round", {"round": -1}, {}, 400, "malformed-body"),
    ("a rail outside the enum", {"rail": "zen"}, {}, 400, "malformed-body"),
    ("a body that is not JSON", "not json", {}, 400, "malformed-body"),
    ("an explicit harness and rail that cannot speak", {"role": "reviewer", "harness": "goose", "rail": "anthropic"}, {}, 400, "harness-rail-mismatch"),
    ("an explicit harness and rail that can speak", {"role": "reviewer", "harness": "claude", "rail": "opencode"}, {}, 200, None),
    ("the kube API is away while resolving the credential", {"role": "reviewer"}, {"transient": "platform-agents/claude-session"}, 503, "credential-transient"),
    ("codex where no allowed rail serves responses", {"harness": "codex"}, {}, 200, None),
    ("codex against a rail that does not serve responses", {"harness": "codex", "rail": "openrouter"}, {}, 400, "harness-rail-mismatch"),
]


@pytest.mark.parametrize(("body", "state", "status", "code"), [r[1:] for r in HTTP_ROWS], ids=[r[0] for r in HTTP_ROWS])
async def test_http_errors(gw, app, secrets, clock, body, state, status, code):
    world()
    await _arrange(gw, app, secrets, clock, state)
    if isinstance(body, str):
        with when(f"POST /sessions body {body!r} (raw, content-type application/json)"):
            r = await gw.post("/sessions", content=body, headers={"content-type": "application/json"})
    else:
        req = {k: v for k, v in _req(body).items() if v is not None}
        with when(f"POST /sessions body {body or '(defaults)'}"):
            r = await gw.post("/sessions", json=req)
    then_eq("status", r.status_code, status)
    if code:
        then_eq("code", err(r), code, claim=f"error code = {code}")
    if body == {"harness": "codex"}:
        then_eq("(decision, reason)", (r.json()["decision"], r.json()["reason"]), ("defer", "role-rail-denied"))
    if status == 503:
        then_eq("retry-after", r.headers.get("retry-after"), "20", claim="status 503 carries retry-after = 20")


async def _active(gw, rail: str) -> int:
    import re

    text = (await gw.get("/metrics")).text
    return int(re.search(rf'^gateway_sessions_active\{{rail="{rail}"\}} (\d+)$', text, re.M).group(1))


async def test_a_dispatch_counts_on_its_rail(gw):
    """row: a dispatch counts on its rail"""
    world()
    with given("before: opencode holds 0 active sessions"):
        await _active(gw, "opencode")  # the /metrics exchange attaches here: the before value
    with when("POST /sessions (platform worker) → dispatch on opencode"):
        await open_session(gw)
    with then("after: gateway_sessions_active{rail=opencode} = 1"):
        check("gateway_sessions_active{rail=opencode}", await _active(gw, "opencode"), 1)


async def test_a_release_frees_the_slot(gw):
    """row: a release frees the slot"""
    world()
    with given("before: opencode holds 1 active session"):
        doc = await open_session(gw)
    with when(f"DELETE /sessions/{doc['session']['id']}"):
        await gw.delete(f"/sessions/{doc['session']['id']}")
    with then("after: gateway_sessions_active{rail=opencode} = 0"):
        check("gateway_sessions_active{rail=opencode}", await _active(gw, "opencode"), 0)


async def test_an_expiry_frees_the_slot(gw, policy, clock):
    """row: an expiry frees the slot without a DELETE"""
    world()
    with given("before: opencode holds 1 active session"):
        await open_session(gw)
    with when(f"the clock passes expires_at (+{policy.session_ttl_s + 1} s), no DELETE"):
        clock.advance(policy.session_ttl_s + 1)
    with then("after: gateway_sessions_active{rail=opencode} = 0"):
        check("gateway_sessions_active{rail=opencode}", await _active(gw, "opencode"), 0)
    with then("a new admission dispatches on rail opencode again"):
        check("rail", (await open_session(gw, task="again"))["rail"], "opencode")


async def test_a_defer_counts_nothing(gw):
    """row: a defer counts nothing"""
    world()
    with given("before: opencode holds 3 active sessions (its cap)"):
        await _fill(gw, "opencode", 3)
    with when("POST /sessions rail=opencode (platform worker)"):
        r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "t", "rail": "opencode"})
    then_eq("decision", r.json()["decision"], "defer")
    with then("after: gateway_sessions_active{rail=opencode} = 3"):
        check("gateway_sessions_active{rail=opencode}", await _active(gw, "opencode"), 3)
