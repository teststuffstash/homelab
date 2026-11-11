"""GW-SESSIONS-ADMIT — POST /sessions: may this unit run now, and on which cell (specs/endpoints/sessions.md
§Admission → GW-SESSIONS-ADMIT). The tables there — the policy walk, the explicit overrides, the
harness that follows the cell and the preferred end of the list (world policy-codex), what is an HTTP error, counting — are this
module's parametrize lists: header == argnames, description == id (tests/_rows.py)."""

from __future__ import annotations

import re

import pytest

from ._codex_world import fresh_report
from ._rows import DASH, POLICY, body_of, enter_world, expect, inputs
from .conftest import attach_json, check, err, given, open_session, quiet, rule, then, when

pytestmark = rule("GW-SESSIONS-ADMIT")

TASK = "homelab-2588-r1"
SUB_REF = "platform-agents/claude-session"
ALL_RESOLVE = "all resolve"
MISS = "anthropic_ref definitive miss"
TRANSIENT = "anthropic_ref transient fault"
# how a rail is filled: an explicit (role, harness) pair the rail serves
FILL = {
    "anthropic": {"role": "reviewer", "harness": "claude"},
    "opencode": {"role": "worker", "harness": "opencode"},
    "openrouter": {"role": "worker", "harness": "goose"},
    "codex": {"role": "prober", "harness": "codex"},
}
DEFAULT_RAILS = ("anthropic", "opencode", "openrouter")
CODEX_RAILS = ("anthropic", "opencode", "codex")


async def fill_rails(gw, active: str, rails: tuple[str, ...]) -> None:
    """Given: `active` = the active sessions per rail (`anthropic/opencode/openrouter` → `0/3/0`),
    opened quietly — one summary attachment instead of n exchanges."""
    counts = {r: int(n) for r, n in zip(rails, active.split("/"), strict=True)}
    filled = {r: n for r, n in counts.items() if n}
    with given(f"active = {active}: " + (", ".join(f"rail {r} holds {n} active sessions" for r, n in filled.items())
                                         or "no rail holds a session")):
        with quiet():
            for r, n in filled.items():
                for i in range(n):
                    await open_session(gw, task=f"fill-{r}-{i}", rail=r, **FILL[r])
        if filled:
            attach_json("filled rails", filled)


async def set_credential(app, secrets, credential: str) -> None:
    """Given: `credential` = the stack's refs as the Secret source answers them."""
    with given(f"credential = {credential}"):
        if credential == MISS:
            secrets.secrets.pop(SUB_REF)
            app.state.resolver.forget()
        elif credential == TRANSIENT:
            secrets.transient.add(SUB_REF)
            app.state.resolver.forget()


def shape(doc: dict) -> None:
    """Then: the answer's keys are exactly the decision's."""
    if doc.get("decision") == "defer":
        with then("a defer carries exactly decision, reason, retry_after_s ≥ 1",
                  keys={"expected": ["decision", "reason", "retry_after_s"], "actual": sorted(doc)}):
            assert set(doc) == {"decision", "reason", "retry_after_s"} and doc["retry_after_s"] >= 1, doc
    else:
        want = ["context_tokens", "decision", "env", "harness", "model", "rail", "rail_choice", "session"]
        with then("a dispatch carries exactly decision, session, rail, harness, model, env, context_tokens, rail_choice",
                  keys={"expected": want, "actual": sorted(doc)}):
            assert set(doc) == set(want), doc


async def _active(gw, rail: str) -> int:
    with quiet():
        text = (await gw.get("/metrics")).text
    return int(re.search(rf'^gateway_sessions_active\{{rail="{rail}"\}} (\d+)$', text, re.M).group(1))


