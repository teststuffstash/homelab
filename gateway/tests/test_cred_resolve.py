"""GW-CRED-RESOLVE — credential ref -> Secret read, caches, verdict classes (specs/endpoints/sessions.md).

| description | rail | the Secret read returns | verdict | admission | data plane | gateway_credential_resolve_total{rail,outcome} |
|---|---|---|---|---|---|---|
| a labeled Secret with the rail's key (anthropic) | anthropic | 200, label true, AUTH_TOKEN present | resolved | eligible | served | anthropic, resolved |
| a labeled Secret with the rail's key (openrouter) | openrouter | 200, label true, OPENROUTER_API_KEY present | resolved | eligible | served | openrouter, resolved |
| the Secret is missing | openrouter | 404 | definitive | skipped (defer credential-unresolved if last) | 401 credential-unresolved | openrouter, definitive |
| RBAC refuses the read | anthropic | 403 | definitive | skipped | 401 credential-unresolved | anthropic, definitive |
| the Secret exists but is unlabeled | anthropic | 200, no label | definitive (refused: not a session key) | skipped | 401 credential-unresolved | anthropic, definitive |
| the Secret is labeled but the rail's key is absent | openrouter | 200, label true, only AUTH_TOKEN | definitive | skipped | 401 credential-unresolved | openrouter, definitive |
| the API server fails | anthropic | 503 | transient | 503 credential-transient | 503 credential-transient | anthropic, transient |
| the API server is unreachable | openrouter | connection refused / timeout | transient | 503 credential-transient | 503 credential-transient | openrouter, transient |
| the Go key is the gateway's own mount | opencode | (no read) | resolved from OPENCODE_GO_API_KEY | eligible | served | opencode, resolved |
| the Go mount is empty | opencode | (no read), env unset | definitive | skipped | 401 credential-unresolved | opencode, definitive |

| description | sequence | kube reads | reason |
|---|---|---|---|
| a resolved ref is cached | resolve, resolve again within 300 s | 1 | positive TTL 300 s |
| a positive entry expires | resolve, advance 301 s, resolve | 2 | positive TTL elapsed |
| a miss is cached briefly | 404, resolve again within 20 s | 1 | negative TTL 20 s |
| a miss expires fast | 404, advance 21 s, resolve | 2 | negative TTL elapsed |
| a transient never poisons a stack's other rail | anthropic transient, then openrouter | the openrouter read happens | verdicts are per ref |
"""

from __future__ import annotations

import re

import pytest

from agent_gateway.credentials import (
    CredentialResolver,
    CredentialTransient,
    CredentialUnresolved,
    StaticSecrets,
)

from .conftest import ANTHROPIC_TOKEN, GO_KEY, OPENROUTER_KEY, Clock, bearer, err, open_session, rule

pytestmark = rule("GW-CRED-RESOLVE")

OR_REF = "platform-agents/platform-openrouter"
SUB_REF = "platform-agents/claude-session"
# (rail → an admission that lands on that rail ONLY, so the verdict decides the answer)
ONLY = {"anthropic": {"role": "prober", "harness": "claude"}, "openrouter": {"role": "worker", "harness": "goose", "rail": "openrouter"},
        "opencode": {"role": "worker", "harness": "opencode", "rail": "opencode"}}
PATH = {"anthropic": "/anthropic/v1/messages", "openrouter": "/openai/v1/chat/completions", "opencode": "/openai/v1/chat/completions"}


def _resolver(policy, secrets, clock, go_key=GO_KEY):
    return CredentialResolver(policy, secrets, go_key, cache_s=300, negative_cache_s=20, clock=clock)


def _counter(text: str, rail: str, outcome: str) -> int:
    m = re.search(rf'^gateway_credential_resolve_total\{{rail="{rail}",outcome="{outcome}"\}} (\d+)$', text, re.M)
    return int(m.group(1)) if m else 0


ROWS = [
    ("a labeled Secret with the rail's key (anthropic)", "anthropic", "labelled", "resolved"),
    ("a labeled Secret with the rail's key (openrouter)", "openrouter", "labelled", "resolved"),
    ("the Secret is missing", "openrouter", "absent", "definitive"),
    ("RBAC refuses the read", "anthropic", "absent", "definitive"),
    ("the Secret exists but is unlabeled", "anthropic", "unlabelled", "definitive"),
    ("the Secret is labeled but the rail's key is absent", "openrouter", "wrong-key", "definitive"),
    ("the API server fails", "anthropic", "transient", "transient"),
    ("the API server is unreachable", "openrouter", "transient", "transient"),
    ("the Go key is the gateway's own mount", "opencode", "labelled", "resolved"),
    ("the Go mount is empty", "opencode", "no-env", "definitive"),
]


