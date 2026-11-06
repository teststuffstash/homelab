"""GW-CRED-RESOLVE — credential ref → Secret read, caches, verdict classes (specs/endpoints/sessions.md
§Cross-cutting → GW-CRED-RESOLVE). Header == argnames, description == id (tests/_rows.py)."""

from __future__ import annotations

import re

import pytest

from agent_gateway.credentials import (
    CredentialResolver,
    CredentialTransient,
    CredentialUnresolved,
    StaticSecrets,
)

from ._rows import enter_world, expect, inputs
from .conftest import (
    ANTHROPIC_TOKEN,
    GO_KEY,
    Clock,
    attach_json,
    bearer,
    err,
    given,
    open_session,
    quiet,
    rule,
    when,
)

pytestmark = rule("GW-CRED-RESOLVE")

OR_REF = "platform-agents/platform-openrouter"
SUB_REF = "platform-agents/claude-session"
# (rail → an admission that lands on that rail ONLY, so the verdict decides the answer)
ONLY = {"anthropic": {"role": "prober", "harness": "claude"}, "openrouter": {"role": "worker", "harness": "goose", "rail": "openrouter"},
        "opencode": {"role": "worker", "harness": "opencode", "rail": "opencode"}}
PATH = {"anthropic": "/anthropic/v1/messages", "openrouter": "/openai/v1/chat/completions", "opencode": "/openai/v1/chat/completions"}
# `secret_read` cell → what the Secret source does with the ref
READS = {
    "200, label true, AUTH_TOKEN present": "labelled",
    "200, label true, OPENROUTER_API_KEY present": "labelled",
    "404": "absent",
    "403": "absent",
    "200, no label": "unlabelled",
    "200, label true, only AUTH_TOKEN": "wrong-key",
    "503": "transient",
    "connection refused / timeout": "transient",
    "(no read)": "labelled",
    "(no read), env unset": "no-env",
}
RESOLVED = "resolved"
DEFINITIVE = "definitive"
TRANSIENT = "transient"


def _resolver(policy, secrets, clock, go_key=GO_KEY):
    return CredentialResolver(policy, secrets, go_key, cache_s=300, negative_cache_s=20, clock=clock)


def _counter(text: str, rail: str, outcome: str) -> int:
    m = re.search(rf'^gateway_credential_resolve_total\{{rail="{rail}",outcome="{outcome}"\}} (\d+)$', text, re.M)
    return int(m.group(1)) if m else 0


def _arrange(secrets, app, rail: str, secret_read: str) -> None:
    state = READS[secret_read]
    ref = SUB_REF if rail == "anthropic" else OR_REF
    target = "the gateway's Go key mount" if rail == "opencode" else f"credential ref {ref}"
    with given(f"secret_read = {secret_read}: {target} is {state}"):
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
        attach_json(f"the Secret source after: {target} is {state}", {"ref": ref, "state": state, "secrets": sorted(secrets.secrets),
                                                                   "transient": sorted(secrets.transient),
                                                                   "go_key_mounted": app.state.resolver.opencode_go_api_key is not None})


VERDICT_ROWS = [
    pytest.param("policy-default · upstream-ok", "anthropic", "200, label true, AUTH_TOKEN present", RESOLVED, "dispatch", "200", "outcome=resolved ≥ 1",
                 id="a labeled Secret with the rail's key (anthropic)"),
    pytest.param("policy-default · upstream-ok", "openrouter", "200, label true, OPENROUTER_API_KEY present", RESOLVED, "dispatch", "200", "outcome=resolved ≥ 1",
                 id="a labeled Secret with the rail's key (openrouter)"),
    pytest.param("policy-default · upstream-ok", "openrouter", "404", DEFINITIVE, "defer credential-unresolved, retry_after_s 60", "401 credential-unresolved", "outcome=definitive ≥ 1",
                 id="the Secret is missing"),
    pytest.param("policy-default · upstream-ok", "anthropic", "403", DEFINITIVE, "defer credential-unresolved, retry_after_s 60", "401 credential-unresolved", "outcome=definitive ≥ 1",
                 id="RBAC refuses the read"),
    pytest.param("policy-default · upstream-ok", "anthropic", "200, no label", DEFINITIVE, "defer credential-unresolved, retry_after_s 60", "401 credential-unresolved", "outcome=definitive ≥ 1",
                 id="the Secret exists but is unlabeled"),
    pytest.param("policy-default · upstream-ok", "openrouter", "200, label true, only AUTH_TOKEN", DEFINITIVE, "defer credential-unresolved, retry_after_s 60", "401 credential-unresolved", "outcome=definitive ≥ 1",
                 id="the Secret is labeled but the rail's key is absent"),
    pytest.param("policy-default · upstream-ok", "anthropic", "503", TRANSIENT, "503 credential-transient", "503 credential-transient", "outcome=transient ≥ 1",
                 id="the API server fails"),
    pytest.param("policy-default · upstream-ok", "openrouter", "connection refused / timeout", TRANSIENT, "503 credential-transient", "503 credential-transient", "outcome=transient ≥ 1",
                 id="the API server is unreachable"),
]
GO_ROWS = [
    pytest.param("policy-default · upstream-ok", "opencode", "(no read)", RESOLVED, "dispatch", "200", "outcome=resolved ≥ 1",
                 id="the Go key is the gateway's own mount"),
    pytest.param("policy-default · upstream-ok", "opencode", "(no read), env unset", DEFINITIVE, "defer credential-unresolved, retry_after_s 60", "401 credential-unresolved", "outcome=definitive ≥ 1",
                 id="the Go mount is empty"),
]


