"""GW-SESSIONS-ADMIT §Capacity — the cell cooldown and the rejected credential: the gateway's own
transport facts as admission rows (specs/endpoints/sessions.md).

World policy-default. T0 = 1_800_000_000 (the conftest Clock). Every arranged 429 / 401 reaches the
gateway through the data plane (a session + one /anthropic/v1/messages call the fake answers as the
row says), never by seeding. The `upstream-429-reset` fake sends OpenRouter's shape — `x-ratelimit-*`
with the reset in epoch MILLISECONDS and no `retry-after` (the 2026-10-17 free-model experiment's tap).

A 429 cools the (rail, model) cell (cell = the session's policy model):

| description | arrange | then | body || decision | rail | reason | retry_after_s |
|---|---|---|---||---|---|---|---|
| a 429 cools its cell until x-ratelimit-reset (epoch ms) | worker ride on openrouter → 429, reset T0 + 42 s | — | worker, rail openrouter || defer | — | cell-cooled | 42 |
| retry-after outranks x-ratelimit-reset | the same, plus retry-after: 30 | — | worker, rail openrouter || defer | — | cell-cooled | 30 |
| a 429 that names no reset cools for defer_retry_s | worker ride on openrouter → 429, no header | — | worker, rail openrouter || defer | — | cell-cooled | 60 |
| another model on the rail is not cooled | worker ride on openrouter → 429, reset T0 + 42 s | — | worker, rail openrouter, tier heavy || dispatch | openrouter | — | — |
| the cell admits again at its reset | worker ride on openrouter → 429, reset T0 + 42 s | +42 s | worker, rail openrouter || dispatch | openrouter | — | — |
| a 2xx on the cell clears it | worker ride on openrouter → 429, the same session → 200 | — | worker, rail openrouter || dispatch | openrouter | — | — |
| a cooled cell is skipped, the walk continues | researcher ride on openrouter → 429 (heavy cell) | — | researcher, harness claude (policy walk) || dispatch | anthropic | — | — |
| a subscription 429 latches the rail and cools the cell: the latch names the defer | reviewer ride on anthropic → 429 (retry-after 30) | — | reviewer, rail anthropic || defer | — | rail-latched | 30 |

An upstream 401/403 with a credential reason rejects THAT credential (rail + sha256 of the value):

| description | arrange | then | body || decision | rail | reason | retry_after_s |
|---|---|---|---||---|---|---|---|
| a rejected credential is skipped, the walk continues | worker ride on opencode → upstream-401-key-expired | — | worker (policy walk) || dispatch | openrouter | — | — |
| every allowed rail's credential rejected defers credential-rejected | prober ride on anthropic → upstream-401 | — | prober (policy walk) || defer | — | credential-rejected | 60 |
| a rejection is per credential: another stack's key still admits | platform worker ride on openrouter → upstream-401 | — | oracle worker, rail openrouter (its own key) || dispatch | openrouter | — | — |
| a new credential value clears it | platform worker ride on openrouter → upstream-401; the Secret then holds a new key | +301 s (the ref cache) | worker, rail openrouter || dispatch | openrouter | — | — |
| a 2xx on the credential clears it | platform worker ride on openrouter → upstream-401, the same session → 200 | — | worker, rail openrouter || dispatch | openrouter | — | — |
| a policy refusal does not reject the credential | worker ride on openrouter → upstream-403-refused | — | worker, rail openrouter || dispatch | openrouter | — | — |
"""

from __future__ import annotations

import pytest

from agent_gateway.credentials import StaticSecrets

from .conftest import (
    OPENROUTER_KEY,
    attach_json,
    bearer,
    given,
    open_session,
    quiet,
    rule,
    then,
    then_eq,
    when,
    world,
)

pytestmark = rule("GW-SESSIONS-ADMIT")