# -- the policy walk -------------------------------------------------------------------------------
WALK = [
    pytest.param("policy-default", "platform", "worker", "0/0/0", ALL_RESOLVE, "dispatch", "opencode", "opencode-go/deepseek-v4.1-flash", DASH,
                 id="a worker takes the first rail in its list"),
    pytest.param("policy-default", "platform", "worker", "0/3/0", ALL_RESOLVE, "dispatch", "openrouter", "deepseek/deepseek-v4-flash", DASH,
                 id="the first rail is full, the second is taken"),
    pytest.param("policy-default", "platform", "worker", "0/3/20", ALL_RESOLVE, "defer", DASH, DASH, "rail-capacity",
                 id="every allowed rail is full"),
    pytest.param("policy-default", "platform", "reviewer", "0/0/0", ALL_RESOLVE, "dispatch", "anthropic", "claude/sonnet", DASH,
                 id="a reviewer rides the subscription first"),
    pytest.param("policy-default", "platform", "reviewer", "5/0/0", ALL_RESOLVE, "dispatch", "opencode", "opencode-go/claude-haiku-5-5", DASH,
                 id="the subscription is full, the reviewer takes Go"),
    pytest.param("policy-default", "platform", "reviewer", "0/0/0", MISS, "dispatch", "opencode", "opencode-go/claude-haiku-5-5", DASH,
                 id="the stack's anthropic ref does not resolve, the walk continues ⚖"),
    pytest.param("policy-default", "platform", "prober", "0/0/0", MISS, "defer", DASH, DASH, "credential-unresolved",
                 id="the only allowed rail's credential does not resolve"),
    pytest.param("policy-default", "nope", "worker", "0/0/0", ALL_RESOLVE, "defer", DASH, DASH, "stack-unknown",
                 id="an unknown stack"),
]


@pytest.mark.parametrize(("world", "stack", "role", "active", "credential", "expected_decision", "expected_rail", "expected_model", "expected_reason"), WALK)
async def test_the_policy_walk(gw, app, secrets, world, stack, role, active, credential,
                               expected_decision, expected_rail, expected_model, expected_reason):
    enter_world(world)
    inputs(stack=stack, role=role, active=active, credential=credential)
    await fill_rails(gw, active, DEFAULT_RAILS)
    await set_credential(app, secrets, credential)
    body = {"stack": stack, "role": role, "task": TASK}
    with when(f"POST /sessions {body}"):
        r = await gw.post("/sessions", json=body)
    assert r.status_code == 200, r.text
    doc = r.json()
    expect(doc, decision=expected_decision, rail=expected_rail, model=expected_model, reason=expected_reason)
    shape(doc)


# -- explicit tier, harness and rail ----------------------------------------------------------------
OVERRIDES = [
    pytest.param("policy-default", "worker", "heavy", POLICY, POLICY, "dispatch", "opencode", "opencode-go/claude-haiku-5-5", DASH,
                 id="an explicit tier picks the model inside the rail"),
    pytest.param("policy-default", "worker", POLICY, "goose", POLICY, "dispatch", "opencode", "opencode-go/deepseek-v4.1-flash", DASH,
                 id="an explicit harness narrows the walk to its dialect"),
    pytest.param("policy-default", "worker", "light", "claude", POLICY, "dispatch", "openrouter", "deepseek/deepseek-v4-flash", DASH,
                 id="an explicit harness passes the rail whose cells all speak another dialect"),
    pytest.param("policy-default", "prober", POLICY, "opencode", POLICY, "defer", DASH, DASH, "role-rail-denied",
                 id="a harness that cannot speak the role's only rail ⚖"),
    pytest.param("policy-default", "worker", POLICY, "claude", "anthropic", "defer", DASH, DASH, "role-rail-denied",
                 id="an explicit rail the role is not allowed"),
    pytest.param("policy-default", "worker", POLICY, "claude", "codex", "defer", DASH, DASH, "role-rail-denied",
                 id="an explicit rail the policy does not declare ⚖"),
    pytest.param("policy-default", "worker", POLICY, POLICY, "openrouter", "dispatch", "openrouter", "deepseek/deepseek-v4-flash", DASH,
                 id="an explicit rail the role is allowed is taken even when later in the list ⚖"),
]