async def _verdicts(gw, app, secrets, world, rail, secret_read, expected):
    enter_world(world)
    inputs(rail=rail, secret_read=secret_read)
    # data plane first: a session admitted while the ref was good, then the read changes
    with given(f"a session on rail {rail} admitted while the ref was good ({ONLY[rail]})"):
        with quiet():
            doc = await open_session(gw, **ONLY[rail])
        attach_json(f"arranged session on {rail}", {"request": ONLY[rail], "decision": doc["decision"], "rail": doc["rail"], "session": doc["session"]["id"]})
    _arrange(secrets, app, rail, secret_read)
    with when(f"POST {PATH[rail]} on the rail {rail} session, then POST /sessions {ONLY[rail]} with the same read"):
        r = await gw.post(PATH[rail], json={"messages": []}, headers=bearer(doc))
        with quiet():
            r2 = await gw.post("/sessions", json={"stack": "platform", "task": "t2", **ONLY[rail]})
            metrics = (await gw.get("/metrics")).text
    data_plane = f"{r.status_code}" + (f" {err(r)}" if r.status_code >= 400 else "")
    if r2.status_code == 200:
        d = r2.json()
        admission = d["decision"] + (f" {d['reason']}, retry_after_s {d['retry_after_s']}" if d["decision"] == "defer" else "")
    else:
        admission = f"{r2.status_code} {err(r2)}"
    verdict = next((v for v in (RESOLVED, DEFINITIVE, TRANSIENT) if _counter(metrics, rail, v) >= 1 and v == expected["verdict"]), None)
    if verdict is None:
        verdict = ", ".join(f"{v} {_counter(metrics, rail, v)}" for v in (RESOLVED, DEFINITIVE, TRANSIENT))
    total = f"outcome={expected['verdict']} ≥ 1" if _counter(metrics, rail, expected["verdict"]) >= 1 else f"outcome={expected['verdict']} = 0"
    if rail == "opencode":
        assert secrets.calls == [] or all(c == SUB_REF for c in secrets.calls), secrets.calls  # the Go key is never a kube read
    expect({"verdict": verdict, "admission": admission, "data_plane": data_plane, "resolve_total": total}, **expected)


@pytest.mark.parametrize(("world", "rail", "secret_read", "expected_verdict", "expected_admission", "expected_data_plane", "expected_resolve_total"), VERDICT_ROWS)
async def test_the_reads_verdict(gw, app, secrets, world, rail, secret_read, expected_verdict, expected_admission, expected_data_plane, expected_resolve_total):
    await _verdicts(gw, app, secrets, world, rail, secret_read,
                    {"verdict": expected_verdict, "admission": expected_admission, "data_plane": expected_data_plane, "resolve_total": expected_resolve_total})


@pytest.mark.parametrize(("world", "rail", "secret_read", "expected_verdict", "expected_admission", "expected_data_plane", "expected_resolve_total"), GO_ROWS)
async def test_the_go_key(gw, app, secrets, world, rail, secret_read, expected_verdict, expected_admission, expected_data_plane, expected_resolve_total):
    await _verdicts(gw, app, secrets, world, rail, secret_read,
                    {"verdict": expected_verdict, "admission": expected_admission, "data_plane": expected_data_plane, "resolve_total": expected_resolve_total})


# -- the caches --------------------------------------------------------------------------------------------
CACHE_ROWS = [
    pytest.param("policy-default", "resolve openrouter, +299 s, resolve again", "platform-openrouter", id="a resolved ref is cached"),
    pytest.param("policy-default", "resolve openrouter, +301 s, resolve again", "platform-openrouter, platform-openrouter", id="a positive entry expires"),
    pytest.param("policy-default", "the ref missing: resolve openrouter, +19 s, resolve again", "platform-openrouter", id="a miss is cached briefly"),
    pytest.param("policy-default", "the ref missing: resolve openrouter, +21 s (the ref restored), resolve again", "platform-openrouter, platform-openrouter",
                 id="a miss expires fast"),
    pytest.param("policy-default", "the anthropic ref transient: resolve anthropic, then resolve openrouter", "claude-session, platform-openrouter",
                 id="a transient never poisons a stack's other rail ⚖"),
]


@pytest.mark.parametrize(("world", "sequence", "expected_kube_reads"), CACHE_ROWS)
async def test_the_caches(policy, secrets, world, sequence, expected_kube_reads):
    enter_world(world)
    inputs(sequence=sequence)
    clock = Clock()
    res = _resolver(policy, secrets, clock)
    sp = policy.stacks["platform"]
    with given(f"sequence = {sequence}: a resolver (cache 300 s, negative cache 20 s) and everything before the last resolve"):
        if sequence.startswith("the ref missing"):
            saved = secrets.secrets.pop(OR_REF)
            with pytest.raises(CredentialUnresolved):
                await res.resolve("openrouter", sp)
            clock.advance(19 if "+19" in sequence else 21)
            if "restored" in sequence:
                secrets.secrets[OR_REF] = saved
        elif sequence.startswith("the anthropic ref transient"):
            secrets.transient.add(SUB_REF)
            with pytest.raises(CredentialTransient):
                await res.resolve("anthropic", sp)
        else:
            await res.resolve("openrouter", sp)
            clock.advance(299 if "+299" in sequence else 301)
        attach_json("kube reads so far", list(secrets.calls))
    with when("resolve(openrouter, platform)"):
        if "+19" in sequence:
            with pytest.raises(CredentialUnresolved) as exc:
                await res.resolve("openrouter", sp)
            attach_json("raised", {"raised": type(exc.value).__name__, "last_reason": res.last_reason})
        else:
            key = await res.resolve("openrouter", sp)
            assert key, key
            attach_json("resolved", {"last_reason": res.last_reason, "last_outcome": res.last_outcome})
    expect({"kube_reads": ", ".join(c.split("/", 1)[1] for c in secrets.calls)}, kube_reads=expected_kube_reads)
