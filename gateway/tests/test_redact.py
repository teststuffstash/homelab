"""Credential redaction in the gateway's log lines (specs/endpoints/sessions.md §Cross-cutting → GW-REDACT).

The real-path log lines are the GW-REDACT rows (header == argnames, description == id — tests/_rows.py);
the formatter's own patterns, fed a bare string, are unlabelled chassis guards (conventions § Allure
taxonomy: only system-level cases are evidence).
"""

from __future__ import annotations

import logging

import pytest

from agent_gateway.logging import REDACTED, RedactingFormatter, redact, register_literal
from agent_gateway.pull import POD_NAME_EXTRA, Review

from ._rows import enter_world, expect, inputs
from .conftest import GO_KEY, attach_json, bearer, given, open_session, rule, then, when, world

TOKEN = "gws_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
FMT = RedactingFormatter("%(message)s")
JWT = "eyJhbGciOiJSUzI1NiJ9.eyJGQUtFIjoxfQ.RkFLRS1TSUc"  # fake, JWT-shaped (header.payload.sig)

ROWS = [
    ("a session token in a message", f"auth ok {TOKEN}", "auth ok <redacted>", "gws_"),
    ("an OAuth token", "inject sk-ant-oat01-FAKEFAKEFAKE", "inject <redacted>", "sk-ant-oat"),
    ("an OpenRouter key", "inject sk-or-v1-FAKEFAKEFAKE", "inject <redacted>", "sk-or-v1-"),
    ("a bearer header value", "Authorization: Bearer abc.def.ghi", "Authorization: Bearer <redacted>", "abc.def.ghi"),
    ("the Go key's value", f"go key {GO_KEY} in use", "go key <redacted> in use", GO_KEY),
    ("a ref is not a credential", "ref platform-agents/claude-session unresolved", "ref platform-agents/claude-session unresolved", REDACTED),
    ("a model id is not a credential", "model opencode-go/deepseek-v4.1-flash", "model opencode-go/deepseek-v4.1-flash", REDACTED),
    ("a projected ServiceAccount token (a JWT)", f"review {JWT}", "review <redacted>", "eyJ"),
]


def _system_row(fn):
    """Label a case as a GW-REDACT row: it observes a log line the gateway writes."""
    for mark in rule("GW-REDACT"):
        fn = mark(fn)
    return fn


@pytest.mark.parametrize(("line", "contains", "absent"), [r[1:] for r in ROWS], ids=[r[0] for r in ROWS])
def test_formatter_rows(line, contains, absent):
    world()
    with given("the Go key's value is registered as a literal to redact"):
        register_literal(GO_KEY)
    with when(f"format LogRecord line {line!r}"):
        out = FMT.format(logging.LogRecord("t", logging.INFO, __file__, 1, line, None, None))
        attach_json("formatter line → output", {"line": line, "output": out, "redact(line)": redact(line)})
    with then(f"output contains = {contains!r} (= redact(line))", contains={"expected": contains, "actual": out}):
        assert out == redact(line) == contains
    with then(f"absent {absent!r} not in the output", absent={"expected": f"no {absent!r}", "actual": out}):
        assert absent not in out


def test_arg_token_masked():
    """Chassis guard: a %-arg carrying a token is masked."""
    world()
    with when("format LogRecord 'ride %s' with args (session token,)"):
        out = FMT.format(logging.LogRecord("t", logging.INFO, __file__, 1, "ride %s", (TOKEN,), None))
        attach_json("formatter msg+args → output", {"msg": "ride %s", "args": ["gws_…"], "output": out})
    with then("output = 'ride <redacted>', no gws_", output={"expected": "ride <redacted>", "actual": out}):
        assert out == "ride <redacted>" and "gws_" not in out


