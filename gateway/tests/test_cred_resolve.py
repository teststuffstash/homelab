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

from .conftest import (
    ANTHROPIC_TOKEN,
    GO_KEY,
    OPENROUTER_KEY,
    Clock,
    attach_json,
    bearer,
    check,
    err,
    given,
    open_session,
    quiet,
    rule,
    then,
    when,
    world,
)

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


def _reads(secrets, res=None) -> dict:
    out = {"kube_reads": list(secrets.calls)}
    if res is not None:
        out |= {"last_reason": res.last_reason, "last_outcome": res.last_outcome}
    return out


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
    target = "the gateway's Go key mount" if rail == "opencode" else f"credential ref {ref}"
    with given(f"state: {target} is {state}"):
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
        attach_json(f"state {state}: {target}", {"ref": ref, "state": state, "secrets": sorted(secrets.secrets),
                                                  "transient": sorted(secrets.transient),
                                                  "go_key_mounted": app.state.resolver.opencode_go_api_key is not None})


@pytest.mark.parametrize(("rail", "state", "verdict"), [r[1:] for r in ROWS], ids=[r[0] for r in ROWS])
async def test_verdicts(gw, app, secrets, upstreams, rail, state, verdict):
    world(upstream="upstream-ok")
    # data plane first: a session admitted while the ref was good, then the read changes
    with given(f"a session on rail {rail} admitted while the ref was good ({ONLY[rail]})"):
        doc = await open_session(gw, **ONLY[rail])
    _arrange(secrets, app, rail, state)
    with when(f"POST {PATH[rail]} on the rail {rail} session"):
        r = await gw.post(PATH[rail], json={"messages": []}, headers=bearer(doc))
    expected = {"resolved": (200, None), "definitive": (401, "credential-unresolved"), "transient": (503, "credential-transient")}[verdict]
    with then(f"verdict {verdict} on the data plane: status {expected[0]}" + (f", code {expected[1]}" if expected[1] else "")):
        check("(status, code)", (r.status_code, err(r) if expected[1] else None), expected)
    if rail == "opencode":
        with then("the Go key is never a kube read", secrets_calls={"expected": f"[] or only {SUB_REF}", "actual": list(secrets.calls)}):
            assert secrets.calls == [] or all(c == SUB_REF for c in secrets.calls)  # the Go key is never a kube read
    # admission with the same read
    want = {"resolved": "decision dispatch", "definitive": "decision defer, reason credential-unresolved, retry_after_s 60",
            "transient": "status 503, code credential-transient"}[verdict]
    with then(f"verdict {verdict} on admission with the same read: {want}"):
        r2 = await gw.post("/sessions", json={"stack": "platform", "task": "t2", **ONLY[rail]})
        if verdict == "resolved":
            check("decision", r2.json()["decision"], "dispatch")
        elif verdict == "definitive":
            check("admission", r2.json(), {"decision": "defer", "reason": "credential-unresolved", "retry_after_s": 60})
        else:
            check("(status, code)", (r2.status_code, err(r2)), (503, "credential-transient"))
    with then(f"gateway_credential_resolve_total{{rail={rail},outcome={verdict}}} ≥ 1"):
        with quiet():  # the counter value is the verdict below; the whole /metrics text is not the row
            n = _counter((await gw.get("/metrics")).text, rail, verdict)
        attach_json(f"verdict: gateway_credential_resolve_total{{rail={rail},outcome={verdict}}}", {"expected": ">= 1", "actual": n})
        assert n >= 1


async def test_resolved_cached(policy, secrets):
    """row: a resolved ref is cached"""
    world()
    clock = Clock()
    res = _resolver(policy, secrets, clock)
    sp = policy.stacks["platform"]
    with given(f"a resolver (cache 300 s) that resolved openrouter ref {OR_REF} once, then the clock +299 s"):
        await res.resolve("openrouter", sp)
        clock.advance(299)
        attach_json("reads after the first resolve", _reads(secrets, res))
    with when("resolve(openrouter, platform) again at +299 s"):
        key = await res.resolve("openrouter", sp)
    with then("the key is the openrouter key", key={"expected": "OPENROUTER_KEY", "actual_matches": key == OPENROUTER_KEY}):
        assert key == OPENROUTER_KEY
    with then(f"one kube read only ({OR_REF}), reason ok-cached, outcome resolved", reads={"expected": {"kube_reads": [OR_REF], "last_reason": "ok-cached", "last_outcome": "resolved"}, "actual": _reads(secrets, res)}):
        assert secrets.calls == [OR_REF] and res.last_reason == "ok-cached" and res.last_outcome == "resolved"