def _arrange(secrets, app, rail: str, state: str):
    ref = SUB_REF if rail == "anthropic" else OR_REF
    if state == "absent":
        secrets.secrets.pop(ref)
    elif state == "unlabelled":
        secrets.secrets[ref] = StaticSecrets.secret(ANTHROPIC_TOKEN, "AUTH_TOKEN", labelled=False)
    elif state == "wrong-key":
        secrets.secrets[ref] = StaticSecrets.secret(ANTHROPIC_TOKEN, "AUTH_TOKEN")
    elif state == "transient":
        secrets.transient.add(ref)
    elif state == "no-env":
        app.state.resolver.opencode_go_api_key = None
    app.state.resolver.forget()


@pytest.mark.parametrize(("rail", "state", "verdict"), [r[1:] for r in ROWS], ids=[r[0] for r in ROWS])
async def test_verdicts(gw, app, secrets, upstreams, rail, state, verdict):
    # data plane first: a session admitted while the ref was good, then the read changes
    doc = await open_session(gw, **ONLY[rail])
    _arrange(secrets, app, rail, state)
    r = await gw.post(PATH[rail], json={"messages": []}, headers=bearer(doc))
    expected = {"resolved": (200, None), "definitive": (401, "credential-unresolved"), "transient": (503, "credential-transient")}[verdict]
    assert r.status_code == expected[0], r.text
    if expected[1]:
        assert err(r) == expected[1]
    if rail == "opencode":
        assert secrets.calls == [] or all(c == SUB_REF for c in secrets.calls)  # the Go key is never a kube read
    # admission with the same read
    r2 = await gw.post("/sessions", json={"stack": "platform", "task": "t2", **ONLY[rail]})
    if verdict == "resolved":
        assert r2.json()["decision"] == "dispatch"
    elif verdict == "definitive":
        assert r2.json() == {"decision": "defer", "reason": "credential-unresolved", "retry_after_s": 60}
    else:
        assert r2.status_code == 503 and err(r2) == "credential-transient"
    text = (await gw.get("/metrics")).text
    assert _counter(text, rail, verdict) >= 1


async def test_resolved_cached(policy, secrets):
    """row: a resolved ref is cached"""
    clock = Clock()
    res = _resolver(policy, secrets, clock)
    sp = policy.stacks["platform"]
    await res.resolve("openrouter", sp)
    clock.advance(299)
    assert await res.resolve("openrouter", sp) == OPENROUTER_KEY
    assert secrets.calls == [OR_REF] and res.last_reason == "ok-cached" and res.last_outcome == "resolved"


async def test_positive_expires(policy, secrets):
    """row: a positive entry expires"""
    clock = Clock()
    res = _resolver(policy, secrets, clock)
    sp = policy.stacks["platform"]
    await res.resolve("openrouter", sp)
    clock.advance(301)
    await res.resolve("openrouter", sp)
    assert secrets.calls == [OR_REF, OR_REF]


async def test_miss_cached_briefly(policy, secrets):
    """row: a miss is cached briefly"""
    clock = Clock()
    secrets.secrets.pop(OR_REF)
    res = _resolver(policy, secrets, clock)
    sp = policy.stacks["platform"]
    with pytest.raises(CredentialUnresolved):
        await res.resolve("openrouter", sp)
    clock.advance(19)
    with pytest.raises(CredentialUnresolved):
        await res.resolve("openrouter", sp)
    assert secrets.calls == [OR_REF] and res.last_reason == "cached-miss"


async def test_miss_expires_fast(policy, secrets):
    """row: a miss expires fast"""
    clock = Clock()
    saved = secrets.secrets.pop(OR_REF)
    res = _resolver(policy, secrets, clock)
    sp = policy.stacks["platform"]
    with pytest.raises(CredentialUnresolved):
        await res.resolve("openrouter", sp)
    clock.advance(21)
    secrets.secrets[OR_REF] = saved
    assert await res.resolve("openrouter", sp) == OPENROUTER_KEY
    assert secrets.calls == [OR_REF, OR_REF]


async def test_transient_per_ref(policy, secrets):
    """row: a transient never poisons a stack's other rail"""
    clock = Clock()
    secrets.transient.add(SUB_REF)
    res = _resolver(policy, secrets, clock)
    sp = policy.stacks["platform"]
    with pytest.raises(CredentialTransient):
        await res.resolve("anthropic", sp)
    assert await res.resolve("openrouter", sp) == OPENROUTER_KEY
    assert secrets.calls == [SUB_REF, OR_REF]