LOG_ROWS = [
    pytest.param("policy-default · upstream-401", "upstream-401 on openrouter", "upstream-auth openrouter 401", "LEAK, sk-ant-oat, invalid x-api-key",
                 id="an upstream 401 body is summarised, not copied"),
    pytest.param("policy-default", "Authorization: Bearer notatoken", "session-unknown", "notatoken",
                 id="a bad inbound header is logged by shape"),
    pytest.param("policy-default", "POST /sessions", "id=…", "gws_",
                 id="a dispatch line names the session id, never the token"),
    pytest.param("policy-default", "a bound dispatch, then its pull", "env pulled id=… by system:serviceaccount:platform-agents:agentstack-worker", "eyJ, gws_",
                 id="a pull line names the session and the identity, never either token"),
    pytest.param("policy-default", "a pull whose token reviews as another ServiceAccount", "pull-identity-refused", "eyJ",
                 id="a refused pull never logs the presented token"),
]


@pytest.mark.parametrize(("world", "path", "expected_log_line_contains", "expected_never_logged"), LOG_ROWS)
@_system_row
async def test_what_the_log_holds_and_never_holds(world, path, expected_log_line_contains, expected_never_logged, gw, upstreams, reviews, caplog):
    enter_world(world)
    inputs(path=path)
    caplog.set_level(logging.INFO)
    session_id = ""
    if path == "upstream-401 on openrouter":
        upstreams["openrouter"].behaviour = "upstream-401"
        with given("a session on rail openrouter (worker, harness goose)"):
            doc = await open_session(gw, role="worker", harness="goose", rail="openrouter")
        with when(f"path = {path}: POST /openai/v1/chat/completions on the openrouter session (upstream answers 401)"):
            r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))
        assert r.status_code == 424, r.text
    elif path == "Authorization: Bearer notatoken":
        with when(f"path = {path}: POST /openai/v1/chat/completions with authorization 'Bearer notatoken'"):
            r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers={"authorization": "Bearer notatoken"})
        assert r.status_code == 401, r.text
    elif path == "POST /sessions":
        with when(f"path = {path} (platform worker) → dispatch"):
            doc = await open_session(gw)
        session_id = doc["session"]["id"]
    elif path == "a bound dispatch, then its pull":
        user = "system:serviceaccount:platform-agents:agentstack-worker"
        with given("a session bound to platform-agents/agentstack-worker pod fixer-1; the fake TokenReview answers that identity"):
            reviews.tokens[JWT] = Review(True, user, ("agent-gateway",), {POD_NAME_EXTRA: ("fixer-1",)})
            doc = await open_session(gw, bind={"namespace": "platform-agents", "serviceaccount": "agentstack-worker", "pod": "fixer-1"})
        session_id = doc["session"]["id"]
        with when(f"path = {path}: POST /sessions/{session_id}/env with the pod's projected token"):
            await gw.post(f"/sessions/{session_id}/env", headers={"authorization": f"Bearer {JWT}"})
    elif path == "a pull whose token reviews as another ServiceAccount":
        with given("a bound session; the presented token reviews as system:serviceaccount:platform-agents:default"):
            reviews.tokens[JWT] = Review(True, "system:serviceaccount:platform-agents:default", ("agent-gateway",), {})
            doc = await open_session(gw, bind={"namespace": "platform-agents", "serviceaccount": "agentstack-worker"})
        session_id = doc["session"]["id"]
        with when(f"path = {path}: POST /sessions/{session_id}/env with that token"):
            await gw.post(f"/sessions/{session_id}/env", headers={"authorization": f"Bearer {JWT}"})
    else:
        raise ValueError(f"no real path named {path!r}")

    needle = expected_log_line_contains.replace("…", session_id)
    messages = [rec.getMessage() for rec in caplog.records]
    attach_json("the log lines", messages)
    held = expected_log_line_contains if any(needle in m for m in messages) else f"no line holds {needle!r}"
    leaked = [f for f in expected_never_logged.split(", ") if any(f in m for m in messages)]
    never = expected_never_logged if not leaked else f"logged: {', '.join(leaked)}"
    expect({"log_line_contains": held, "never_logged": never}, log_line_contains=expected_log_line_contains, never_logged=expected_never_logged)