@pytest.mark.parametrize(("world", "role", "tier", "harness", "rail", "expected_decision", "expected_rail", "expected_model", "expected_reason"), OVERRIDES)
async def test_explicit_tier_harness_and_rail(gw, world, role, tier, harness, rail,
                                              expected_decision, expected_rail, expected_model, expected_reason):
    enter_world(world)
    inputs(role=role, tier=tier, harness=harness, rail=rail)
    body = {"stack": "platform", "task": TASK, **body_of(role=role, tier=tier, harness=harness, rail=rail)}
    with when(f"POST /sessions {body}"):
        r = await gw.post("/sessions", json=body)
    assert r.status_code == 200, r.text
    doc = r.json()
    expect(doc, decision=expected_decision, rail=expected_rail, model=expected_model, reason=expected_reason)
    shape(doc)


# -- the harness follows the cell (world policy-codex) ----------------------------------------------
CELL = [
    pytest.param("policy-codex", "reviewer", POLICY, POLICY, POLICY, "5/3/0", "dispatch", "codex", "codex", "codex/fixture-model", DASH,
                 id="without a harness the walk crosses the dialect boundary: the reviewer reaches codex ⚖"),
    pytest.param("policy-codex", "reviewer", POLICY, POLICY, POLICY, "5/0/0", "dispatch", "opencode", "claude", "opencode-go/claude-haiku-5-5", DASH,
                 id="a dual-dialect rail keeps the role's harness"),
    pytest.param("policy-codex", "reviewer", "standard", POLICY, POLICY, "5/0/0", "dispatch", "opencode", "opencode", "opencode-go/deepseek-v4.1-flash", DASH,
                 id="the Go cell's dialect is the model's: an openai cell rides the opencode harness"),
    pytest.param("policy-codex", "reviewer", "standard", "claude", POLICY, "5/0/0", "dispatch", "opencode", "claude", "opencode-go/claude-haiku-5-5", DASH,
                 id="an explicit harness on the Go rail skips the openai cells and takes the Claude model"),
    pytest.param("policy-codex", "worker", POLICY, POLICY, POLICY, "0/3/2", "dispatch", "anthropic", "claude", "claude/sonnet", DASH,
                 id="an opencode-harness worker reaching the anthropic rail rides claude ⚖"),
    pytest.param("policy-codex", "reviewer", POLICY, "claude", POLICY, "5/3/0", "defer", DASH, DASH, DASH, "rail-capacity",
                 id="an explicit harness still narrows the walk to its dialect"),
    pytest.param("policy-codex", "reviewer", POLICY, POLICY, "codex", "0/0/0", "dispatch", "codex", "codex", "codex/fixture-model", DASH,
                 id="an explicit rail without a harness takes the rail's harness ⚖"),
]


async def codex_ready(codex_app, clock) -> None:
    with given("codex headroom observed fresh: 20 % / 64 % (the rail's admission gate)"):
        codex_app.state.codex.headroom.observe(fresh_report(clock))


@pytest.mark.parametrize(("world", "role", "tier", "harness", "rail", "active",
                          "expected_decision", "expected_rail", "expected_harness", "expected_model", "expected_reason"), CELL)
async def test_the_harness_follows_the_cell(codex_app, codex_gw, clock, world, role, tier, harness, rail, active,
                                            expected_decision, expected_rail, expected_harness, expected_model, expected_reason):
    enter_world(world)
    inputs(role=role, tier=tier, harness=harness, rail=rail, active=active)
    await codex_ready(codex_app, clock)
    await fill_rails(codex_gw, active, CODEX_RAILS)
    body = {"stack": "platform", "task": TASK, **body_of(role=role, tier=tier, harness=harness, rail=rail)}
    with when(f"POST /sessions {body}"):
        r = await codex_gw.post("/sessions", json=body)
    assert r.status_code == 200, r.text
    expect(r.json(), decision=expected_decision, rail=expected_rail, harness=expected_harness, model=expected_model, reason=expected_reason)


ENV_FOLLOWS = [
    pytest.param("policy-codex", "worker", "0/3/2", "claude", "ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL",
                 id="the env is the picked harness's"),
]


@pytest.mark.parametrize(("world", "role", "active", "expected_harness", "expected_env_keys"), ENV_FOLLOWS)
async def test_the_env_follows_the_picked_harness(codex_app, codex_gw, clock, world, role, active, expected_harness, expected_env_keys):
    enter_world(world)
    inputs(role=role, active=active)
    await codex_ready(codex_app, clock)
    await fill_rails(codex_gw, active, CODEX_RAILS)
    body = {"stack": "platform", "task": TASK, "role": role}
    with when(f"POST /sessions {body} — no harness"):
        doc = await open_session(codex_gw, **body)
    expect({"harness": doc["harness"], "env_keys": ", ".join(doc["env"])}, harness=expected_harness, env_keys=expected_env_keys)


