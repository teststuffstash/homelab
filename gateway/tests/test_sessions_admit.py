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
| codex is a gap | harness: codex | 400 | harness-rail-mismatch |

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

from .conftest import err, open_session, rule

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
    for i in range(n):
        await open_session(gw, role="worker" if rail != "anthropic" else "reviewer", task=f"fill-{rail}-{i}", rail=rail, harness="claude")


async def _arrange(gw, app, secrets, clock, state: dict):
    for rail, n in state.get("fill", {}).items():
        await _fill(gw, rail, n)
    if "miss" in state:
        secrets.secrets.pop(state["miss"])
        app.state.resolver.forget()
    if "transient" in state:
        secrets.transient.add(state["transient"])
        app.state.resolver.forget()


@pytest.mark.parametrize(("body", "state", "expected"), [r[1:] for r in WALK_ROWS], ids=[r[0] for r in WALK_ROWS])
async def test_walk(gw, app, secrets, clock, body, state, expected):
    await _arrange(gw, app, secrets, clock, state)
    r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "homelab-2588-r1", **body})
    assert r.status_code == 200, r.text
    doc = r.json()
    for k, v in expected.items():
        assert doc.get(k) == v, (k, doc)
    if doc["decision"] == "defer":
        assert set(doc) == {"decision", "reason", "retry_after_s"} and doc["retry_after_s"] >= 1
    else:
        assert set(doc) == {"decision", "session", "rail", "harness", "model", "env", "context_tokens"}


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
    ("codex is a gap", {"harness": "codex"}, {}, 400, "harness-rail-mismatch"),
]


@pytest.mark.parametrize(("body", "state", "status", "code"), [r[1:] for r in HTTP_ROWS], ids=[r[0] for r in HTTP_ROWS])
async def test_http_errors(gw, app, secrets, clock, body, state, status, code):
    await _arrange(gw, app, secrets, clock, state)
    if isinstance(body, str):
        r = await gw.post("/sessions", content=body, headers={"content-type": "application/json"})
    else:
        req = {"stack": "platform", "role": "worker", "task": "homelab-2588-r1", **body}
        r = await gw.post("/sessions", json={k: v for k, v in req.items() if v is not None})
    assert r.status_code == status, r.text
    if code:
        assert err(r) == code
    if status == 503:
        assert r.headers["retry-after"] == "20"


async def _active(gw, rail: str) -> int:
    import re

    text = (await gw.get("/metrics")).text
    return int(re.search(rf'^gateway_sessions_active\{{rail="{rail}"\}} (\d+)$', text, re.M).group(1))


async def test_a_dispatch_counts_on_its_rail(gw):
    """row: a dispatch counts on its rail"""
    await open_session(gw)
    assert await _active(gw, "opencode") == 1


async def test_a_release_frees_the_slot(gw):
    """row: a release frees the slot"""
    doc = await open_session(gw)
    await gw.delete(f"/sessions/{doc['session']['id']}")
    assert await _active(gw, "opencode") == 0


async def test_an_expiry_frees_the_slot(gw, policy, clock):
    """row: an expiry frees the slot without a DELETE"""
    await open_session(gw)
    clock.advance(policy.session_ttl_s + 1)
    assert await _active(gw, "opencode") == 0
    assert (await open_session(gw, task="again"))["rail"] == "opencode"


async def test_a_defer_counts_nothing(gw):
    """row: a defer counts nothing"""
    await _fill(gw, "opencode", 3)
    r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "t", "rail": "opencode"})
    assert r.json()["decision"] == "defer"
    assert await _active(gw, "opencode") == 3
