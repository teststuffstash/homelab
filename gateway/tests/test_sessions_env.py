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

from .conftest import SELF_URL, attach_json, check, err, given, open_session, rule, then, then_eq, when, world

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
    world()
    with when(f"POST /sessions body {body} → dispatch"):
        doc = await open_session(gw, **body)
    expected = doc["session"]["token"] if value == "<token>" else value
    with then(f"env var {var} = value {value}", **{var: {"expected": value, "actual": "<token>" if doc["env"].get(var) == doc["session"]["token"] else doc["env"].get(var)}}):
        assert doc["env"][var] == expected, doc["env"]


SHAPE_ROWS = [
    ("claude's env is exactly three vars", CLAUDE, {"ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL"}, ("ANTHROPIC_API_KEY", "OPENAI_", "OPENROUTER_")),
    ("the openai-dialect env never carries an anthropic var", OPENCODE, {"OPENAI_BASE_URL", "OPENAI_API_KEY", "OPENCODE_MODEL"}, ("ANTHROPIC_", "OPENROUTER_API_KEY")),
]


@pytest.mark.parametrize(("body", "present", "absent"), [r[1:] for r in SHAPE_ROWS], ids=[r[0] for r in SHAPE_ROWS])
async def test_env_shape(gw, body, present, absent):
    world()
    with when(f"POST /sessions body {body} → dispatch"):
        env = (await open_session(gw, **body))["env"]
    with then(f"env keys present = exactly {sorted(present)}", present={"expected": sorted(present), "actual": sorted(env)}):
        assert set(env) == present, env
    with then(f"absent: no env key starts with {list(absent)}", absent={"expected": list(absent), "actual": sorted(env)}):
        for prefix in absent:
            assert not any(k.startswith(prefix) for k in env), (prefix, env)


async def test_no_env_value_is_a_real_key(gw):
    """row: no env value is a real key"""
    world()
    docs = []
    with when("POST /sessions for each harness shape: claude, claude on Go, opencode, goose"):
        for body in (CLAUDE, CLAUDE_GO, OPENCODE, GOOSE):
            docs.append(await open_session(gw, **body))
    with then("every env value is the session token, an http:// URL or the model id — never a credential-shaped value"):
        attach_json("verdict: env values per harness (token shown as <token>)",
                    {f"{d['harness']} on {d['rail']}": {k: ("<token>" if v == d["session"]["token"] else v) for k, v in d["env"].items()} for d in docs})
        for doc in docs:
            token = doc["session"]["token"]
            for k, v in doc["env"].items():
                assert v == token or v.startswith("http://") or v in (doc["model"], doc["model"].split("/", 1)[-1]), (k, v)
                assert v == token or not looks_like_credential(v), (k, v)


async def test_codex_is_a_gap(gw):
    """row: codex is a gap"""
    world()
    with when("POST /sessions harness codex (platform worker)"):
        r = await gw.post("/sessions", json={"stack": "platform", "role": "worker", "task": "t", "harness": "codex"})
    with then("status 400 with code harness-rail-mismatch"):
        check("(status, code)", (r.status_code, err(r)), (400, "harness-rail-mismatch"))


CTX_ROWS = [("a declared `context_tokens` is echoed", OPENCODE, 1000000), ("an undeclared `context_tokens` is null, never a default", CLAUDE, None)]


@pytest.mark.parametrize(("body", "ctx"), [r[1:] for r in CTX_ROWS], ids=[r[0] for r in CTX_ROWS])
async def test_context_tokens(gw, body, ctx):
    world()
    with given(f"policy: the dispatched model's declared ctx (context_tokens) is {ctx}"):
        pass
    with when(f"POST /sessions body {body} → dispatch"):
        doc = await open_session(gw, **body)
    then_eq("context_tokens", doc["context_tokens"], ctx, claim=f"ctx: context_tokens = {ctx}")
