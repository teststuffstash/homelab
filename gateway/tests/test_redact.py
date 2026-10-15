"""GW-REDACT — no credential value in any log line (specs/endpoints/sessions.md).

| description | the formatter is given | the line contains | the line does not contain |
|---|---|---|---|
| a session token in a message | "auth ok gws_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" | auth ok <redacted> | gws_ |
| an OAuth token | "inject sk-ant-oat01-FAKE..." | inject <redacted> | sk-ant-oat |
| an OpenRouter key | "inject sk-or-v1-FAKE..." | inject <redacted> | sk-or-v1- |
| a bearer header value | "Authorization: Bearer abc.def.ghi" | Authorization: Bearer <redacted> | abc.def.ghi |
| the Go key's value | the OPENCODE_GO_API_KEY fixture value | <redacted> | the value |
| a ref is not a credential | "ref platform-agents/claude-session unresolved" | the ref verbatim | <redacted> |
| a model id is not a credential | "model opencode-go/deepseek-v4-flash" | the id verbatim | <redacted> |
| a %-arg carrying a token is masked | "ride %s" % token | ride <redacted> | gws_ |

| description | path | the log holds | the log does not hold |
|---|---|---|---|
| an upstream 401 body is summarised, not copied | upstream-401 on openrouter | upstream-auth openrouter 401 | the upstream body, the key |
| a bad inbound header is logged by shape | Authorization: Bearer notatoken | session-unknown | notatoken |
| a dispatch line names the session id, never the token | dispatch | the session id | the token |
"""

from __future__ import annotations

import logging

import pytest

from agent_gateway.logging import REDACTED, RedactingFormatter, redact, register_literal

from .conftest import GO_KEY, bearer, open_session, rule

pytestmark = rule("GW-REDACT")

TOKEN = "gws_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
FMT = RedactingFormatter("%(message)s")

ROWS = [
    ("a session token in a message", f"auth ok {TOKEN}", "auth ok <redacted>", "gws_"),
    ("an OAuth token", "inject sk-ant-oat01-FAKEFAKEFAKE", "inject <redacted>", "sk-ant-oat"),
    ("an OpenRouter key", "inject sk-or-v1-FAKEFAKEFAKE", "inject <redacted>", "sk-or-v1-"),
    ("a bearer header value", "Authorization: Bearer abc.def.ghi", "Authorization: Bearer <redacted>", "abc.def.ghi"),
    ("the Go key's value", f"go key {GO_KEY} in use", "go key <redacted> in use", GO_KEY),
    ("a ref is not a credential", "ref platform-agents/claude-session unresolved", "ref platform-agents/claude-session unresolved", REDACTED),
    ("a model id is not a credential", "model opencode-go/deepseek-v4-flash", "model opencode-go/deepseek-v4-flash", REDACTED),
]


@pytest.mark.parametrize(("line", "contains", "absent"), [r[1:] for r in ROWS], ids=[r[0] for r in ROWS])
def test_formatter_rows(line, contains, absent):
    register_literal(GO_KEY)
    out = FMT.format(logging.LogRecord("t", logging.INFO, __file__, 1, line, None, None))
    assert out == redact(line) == contains
    assert absent not in out


def test_arg_token_masked():
    """row: a %-arg carrying a token is masked"""
    out = FMT.format(logging.LogRecord("t", logging.INFO, __file__, 1, "ride %s", (TOKEN,), None))
    assert out == "ride <redacted>" and "gws_" not in out


def _lines(caplog) -> list[str]:
    return [FMT.format(rec) for rec in caplog.records]


async def test_upstream_401_summarised(gw, upstreams, caplog):
    """row: an upstream 401 body is summarised, not copied"""
    caplog.set_level(logging.INFO)
    upstreams["openrouter"].behaviour = "upstream-401"
    doc = await open_session(gw, role="worker", harness="goose", rail="openrouter")
    assert (await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers=bearer(doc))).status_code == 502
    lines = _lines(caplog)
    assert any(line.startswith("upstream-auth openrouter 401") for line in lines), lines
    assert not any("LEAK" in line or "sk-ant-oat" in line or "invalid x-api-key" in line for line in lines)


async def test_bad_inbound_header_logged_by_shape(gw, caplog):
    """row: a bad inbound header is logged by shape"""
    caplog.set_level(logging.INFO)
    r = await gw.post("/openai/v1/chat/completions", json={"messages": []}, headers={"authorization": "Bearer notatoken"})
    assert r.status_code == 401
    lines = _lines(caplog)
    assert any("session-unknown" in line for line in lines), lines
    assert not any("notatoken" in line for line in lines)


async def test_dispatch_line_names_id_not_token(gw, caplog):
    """row: a dispatch line names the session id, never the token"""
    caplog.set_level(logging.INFO)
    doc = await open_session(gw)
    lines = _lines(caplog)
    assert any(f"id={doc['session']['id']}" in line for line in lines), lines
    for rec in caplog.records:
        assert doc["session"]["token"] not in rec.getMessage() and "gws_" not in rec.getMessage()