# -- the preferred end of the list (world policy-codex: anthropic heavy = [sonnet, opus, fable]) ------
REVIEW_TASK = "specs-review homelab#2700"
FABLE_STRUCK = "harness-gave-up on (anthropic, claude/fable)"
PREFER = [
    pytest.param("policy-codex", "reviewer", "heavy", POLICY, "0/0/0", DASH, "dispatch", "anthropic", "claude/sonnet",
                 id="no preference: the list is walked from its head"),
    pytest.param("policy-codex", "reviewer", "heavy", "cheapest", "0/0/0", DASH, "dispatch", "anthropic", "claude/sonnet",
                 id="cheapest is the default, spelled"),
    pytest.param("policy-codex", "reviewer", "heavy", "strongest", "0/0/0", DASH, "dispatch", "anthropic", "claude/fable",
                 id="strongest takes the last model of the rail's list ⚖"),
    pytest.param("policy-codex", "reviewer", "heavy", "strongest", "0/0/0", FABLE_STRUCK, "dispatch", "anthropic", "claude/opus",
                 id="the strongest is struck: the next-strongest is taken, not the cheapest ⚖"),
    pytest.param("policy-codex", "reviewer", "standard", "strongest", "5/0/0", DASH, "dispatch", "opencode", "opencode-go/claude-haiku-5-5",
                 id="the role's rail order stands: the next rail's list is walked from its end too ⚖"),
    pytest.param("policy-codex", "reviewer", "standard", "strongest", "0/0/0", DASH, "dispatch", "anthropic", "claude/sonnet",
                 id="a one-model list is the same from either end"),
]


@pytest.mark.parametrize(("world", "role", "tier", "prefer", "active", "strikes",
                          "expected_decision", "expected_rail", "expected_model"), PREFER)
async def test_the_preferred_end_of_the_list(codex_app, codex_gw, clock, world, role, tier, prefer, active, strikes,
                                             expected_decision, expected_rail, expected_model):
    enter_world(world)
    inputs(role=role, tier=tier, prefer=prefer, active=active, strikes=strikes)
    await codex_ready(codex_app, clock)
    await fill_rails(codex_gw, active, CODEX_RAILS)
    asked = {"stack": "platform", "task": REVIEW_TASK, **body_of(role=role, tier=tier, prefer=prefer)}
    with given(f"strikes = {strikes}"):
        if strikes == FABLE_STRUCK:  # the task's attempt 1, admitted with the same preference, ends harness-gave-up (cell scope)
            with quiet():
                first = await open_session(codex_gw, **asked)
                o = await codex_gw.post(f"/sessions/{first['session']['id']}/outcome", json={"class": "harness-gave-up"})
                await codex_gw.delete(f"/sessions/{first['session']['id']}")
            attach_json(f"arranged strike: harness-gave-up on ({first['rail']}, {first['model']})", o.json())
            assert (first["rail"], first["model"]) == ("anthropic", "claude/fable"), first
            assert o.json()["strike"] == {"class": "harness-gave-up", "scope": "cell"}, o.text
    body = {**asked, **({"attempt": 2} if strikes != DASH else {})}
    with when(f"POST /sessions {body}"):
        r = await codex_gw.post("/sessions", json=body)
    assert r.status_code == 200, r.text
    doc = r.json()
    expect(doc, decision=expected_decision, rail=expected_rail, model=expected_model)
    shape(doc)