async def _ride(gw, upstreams, clock, *, rail: str, role: str, behaviour: str, stack: str = "platform",
                reset_in: int | None = None, retry_after: str | None = None, doc=None):
    """Arrange through the data plane: one claude-harness ride on `rail` answered by the fake as stated."""
    if doc is None:
        with quiet():
            doc = await open_session(gw, stack=stack, role=role, rail=rail, harness="claude", task=f"arrange-{rail}-{role}-{stack}")
    up = upstreams[rail]
    up.behaviour = behaviour
    up.reset_ms = int((clock.t + reset_in) * 1000) if reset_in is not None else None
    up.retry_after = retry_after
    with quiet():
        r = await gw.post("/anthropic/v1/messages", headers=bearer(doc),
                          json={"max_tokens": 8, "messages": [{"role": "user", "content": "hi"}]})
    up.behaviour, up.reset_ms, up.retry_after = "upstream-ok", None, None
    attach_json(f"arranged ride: {stack} {role} on {rail} → {r.status_code}",
                {"session": doc["session"]["id"], "rail": rail, "model": doc["model"],
                 "upstream": {"behaviour": behaviour, "x-ratelimit-reset (ms)": int((clock.t + reset_in) * 1000) if reset_in is not None else None,
                              "retry-after": retry_after},
                 "gateway_status": r.status_code, "retry_after": r.headers.get("retry-after")})
    return doc


async def _admit(gw, body: dict) -> dict:
    req = {"stack": "platform", "role": "worker", "task": "homelab-2650-r1", **body}
    with when(f"POST /sessions body {body}"):
        r = await gw.post("/sessions", json=req)
    then_eq("status", r.status_code, 200)
    return r.json()


def _verdict(doc: dict, expected: dict) -> None:
    claim = "expected " + ", ".join(f"{k} = {v}" for k, v in expected.items())
    with then(claim, **{k: {"expected": v, "actual": doc.get(k)} for k, v in expected.items()}):
        assert {k: doc.get(k) for k in expected} == expected, f"{claim}: got {doc}"


# arrange step = (rail, role, behaviour, extra); "same" = the same session answers next
CELL_ROWS = [
    ("a 429 cools its cell until x-ratelimit-reset (epoch ms)", [("openrouter", "worker", "upstream-429-reset", {"reset_in": 42})], 0,
     {"rail": "openrouter"}, {"decision": "defer", "reason": "cell-cooled", "retry_after_s": 42}),
    ("retry-after outranks x-ratelimit-reset", [("openrouter", "worker", "upstream-429-reset", {"reset_in": 42, "retry_after": "30"})], 0,
     {"rail": "openrouter"}, {"decision": "defer", "reason": "cell-cooled", "retry_after_s": 30}),
    # no reset on the wire, and openrouter declares no latch_429_hold_s → the policy's defer_retry_s (60)
    ("a 429 that names no reset cools for defer_retry_s", [("openrouter", "worker", "upstream-429-no-header", {})], 0,
     {"rail": "openrouter"}, {"decision": "defer", "reason": "cell-cooled", "retry_after_s": 60}),
    # the worker's standard tier = deepseek/deepseek-v4-flash is cooled; heavy = deepseek/deepseek-v4.1-flash is not
    ("another model on the rail is not cooled", [("openrouter", "worker", "upstream-429-reset", {"reset_in": 42})], 0,
     {"rail": "openrouter", "tier": "heavy"}, {"decision": "dispatch", "rail": "openrouter", "model": "deepseek/deepseek-v4.1-flash"}),
    ("the cell admits again at its reset", [("openrouter", "worker", "upstream-429-reset", {"reset_in": 42})], 42,
     {"rail": "openrouter"}, {"decision": "dispatch", "rail": "openrouter"}),
    ("a 2xx on the cell clears it", [("openrouter", "worker", "upstream-429-reset", {"reset_in": 42}), ("same", "worker", "upstream-ok", {})], 0,
     {"rail": "openrouter"}, {"decision": "dispatch", "rail": "openrouter"}),
    # researcher: rails [openrouter, anthropic], tier heavy → openrouter's deepseek-v4.1-flash cell cooled → anthropic
    ("a cooled cell is skipped, the walk continues", [("openrouter", "researcher", "upstream-429-reset", {"reset_in": 42})], 0,
     {"role": "researcher", "harness": "claude"}, {"decision": "dispatch", "rail": "anthropic"}),
    # the fake's upstream-429 sends retry-after: 30; latch and cell both free at +30 — the latch is listed first
    ("a subscription 429 latches the rail and cools the cell: the latch names the defer", [("anthropic", "reviewer", "upstream-429", {})], 0,
     {"role": "reviewer", "rail": "anthropic"}, {"decision": "defer", "reason": "rail-latched", "retry_after_s": 30}),
]


