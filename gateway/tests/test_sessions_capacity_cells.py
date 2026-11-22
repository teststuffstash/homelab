"""GW-SESSIONS-CAPACITY — the cell cooldown, the rejected credential and its recovery without traffic:
the gateway's own transport facts as admission rows (specs/endpoints/sessions.md §Admission →
GW-SESSIONS-CAPACITY). T0 = 1_800_000_000 (the conftest Clock). Every arranged 429 / 401 reaches the
gateway through the data plane (a session + one /anthropic/v1/messages call the fake answers as the
row says), never by seeding. `upstream-429-reset` sends OpenRouter's shape — `x-ratelimit-*` with the
reset in epoch MILLISECONDS and no `retry-after` (the 2026-10-17 free-model experiment's tap).
Header == argnames, description == id (tests/_rows.py)."""

from __future__ import annotations

import re

import pytest

from agent_gateway.credentials import StaticSecrets

from ._rows import DASH, POLICY, body_of, enter_world, expect, inputs
from .conftest import OPENROUTER_KEY, attach_json, bearer, given, open_session, quiet, rule, when

pytestmark = rule("GW-SESSIONS-CAPACITY")

TASK = "homelab-2650-r1"


async def _ride(gw, upstreams, clock, *, rail: str, role: str, behaviour: str, stack: str = "platform",
                reset_in: int | None = None, retry_after: str | None = None, doc=None, task: str | None = None):
    """Arrange through the data plane: one ride on `rail` (the role's harness, from the picked cell)
    answered by the fake as stated — the request rides the anthropic dialect either way."""
    if doc is None:
        with quiet():
            doc = await open_session(gw, stack=stack, role=role, rail=rail, task=task or f"arrange-{rail}-{role}-{stack}")
    up = upstreams[rail]
    up.behaviour = behaviour
    up.reset_ms = int((clock.t + reset_in) * 1000) if reset_in is not None else None
    up.retry_after = retry_after
    with quiet():
        r = await gw.post("/anthropic/v1/messages", headers=bearer(doc),
                          json={"max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]})
    reset_ms = up.reset_ms
    up.behaviour, up.reset_ms, up.retry_after = "upstream-ok", None, None
    attach_json(f"arranged ride: {stack} {role} on {rail} → {r.status_code}",
                {"session": doc["session"]["id"], "rail": rail, "model": doc["model"],
                 "upstream": {"behaviour": behaviour, "x-ratelimit-reset (ms)": reset_ms, "retry-after": retry_after},
                 "gateway_status": r.status_code, "retry_after": r.headers.get("retry-after")})
    return doc


async def _admit(gw, body: dict) -> dict:
    req = {"stack": "platform", "role": "worker", "task": TASK, **body}
    with when(f"POST /sessions {req}"):
        r = await gw.post("/sessions", json=req)
    assert r.status_code == 200, r.text
    return r.json()


def _seconds(then: str) -> int:
    return 0 if then == DASH else int(re.fullmatch(r"\+(\d+) s.*", then).group(1))


# `arrange` cell → the rides, in order: (rail, role, behaviour, extra) — "same" = the same session
# answers again; ("secret", …) = a Secret change between the rides and the ask.
ARRANGE = {
    "worker ride on openrouter → 429, reset T0 + 42 s": [("openrouter", "worker", "upstream-429-reset", {"reset_in": 42})],
    "the same, plus retry-after: 30": [("openrouter", "worker", "upstream-429-reset", {"reset_in": 42, "retry_after": "30"})],
    "worker ride on openrouter → 429, no header": [("openrouter", "worker", "upstream-429-no-header", {})],
    "worker ride on openrouter → 429, reset T0 + 42 s, the same session → 200": [
        ("openrouter", "worker", "upstream-429-reset", {"reset_in": 42}), ("same", "worker", "upstream-ok", {})],
    "researcher ride on openrouter → 429 (the heavy cell)": [("openrouter", "researcher", "upstream-429-reset", {"reset_in": 42})],
    "reviewer ride on anthropic → 429 (retry-after: 30)": [("anthropic", "reviewer", "upstream-429", {})],
    "worker ride on opencode → upstream-401-key-expired": [("opencode", "worker", "upstream-401-key-expired", {})],
    "prober ride on anthropic → upstream-401": [("anthropic", "prober", "upstream-401", {})],
    "platform worker ride on openrouter → upstream-401 (oracle's key differs)": [
        ("secret", "oracle-agents/oracle-openrouter", "sk-or-v1-test-oracle-own-key"), ("openrouter", "worker", "upstream-401", {})],
    "platform worker ride on openrouter → upstream-401; the Secret then holds a new key": [
        ("openrouter", "worker", "upstream-401", {}), ("secret", "platform-agents/platform-openrouter", OPENROUTER_KEY + "-rotated")],
    "platform worker ride on openrouter → upstream-401, the same session → 200": [
        ("openrouter", "worker", "upstream-401", {}), ("same", "worker", "upstream-ok", {})],
    "worker ride on openrouter → upstream-403-refused": [("openrouter", "worker", "upstream-403-refused", {})],
    "worker ride on opencode → upstream-403-edge": [("opencode", "worker", "upstream-403-edge", {})],
    "prober ride on anthropic → upstream-401; +900 s; prober ride on anthropic → upstream-401 again": [
        ("anthropic", "prober", "upstream-401", {}), ("advance", 900), ("anthropic", "prober", "upstream-401", {"task": "arrange-second-ride"})],
}


async def _arrange(gw, upstreams, clock, secrets, arrange: str) -> None:
    with given(f"arrange = {arrange}"):
        doc = None
        for step in ARRANGE[arrange]:
            if step[0] == "secret":
                _, ref, value = step
                secrets.secrets[ref] = StaticSecrets.secret(value, "OPENROUTER_API_KEY")
                attach_json(f"the Secret {ref} now holds another key", {"ref": ref})
                continue
            if step[0] == "advance":
                clock.advance(step[1])
                continue
            rail, role, behaviour, extra = step
            doc = await _ride(gw, upstreams, clock, rail=doc["rail"] if rail == "same" else rail, role=role, behaviour=behaviour,
                              doc=doc if rail == "same" else None, **extra)


# -- the cell cooldown ------------------------------------------------------------------------------
CELL_ROWS = [
    pytest.param("policy-default · upstream-429-reset", "worker ride on openrouter → 429, reset T0 + 42 s", DASH, "worker", "openrouter", POLICY,
                 "defer", DASH, "cell-cooled", 42, id="a 429 cools its cell until x-ratelimit-reset (epoch ms)"),
    pytest.param("policy-default · upstream-429-reset", "the same, plus retry-after: 30", DASH, "worker", "openrouter", POLICY,
                 "defer", DASH, "cell-cooled", 30, id="retry-after outranks x-ratelimit-reset"),
    pytest.param("policy-default · upstream-429-no-header", "worker ride on openrouter → 429, no header", DASH, "worker", "openrouter", POLICY,
                 "defer", DASH, "cell-cooled", 60, id="a 429 that names no reset cools for defer_retry_s ⚖"),
    pytest.param("policy-default · upstream-429-reset", "worker ride on openrouter → 429, reset T0 + 42 s", DASH, "worker", "openrouter", "heavy",
                 "dispatch", "openrouter", DASH, DASH, id="another model on the rail is not cooled"),
    pytest.param("policy-default · upstream-429-reset", "worker ride on openrouter → 429, reset T0 + 42 s", "+42 s", "worker", "openrouter", POLICY,
                 "dispatch", "openrouter", DASH, DASH, id="the cell admits again at its reset"),
    pytest.param("policy-default · upstream-429-reset", "worker ride on openrouter → 429, reset T0 + 42 s, the same session → 200", DASH, "worker", "openrouter", POLICY,
                 "dispatch", "openrouter", DASH, DASH, id="a 2xx on the cell clears it"),
    pytest.param("policy-default · upstream-429-reset", "researcher ride on openrouter → 429 (the heavy cell)", DASH, "researcher", POLICY, POLICY,
                 "dispatch", "anthropic", DASH, DASH, id="a cooled cell is skipped, the walk continues"),
    pytest.param("policy-default · upstream-429", "reviewer ride on anthropic → 429 (retry-after: 30)", DASH, "reviewer", "anthropic", POLICY,
                 "defer", DASH, "rail-latched", 30, id="a subscription 429 latches the rail and cools the cell: the latch names the defer ⚖"),
]


@pytest.mark.parametrize(("world", "arrange", "then", "role", "rail", "tier", "expected_decision", "expected_rail", "expected_reason", "expected_retry_after_s"), CELL_ROWS)
async def test_the_cell_cooldown(gw, upstreams, clock, secrets, world, arrange, then, role, rail, tier,
                                 expected_decision, expected_rail, expected_reason, expected_retry_after_s):
    enter_world(world)
    inputs(arrange=arrange, then=then, role=role, rail=rail, tier=tier)
    await _arrange(gw, upstreams, clock, secrets, arrange)
    with given(f"then = {then}: {_seconds(then)} s pass"):
        clock.advance(_seconds(then))
    doc = await _admit(gw, body_of(role=role, rail=rail, tier=tier))
    expect(doc, decision=expected_decision, rail=expected_rail, reason=expected_reason, retry_after_s=expected_retry_after_s)


# -- a rejected credential --------------------------------------------------------------------------
CRED_ROWS = [
    pytest.param("policy-default · upstream-401-key-expired", "worker ride on opencode → upstream-401-key-expired", DASH, "platform", "worker", POLICY,
                 "dispatch", "openrouter", DASH, DASH, id="a rejected credential is skipped, the walk continues"),
    pytest.param("policy-default · upstream-401", "prober ride on anthropic → upstream-401", DASH, "platform", "prober", POLICY,
                 "defer", DASH, "credential-rejected", 900, id="every allowed rail's credential rejected defers credential-rejected ⚖"),
    pytest.param("policy-default · upstream-401", "platform worker ride on openrouter → upstream-401 (oracle's key differs)", DASH, "oracle", "worker", "openrouter",
                 "dispatch", "openrouter", DASH, DASH, id="a rejection is per credential: another stack's key still admits"),
    pytest.param("policy-default · upstream-401", "platform worker ride on openrouter → upstream-401; the Secret then holds a new key", "+301 s (the ref cache)", "platform", "worker", "openrouter",
                 "dispatch", "openrouter", DASH, DASH, id="a new credential value clears it"),
    pytest.param("policy-default · upstream-401", "platform worker ride on openrouter → upstream-401, the same session → 200", DASH, "platform", "worker", "openrouter",
                 "dispatch", "openrouter", DASH, DASH, id="a 2xx on the credential clears it"),
    pytest.param("policy-default · upstream-403-refused", "worker ride on openrouter → upstream-403-refused", DASH, "platform", "worker", "openrouter",
                 "dispatch", "openrouter", DASH, DASH, id="a policy refusal does not reject the credential"),
]


@pytest.mark.parametrize(("world", "arrange", "then", "stack", "role", "rail", "expected_decision", "expected_rail", "expected_reason", "expected_retry_after_s"), CRED_ROWS)
async def test_a_rejected_credential(gw, upstreams, clock, secrets, world, arrange, then, stack, role, rail,
                                     expected_decision, expected_rail, expected_reason, expected_retry_after_s):
    enter_world(world)
    inputs(arrange=arrange, then=then, stack=stack, role=role, rail=rail)
    await _arrange(gw, upstreams, clock, secrets, arrange)
    with given(f"then = {then}: {_seconds(then)} s pass"):
        clock.advance(_seconds(then))
    doc = await _admit(gw, {"stack": stack, **body_of(role=role, rail=rail)})
    expect(doc, decision=expected_decision, rail=expected_rail, reason=expected_reason, retry_after_s=expected_retry_after_s)


# -- a rejected credential recovers WITHOUT traffic (the 2026-10-17 self-latch's fix) ------------------
# opencode declares `credential_probe` (POST /v1/chat/completions, 1 token, backoff [60, 3600]);
# anthropic declares none → `credential_hold_s` 900, half-open. `probe_answers` = what the upstream
# answers the re-probe pass (`—` = no pass is run); `probes_sent?` = the probes that pass sent.
RECOVER_ROWS = [
    pytest.param("policy-default · upstream-401-key-expired", "worker ride on opencode → upstream-401-key-expired", "+60 s", "worker", "opencode", "upstream-ok",
                 1, "dispatch", "opencode", DASH, DASH, id="a probe's 2xx clears a rejected credential without traffic"),
    pytest.param("policy-default · upstream-401-key-expired", "worker ride on opencode → upstream-401-key-expired", "+60 s", "worker", "opencode", "upstream-401-key-expired",
                 1, "defer", DASH, "credential-rejected", 120, id="a probe rejected again doubles the backoff"),
    pytest.param("policy-default · upstream-401-key-expired", "worker ride on opencode → upstream-401-key-expired", "+60 s", "worker", "opencode", "upstream-500",
                 1, "defer", DASH, "credential-rejected", 60, id="a probe with no verdict keeps the backoff ⚖"),
    pytest.param("policy-default · upstream-401-key-expired", "worker ride on opencode → upstream-401-key-expired", "+30 s", "worker", "opencode", "upstream-ok",
                 0, "defer", DASH, "credential-rejected", 30, id="a probe is not sent before it is due"),
    pytest.param("policy-default · upstream-401", "prober ride on anthropic → upstream-401", "+900 s", "prober", POLICY, "upstream-ok",
                 0, "dispatch", "anthropic", DASH, DASH, id="a rail with no probe is re-admitted half-open after its hold ⚖"),
    pytest.param("policy-default · upstream-401", "prober ride on anthropic → upstream-401; +900 s; prober ride on anthropic → upstream-401 again", DASH, "prober", POLICY, DASH,
                 DASH, "defer", DASH, "credential-rejected", 1800, id="a repeat rejection after half-open doubles the hold"),
    pytest.param("policy-default · upstream-403-edge", "worker ride on opencode → upstream-403-edge", DASH, "worker", "opencode", "upstream-ok",
                 0, "dispatch", "opencode", DASH, DASH, id="an edge refusal marks nothing: the rail keeps admitting"),
]


@pytest.mark.parametrize(("world", "arrange", "then", "role", "rail", "probe_answers",
                          "expected_probes_sent", "expected_decision", "expected_rail", "expected_reason", "expected_retry_after_s"), RECOVER_ROWS)
async def test_recovery_without_traffic(gw, app, upstreams, clock, secrets, world, arrange, then, role, rail, probe_answers,
                                        expected_probes_sent, expected_decision, expected_rail, expected_reason, expected_retry_after_s):
    enter_world(world)
    inputs(arrange=arrange, then=then, role=role, rail=rail, probe_answers=probe_answers)
    await _arrange(gw, upstreams, clock, secrets, arrange)
    sent = DASH
    with given(f"then = {then}: {_seconds(then)} s pass; probe_answers = {probe_answers}"
               + (": the re-probe pass runs on the test clock" if probe_answers != DASH else ": no re-probe pass")):
        clock.advance(_seconds(then))
        if probe_answers != DASH:
            probed_rail = rail if rail != POLICY else "anthropic"
            upstreams[probed_rail].behaviour = probe_answers
            with quiet():
                sent = await app.state.proxy.reprobe()
            upstreams[probed_rail].behaviour = "upstream-ok"
            attach_json("the re-probe pass", {"probes sent": sent})
    doc = await _admit(gw, body_of(role=role, rail=rail))
    expect({**doc, "probes_sent": sent}, probes_sent=expected_probes_sent, decision=expected_decision, rail=expected_rail,
           reason=expected_reason, retry_after_s=expected_retry_after_s)