# `body` cell → the request: a well-formed body with the named keys set.
CANARY_CELL = {"model": "deepseek/deepseek-v4.1-flash", "provider": "deepinfra"}
PREFER_BODIES = {
    "worker, prefer: fastest": {"role": "worker", "prefer": "fastest"},
    "worker, prefer: 1": {"role": "worker", "prefer": 1},
    "prober, canary: {deepseek/deepseek-v4.1-flash, deepinfra}": {"role": "prober", "canary": CANARY_CELL},
    "prober, canary: {deepseek/deepseek-v4.1-flash, deepinfra}, prefer: strongest": {"role": "prober", "canary": CANARY_CELL, "prefer": "strongest"},
    "prober, canary: {deepseek/deepseek-v4.1-flash, deepinfra}, prefer: cheapest": {"role": "prober", "canary": CANARY_CELL, "prefer": "cheapest"},
}
PREFER_REFUSED = [
    pytest.param("policy-default", "worker, prefer: fastest", 400, "malformed-body", DASH,
                 id="a preference outside the enum"),
    pytest.param("policy-default", "worker, prefer: 1", 400, "malformed-body", DASH,
                 id="a preference that is not a string"),
    pytest.param("policy-default", "prober, canary: {deepseek/deepseek-v4.1-flash, deepinfra}", 200, DASH, "defer",
                 id="a canary without a preference is answered as a canary"),
    pytest.param("policy-default", "prober, canary: {deepseek/deepseek-v4.1-flash, deepinfra}, prefer: strongest", 400, "malformed-body", DASH,
                 id="a canary names its own cell: a preference with it is refused ⚖"),
    pytest.param("policy-default", "prober, canary: {deepseek/deepseek-v4.1-flash, deepinfra}, prefer: cheapest", 400, "malformed-body", DASH,
                 id="the default spelled on a canary is refused too ⚖"),
]


@pytest.mark.parametrize(("world", "body", "expected_status", "expected_code", "expected_decision"), PREFER_REFUSED)
async def test_a_preference_the_body_may_not_carry(gw, world, body, expected_status, expected_code, expected_decision):
    enter_world(world)
    inputs(body=body)
    req = {"stack": "platform", "task": TASK, **PREFER_BODIES[body]}
    with when(f"POST /sessions {req}"):
        r = await gw.post("/sessions", json=req)
    view = {"status": r.status_code, "code": err(r) if r.status_code >= 400 else None, "decision": r.json().get("decision")}
    expect(view, status=expected_status, code=expected_code, decision=expected_decision)


# -- what is an HTTP error, and what is not ---------------------------------------------------------
MALFORMED = [
    pytest.param("policy-default", "no task", 400, "malformed-body", id="a missing required field"),
    pytest.param("policy-default", "role: janitor", 400, "malformed-body", id="a role outside the enum"),
    pytest.param("policy-default", "tier: enormous", 400, "malformed-body", id="a tier outside the enum"),
    pytest.param("policy-default", "rail: zen", 400, "malformed-body", id="a rail outside the enum"),
    pytest.param("policy-default", "round: -1", 400, "malformed-body", id="a negative round"),
    pytest.param("policy-default", "not JSON", 400, "malformed-body", id="a body that is not JSON"),
]


@pytest.mark.parametrize(("world", "body", "expected_status", "expected_code"), MALFORMED)
async def test_a_malformed_body(gw, world, body, expected_status, expected_code):
    enter_world(world)
    inputs(body=body)
    if body == "not JSON":
        with when(f"POST /sessions body {body!r} (raw, content-type application/json)"):
            r = await gw.post("/sessions", content=b"not json", headers={"content-type": "application/json"})
    else:
        req = {"stack": "platform", "role": "worker", "task": TASK}
        if body == "no task":
            del req["task"]
        else:
            key, value = body.split(": ", 1)
            req[key] = int(value) if key == "round" else value
        with when(f"POST /sessions {req}"):
            r = await gw.post("/sessions", json=req)
    expect({"status": r.status_code, "code": err(r)}, status=expected_status, code=expected_code)


PAIR = [
    pytest.param("policy-default", "reviewer", "goose", "anthropic", 400, "harness-rail-mismatch", DASH, DASH,
                 id="an explicit harness and rail that cannot speak"),
    pytest.param("policy-default", "worker", "claude", "opencode", 400, "harness-rail-mismatch", DASH, DASH,
                 id="an explicit harness and rail no cell of which speaks it"),
    pytest.param("policy-default", "reviewer", "claude", "opencode", 200, DASH, "dispatch", DASH,
                 id="an explicit harness and rail that can speak"),
    pytest.param("policy-default", "worker", "codex", POLICY, 200, DASH, "defer", "role-rail-denied",
                 id="codex where no allowed rail serves responses"),
    pytest.param("policy-default", "worker", "codex", "openrouter", 400, "harness-rail-mismatch", DASH, DASH,
                 id="codex against a rail that does not serve responses"),
]