async def _arrange(gw, upstreams, clock, steps):
    doc = None
    for rail, role, behaviour, extra in steps:
        stack = extra.get("stack", "platform")
        with given(f"arrange: a {stack} {role} ride on {rail if rail != 'same' else 'the same session'} is answered {behaviour}"
                   + (f" {extra}" if extra else "")):
            kw = {k: v for k, v in extra.items() if k != "stack"}
            doc = await _ride(gw, upstreams, clock, rail=doc["rail"] if rail == "same" else rail, role=role, behaviour=behaviour,
                              stack=stack, doc=doc if rail == "same" else None, **kw)


@pytest.mark.parametrize(("arrange", "advance", "body", "expected"), [r[1:] for r in CELL_ROWS], ids=[r[0] for r in CELL_ROWS])
async def test_cell_cooldown(gw, upstreams, clock, arrange, advance, body, expected):
    world(upstream="upstream-429-reset", note="the arranged ride's answer; every other answer is upstream-ok")
    await _arrange(gw, upstreams, clock, arrange)
    with given(f"advance = {advance}: {advance} s pass"):
        clock.advance(advance)
    _verdict(await _admit(gw, body), expected)


CRED_ROWS = [
    ("a rejected credential is skipped, the walk continues", [("opencode", "worker", "upstream-401-key-expired", {})], 0, None,
     {}, {"decision": "dispatch", "rail": "openrouter"}),
    # prober: rails [anthropic] only, tier light (claude/haiku); no rail frees by time → defer_retry_s
    ("every allowed rail's credential rejected defers credential-rejected", [("anthropic", "prober", "upstream-401", {})], 0, None,
     {"role": "prober"}, {"decision": "defer", "reason": "credential-rejected", "retry_after_s": 60}),
    ("a rejection is per credential: another stack's key still admits", [("openrouter", "worker", "upstream-401", {})], 0, "oracle-own-key",
     {"stack": "oracle", "rail": "openrouter"}, {"decision": "dispatch", "rail": "openrouter"}),
    # the resolver caches a resolved ref for 300 s (GW-CRED-RESOLVE): the new value is read at +301 s
    ("a new credential value clears it", [("openrouter", "worker", "upstream-401", {})], 301, "platform-new-key",
     {"rail": "openrouter"}, {"decision": "dispatch", "rail": "openrouter"}),
    ("a 2xx on the credential clears it", [("openrouter", "worker", "upstream-401", {}), ("same", "worker", "upstream-ok", {})], 0, None,
     {"rail": "openrouter"}, {"decision": "dispatch", "rail": "openrouter"}),
    ("a policy refusal does not reject the credential", [("openrouter", "worker", "upstream-403-refused", {})], 0, None,
     {"rail": "openrouter"}, {"decision": "dispatch", "rail": "openrouter"}),
]


@pytest.mark.parametrize(("arrange", "advance", "secret", "body", "expected"), [r[1:] for r in CRED_ROWS], ids=[r[0] for r in CRED_ROWS])
async def test_credential_rejected(gw, upstreams, clock, secrets, arrange, advance, secret, body, expected):
    world(upstream=arrange[0][2], note="the arranged ride's answer; every other answer is upstream-ok")
    if secret == "oracle-own-key":
        with given("state: the oracle stack's OpenRouter Secret holds its OWN key (a different value from platform's)"):
            secrets.secrets["oracle-agents/oracle-openrouter"] = StaticSecrets.secret("sk-or-v1-test-oracle-own-key", "OPENROUTER_API_KEY")
    await _arrange(gw, upstreams, clock, arrange)
    if secret == "platform-new-key":
        with given("state: the platform OpenRouter Secret now holds a NEW key (a rotation)"):
            secrets.secrets["platform-agents/platform-openrouter"] = StaticSecrets.secret(OPENROUTER_KEY + "-rotated", "OPENROUTER_API_KEY")
    with given(f"advance = {advance}: {advance} s pass"):
        clock.advance(advance)
    _verdict(await _admit(gw, body), expected)
