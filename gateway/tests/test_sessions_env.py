"""GW-SESSIONS-ENV — the dispatch answer's env is the pod's complete LLM env for the harness (specs/endpoints/sessions.md).

| description | harness | rail | model (policy) | env var | value |
|---|---|---|---|---|---|
| claude: the base url is this gateway's anthropic path | claude | anthropic | claude/sonnet | ANTHROPIC_BASE_URL | <self>/anthropic |
| claude: the auth token is the session token | claude | anthropic | claude/sonnet | ANTHROPIC_AUTH_TOKEN | the session token |
| claude: the model name is the alias the CLI resolves | claude | anthropic | claude/sonnet | ANTHROPIC_MODEL | sonnet |
| claude on the Go rail: same three vars, Go's model name | claude | opencode | opencode-go/claude-sonnet-4-6 | ANTHROPIC_MODEL | claude-sonnet-4-6 |
| opencode: the base url is this gateway's openai path (verify) | opencode | opencode | opencode-go/deepseek-v4-flash | OPENAI_BASE_URL | <self>/openai/v1 |
| opencode: the api key is the session token (verify) | opencode | opencode | opencode-go/deepseek-v4-flash | OPENAI_API_KEY | the session token |
| opencode: the model var carries the bare id (verify) | opencode | opencode | opencode-go/deepseek-v4-flash | OPENCODE_MODEL | deepseek-v4-flash |
| goose: the base url is this gateway's openai path (verify) | goose | openrouter | deepseek/deepseek-v4-flash | OPENAI_BASE_URL | <self>/openai/v1 |
| goose: the api key is the session token (verify) | goose | openrouter | deepseek/deepseek-v4-flash | OPENAI_API_KEY | the session token |
| goose: the model var carries the bare id (verify) | goose | openrouter | deepseek/deepseek-v4-flash | GOOSE_MODEL | deepseek/deepseek-v4-flash |

| description | harness | vars present | vars absent |
|---|---|---|---|
| claude's env is exactly three vars | claude | ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL | ANTHROPIC_API_KEY, any OPENAI_*, any OPENROUTER_* |
| the openai-dialect env never carries an anthropic var | opencode | OPENAI_BASE_URL OPENAI_API_KEY OPENCODE_MODEL | any ANTHROPIC_*, OPENROUTER_API_KEY |
| no env value is a real key | any | every value is the token, a URL or a model name | any value matching the GW-REDACT patterns |
| codex is a gap | codex | — | 400 harness-rail-mismatch |

| description | model (policy) | context_tokens |
|---|---|---|
| a declared `context_tokens` is echoed | opencode-go/deepseek-v4-flash | 1000000 |
| an undeclared `context_tokens` is null, never a default | claude/sonnet | null |
"""

from __future__ import annotations

import pytest

from agent_gateway.logging import looks_like_credential

from .conftest import SELF_URL, err, open_session, rule

pytestmark = rule("GW-SESSIONS-ENV")

CLAUDE = {"role": "reviewer", "harness": "claude"}
CLAUDE_GO = {"role": "reviewer", "harness": "claude", "rail": "opencode"}
OPENCODE = {"role": "worker", "harness": "opencode"}
GOOSE = {"role": "worker", "harness": "goose", "rail": "openrouter"}

VAR_ROWS = [
    ("claude: the base url is this gateway's anthropic path", CLAUDE, "ANTHROPIC_BASE_URL", f"{SELF_URL}/anthropic"),
    ("claude: the auth token is the session token", CLAUDE, "ANTHROPIC_AUTH_TOKEN", "<token>"),
    ("claude: the model name is the alias the CLI resolves", CLAUDE, "ANTHROPIC_MODEL", "sonnet"),
    ("claude on the Go rail: same three vars, Go's model name", CLAUDE_GO, "ANTHROPIC_MODEL", "claude-sonnet-4-6"),
    ("opencode: the base url is this gateway's openai path (verify)", OPENCODE, "OPENAI_BASE_URL", f"{SELF_URL}/openai/v1"),
    ("opencode: the api key is the session token (verify)", OPENCODE, "OPENAI_API_KEY", "<token>"),
    ("opencode: the model var carries the bare id (verify)", OPENCODE, "OPENCODE_MODEL", "deepseek-v4-flash"),
    ("goose: the base url is this gateway's openai path (verify)", GOOSE, "OPENAI_BASE_URL", f"{SELF_URL}/openai/v1"),
    ("goose: the api key is the session token (verify)", GOOSE, "OPENAI_API_KEY", "<token>"),
    ("goose: the model var carries the bare id (verify)", GOOSE, "GOOSE_MODEL", "deepseek/deepseek-v4-flash"),
]


@pytest.mark.parametrize(("body", "var", "value"), [r[1:] for r in VAR_ROWS], ids=[r[0] for r in VAR_ROWS])
async def test_env_var(gw, body, var, value):
    doc = await open_session(gw, **body)
    expected = doc["session"]["token"] if value == "<token>" else value
    assert doc["env"][var] == expected, doc["env"]


SHAPE_ROWS = [
    ("claude's env is exactly three vars", CLAUDE, {"ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL"}, ("ANTHROPIC_API_KEY", "OPENAI_", "OPENROUTER_")),
    ("the openai-dialect env never carries an anthropic var", OPENCODE, {"OPENAI_BASE_URL", "OPENAI_API_KEY", "OPENCODE_MODEL"}, ("ANTHROPIC_", "OPENROUTER_API_KEY")),
]


@pytest.mark.parametrize(("body", "present", "absent"), [r[1:] for r in SHAPE_ROWS], ids=[r[0] for r in SHAPE_ROWS])
async def test_env_shape(gw, body, present, absent):
    env = (await open_session(gw, **body))["env"]
    assert set(env) == present, env
    for prefix in absent:
        assert not any(k.startswith(prefix) for k in env), (prefix, env)


async def test_no_env_value_is_a_real_key(gw):
    """row: no env value is a real key"""
    for body in (CLAUDE, CLAUDE_GO, OPENCODE, GOOSE):
        doc = await open_session(gw, **body)
        token = doc["session"]["token"]
        for k, v in doc["env"].items():
            assert v == token or v.startswith("http://") or v in (doc["model"], doc["model"].split("/", 1)[-1]), (k, v)
            assert v == token or not looks_like_credential(v), (k, v)


async def test_codex_is_a_gap(gw):
    """row: codex is a gap"""
    r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "t", "harness": "codex"})
    assert r.status_code == 400 and err(r) == "harness-rail-mismatch"


CTX_ROWS = [("a declared `context_tokens` is echoed", OPENCODE, 1000000), ("an undeclared `context_tokens` is null, never a default", CLAUDE, None)]


@pytest.mark.parametrize(("body", "ctx"), [r[1:] for r in CTX_ROWS], ids=[r[0] for r in CTX_ROWS])
async def test_context_tokens(gw, body, ctx):
    doc = await open_session(gw, **body)
    assert doc["context_tokens"] == ctx