@pytest.mark.parametrize(("world", "role", "harness", "rail", "expected_status", "expected_code", "expected_decision", "expected_reason"), PAIR)
async def test_an_explicit_harness_and_rail_pair(gw, world, role, harness, rail, expected_status, expected_code, expected_decision, expected_reason):
    enter_world(world)
    inputs(role=role, harness=harness, rail=rail)
    body = {"stack": "platform", "task": TASK, **body_of(role=role, harness=harness, rail=rail)}
    with when(f"POST /sessions {body}"):
        r = await gw.post("/sessions", json=body)
    doc = r.json()
    view = {"status": r.status_code, "code": err(r) if r.status_code >= 400 else None,
            "decision": doc.get("decision"), "reason": doc.get("reason")}
    expect(view, status=expected_status, code=expected_code, decision=expected_decision, reason=expected_reason)


NOT_AN_ERROR = [
    pytest.param("policy-default", "worker", "0/3/20", ALL_RESOLVE, 200, DASH, "defer", DASH,
                 id="a well-formed request that must wait"),
    pytest.param("policy-default", "reviewer", "0/0/0", TRANSIENT, 503, "credential-transient", DASH, "20",
                 id="the kube API is away while resolving the credential"),
]


@pytest.mark.parametrize(("world", "role", "active", "credential", "expected_status", "expected_code", "expected_decision", "expected_retry_after_header"), NOT_AN_ERROR)
async def test_a_defer_is_200_a_transient_fault_is_503(gw, app, secrets, world, role, active, credential,
                                                       expected_status, expected_code, expected_decision, expected_retry_after_header):
    enter_world(world)
    inputs(role=role, active=active, credential=credential)
    await fill_rails(gw, active, DEFAULT_RAILS)
    await set_credential(app, secrets, credential)
    body = {"stack": "platform", "role": role, "task": TASK}
    with when(f"POST /sessions {body}"):
        r = await gw.post("/sessions", json=body)
    doc = r.json()
    view = {"status": r.status_code, "code": err(r) if r.status_code >= 400 else None,
            "decision": doc.get("decision"), "retry_after_header": r.headers.get("retry-after")}
    expect(view, status=expected_status, code=expected_code, decision=expected_decision, retry_after_header=expected_retry_after_header)


# -- counting ---------------------------------------------------------------------------------------
COUNTING = [
    pytest.param("policy-default", 0, "a worker dispatch", 1, id="a dispatch counts on its rail"),
    pytest.param("policy-default", 1, "DELETE", 0, id="a release frees the slot"),
    pytest.param("policy-default", 1, "expires_at passes", 0, id="an expiry frees the slot without a DELETE"),
    pytest.param("policy-default", 3, "a worker defer", 3, id="a defer counts nothing"),
]


@pytest.mark.parametrize(("world", "before", "action", "expected_gauge"), COUNTING)
async def test_counting(gw, policy, clock, world, before, action, expected_gauge):
    enter_world(world)
    inputs(before=before, action=action)
    docs = []
    with given(f"before = {before}: rail opencode holds {before} active sessions"):
        with quiet():
            for i in range(before):
                docs.append(await open_session(gw, task=f"before-{i}", rail="opencode"))
        check("gateway_sessions_active{rail=opencode} before", await _active(gw, "opencode"), before)
    with when(f"action = {action}"):
        if action == "a worker dispatch":
            await open_session(gw, task=TASK)
        elif action == "DELETE":
            await gw.delete(f"/sessions/{docs[0]['session']['id']}")
        elif action == "expires_at passes":
            clock.advance(policy.session_ttl_s + 1)
        elif action == "a worker defer":
            r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": TASK, "rail": "opencode"})
            assert r.json()["decision"] == "defer", r.text
    expect({"gauge": await _active(gw, "opencode")}, gauge=expected_gauge)