async def test_positive_expires(policy, secrets):
    """row: a positive entry expires"""
    world()
    clock = Clock()
    res = _resolver(policy, secrets, clock)
    sp = policy.stacks["platform"]
    with given(f"a resolver (cache 300 s) that resolved openrouter ref {OR_REF} once, then the clock +301 s"):
        await res.resolve("openrouter", sp)
        clock.advance(301)
        attach_json("reads after the first resolve", _reads(secrets))
    with when("resolve(openrouter, platform) again at +301 s"):
        await res.resolve("openrouter", sp)
    with then(f"a second kube read: {[OR_REF, OR_REF]}"):
        check("kube_reads", list(secrets.calls), [OR_REF, OR_REF])


async def test_miss_cached_briefly(policy, secrets):
    """row: a miss is cached briefly"""
    world()
    clock = Clock()
    with given(f"state: credential ref {OR_REF} is a definitive miss"):
        secrets.secrets.pop(OR_REF)
        attach_json(f"secrets after: {OR_REF} removed", sorted(secrets.secrets))
    res = _resolver(policy, secrets, clock)
    sp = policy.stacks["platform"]
    with given("a resolver (negative cache 20 s) whose first resolve raised CredentialUnresolved, then the clock +19 s"):
        with pytest.raises(CredentialUnresolved):
            await res.resolve("openrouter", sp)
        clock.advance(19)
    with when("resolve(openrouter, platform) again at +19 s"):
        with pytest.raises(CredentialUnresolved) as exc:
            await res.resolve("openrouter", sp)
        attach_json("raised", {"raised": type(exc.value).__name__})
    with then(f"one kube read only ({OR_REF}), reason cached-miss", reads={"expected": {"kube_reads": [OR_REF], "last_reason": "cached-miss"}, "actual": _reads(secrets, res)}):
        assert secrets.calls == [OR_REF] and res.last_reason == "cached-miss"


async def test_miss_expires_fast(policy, secrets):
    """row: a miss expires fast"""
    world()
    clock = Clock()
    with given(f"state: credential ref {OR_REF} is a definitive miss"):
        saved = secrets.secrets.pop(OR_REF)
        attach_json(f"secrets after: {OR_REF} removed", sorted(secrets.secrets))
    res = _resolver(policy, secrets, clock)
    sp = policy.stacks["platform"]
    with given(f"a resolver (negative cache 20 s) whose first resolve raised, then the clock +21 s and {OR_REF} restored"):
        with pytest.raises(CredentialUnresolved):
            await res.resolve("openrouter", sp)
        clock.advance(21)
        secrets.secrets[OR_REF] = saved
    with when("resolve(openrouter, platform) again at +21 s"):
        key = await res.resolve("openrouter", sp)
    with then("the key is the openrouter key", key={"expected": "OPENROUTER_KEY", "actual_matches": key == OPENROUTER_KEY}):
        assert key == OPENROUTER_KEY
    with then(f"a second kube read: {[OR_REF, OR_REF]}"):
        check("kube_reads", list(secrets.calls), [OR_REF, OR_REF])


async def test_transient_per_ref(policy, secrets):
    """row: a transient never poisons a stack's other rail"""
    world()
    clock = Clock()
    with given(f"state: credential ref {SUB_REF} answers a transient fault"):
        secrets.transient.add(SUB_REF)
        attach_json(f"secrets transient: {SUB_REF}", sorted(secrets.transient))
    res = _resolver(policy, secrets, clock)
    sp = policy.stacks["platform"]
    with given("a resolver whose anthropic resolve raised CredentialTransient"):
        with pytest.raises(CredentialTransient):
            await res.resolve("anthropic", sp)
    with when("resolve(openrouter, platform) — the stack's other rail"):
        key = await res.resolve("openrouter", sp)
    with then("the key is the openrouter key", key={"expected": "OPENROUTER_KEY", "actual_matches": key == OPENROUTER_KEY}):
        assert key == OPENROUTER_KEY
    with then(f"kube reads = {[SUB_REF, OR_REF]}"):
        check("kube_reads", list(secrets.calls), [SUB_REF, OR_REF])
