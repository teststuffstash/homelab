"""GW-SESSIONS-ENV — the dispatch answer's env is the pod's complete LLM env for the harness (specs/endpoints/sessions.md).

| description | harness | rail | model (policy) | env var | value |
|---|---|---|---|---|---|
| claude: the base url is this gateway's anthropic path | claude | anthropic | claude/sonnet | ANTHROPIC_BASE_URL | <self>/anthropic |
| claude: the auth token is the session token | claude | anthropic | claude/sonnet | ANTHROPIC_AUTH_TOKEN | the session token |
| claude: the model name is the alias the CLI resolves | claude | anthropic | claude/sonnet | ANTHROPIC_MODEL | sonnet |
| claude on the Go rail: same three vars, Go's model name | claude | opencode | opencode-go/claude-haiku-5-5 | ANTHROPIC_MODEL | claude-haiku-5-5 |
| opencode: an openai-compatible provider block | opencode | opencode | opencode-go/deepseek-v4.1-flash | OPENCODE_CONFIG_CONTENT .provider.gateway.npm | @ai-sdk/openai-compatible |
| opencode: the provider's base url is this gateway's openai path | opencode | opencode | opencode-go/deepseek-v4.1-flash | OPENCODE_CONFIG_CONTENT .provider.gateway.options.baseURL | <self>/openai/v1 |
| opencode: the provider's api key is the session token | opencode | opencode | opencode-go/deepseek-v4.1-flash | OPENCODE_CONFIG_CONTENT .provider.gateway.options.apiKey | the session token |
| opencode: the session model is the bare id under that provider | opencode | opencode | opencode-go/deepseek-v4.1-flash | OPENCODE_CONFIG_CONTENT .model | gateway/deepseek-v4.1-flash |
| opencode: the title model is the same id | opencode | opencode | opencode-go/deepseek-v4.1-flash | OPENCODE_CONFIG_CONTENT .small_model | gateway/deepseek-v4.1-flash |
| goose: the provider is goose's openai provider | goose | openrouter | deepseek/deepseek-v4-flash | GOOSE_PROVIDER | openai |
| goose: the base url is this gateway's openai path | goose | openrouter | deepseek/deepseek-v4-flash | OPENAI_BASE_URL | <self>/openai/v1 |
| goose: the api key is the session token | goose | openrouter | deepseek/deepseek-v4-flash | OPENAI_API_KEY | the session token |
| goose: the model var carries the bare id | goose | openrouter | deepseek/deepseek-v4-flash | GOOSE_MODEL | deepseek/deepseek-v4-flash |
| codex: the base url is this gateway's openai path (wrapper-rendered) | codex | codex | codex/fixture-model | OPENAI_BASE_URL | <self>/openai/v1 |
| codex: the api key is the session token, read through env_key | codex | codex | codex/fixture-model | OPENAI_API_KEY | the session token |
| codex: the model var carries the bare id (wrapper-rendered) | codex | codex | codex/fixture-model | CODEX_MODEL | fixture-model |

| description | harness | vars present | vars absent |
|---|---|---|---|
| claude's env is exactly three vars | claude | ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL | ANTHROPIC_API_KEY, any OPENAI_*, any OPENROUTER_* |
| opencode's env is exactly the provider config | opencode | OPENCODE_CONFIG_CONTENT | any ANTHROPIC_*, any OPENAI_*, any OPENROUTER_* |
| goose's env is exactly four vars | goose | OPENAI_BASE_URL OPENAI_API_KEY GOOSE_PROVIDER GOOSE_MODEL | any ANTHROPIC_*, any OPENROUTER_* |
| no env value is a real key | any | every value (each leaf of opencode's config) is the token, a URL, a model name or a provider/package name | any value matching the GW-REDACT patterns |
| codex's env is exactly three vars | codex | OPENAI_BASE_URL OPENAI_API_KEY CODEX_MODEL | any ANTHROPIC_*, any OPENROUTER_* |

| description | model (policy) | context_tokens |
|---|---|---|
| a declared `context_tokens` is echoed | opencode-go/deepseek-v4.1-flash | 1000000 |
| an undeclared `context_tokens` is null, never a default | claude/sonnet | null |
"""

from __future__ import annotations

import json

import pytest

from agent_gateway.logging import looks_like_credential

from ._codex_world import fresh_report
from .conftest import SELF_URL, attach_json, given, open_session, rule, then, then_eq, when, world

pytestmark = rule("GW-SESSIONS-ENV")

CLAUDE = {"role": "reviewer", "harness": "claude"}
CLAUDE_GO = {"role": "reviewer", "harness": "claude", "rail": "opencode"}
OPENCODE = {"role": "worker", "harness": "opencode"}
GOOSE = {"role": "worker", "harness": "goose", "rail": "openrouter"}

VAR_ROWS = [
    ("claude: the base url is this gateway's anthropic path", CLAUDE, "ANTHROPIC_BASE_URL", f"{SELF_URL}/anthropic"),
    ("claude: the auth token is the session token", CLAUDE, "ANTHROPIC_AUTH_TOKEN", "<token>"),
    ("claude: the model name is the alias the CLI resolves", CLAUDE, "ANTHROPIC_MODEL", "sonnet"),
    ("claude on the Go rail: same three vars, Go's model name", CLAUDE_GO, "ANTHROPIC_MODEL", "claude-haiku-5-5"),
    ("goose: the provider is goose's openai provider", GOOSE, "GOOSE_PROVIDER", "openai"),
    ("goose: the base url is this gateway's openai path", GOOSE, "OPENAI_BASE_URL", f"{SELF_URL}/openai/v1"),
    ("goose: the api key is the session token", GOOSE, "OPENAI_API_KEY", "<token>"),
    ("goose: the model var carries the bare id", GOOSE, "GOOSE_MODEL", "deepseek/deepseek-v4-flash"),
]

# opencode's ONE var is a JSON config: each row reads one path of the parsed value
OPENCODE_ROWS = [
    ("opencode: an openai-compatible provider block", ("provider", "gateway", "npm"), "@ai-sdk/openai-compatible"),
    ("opencode: the provider's base url is this gateway's openai path", ("provider", "gateway", "options", "baseURL"), f"{SELF_URL}/openai/v1"),
    ("opencode: the provider's api key is the session token", ("provider", "gateway", "options", "apiKey"), "<token>"),
    ("opencode: the session model is the bare id under that provider", ("model",), "gateway/deepseek-v4.1-flash"),
    ("opencode: the title model is the same id", ("small_model",), "gateway/deepseek-v4.1-flash"),
]


@pytest.mark.parametrize(("body", "var", "value"), [r[1:] for r in VAR_ROWS], ids=[r[0] for r in VAR_ROWS])
async def test_env_var(gw, body, var, value):
    world()
    with when(f"POST /sessions body {body} → dispatch"):
        doc = await open_session(gw, **body)
    expected = doc["session"]["token"] if value == "<token>" else value
    with then(f"env var {var} = value {value}", **{var: {"expected": value, "actual": "<token>" if doc["env"].get(var) == doc["session"]["token"] else doc["env"].get(var)}}):
        assert doc["env"][var] == expected, doc["env"]


@pytest.mark.parametrize(("path", "value"), [r[1:] for r in OPENCODE_ROWS], ids=[r[0] for r in OPENCODE_ROWS])
async def test_opencode_config(gw, path, value):
    world()
    with when(f"POST /sessions body {OPENCODE} → dispatch"):
        doc = await open_session(gw, **OPENCODE)
    with when(f"read OPENCODE_CONFIG_CONTENT as JSON at path {path}"):
        cfg = json.loads(doc["env"]["OPENCODE_CONFIG_CONTENT"])
        actual = cfg
        for key in path:
            actual = actual[key]
        expected = doc["session"]["token"] if value == "<token>" else value
        shown = "<token>" if actual == doc["session"]["token"] else actual
    with then(f"OPENCODE_CONFIG_CONTENT at path {path} = value {value}", **{".".join(path): {"expected": value, "actual": shown}}):
        assert actual == expected, cfg


SHAPE_ROWS = [
    ("claude's env is exactly three vars", CLAUDE, {"ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL"}, ("ANTHROPIC_API_KEY", "OPENAI_", "OPENROUTER_")),
    ("opencode's env is exactly the provider config", OPENCODE, {"OPENCODE_CONFIG_CONTENT"}, ("ANTHROPIC_", "OPENAI_", "OPENROUTER_")),
    ("goose's env is exactly four vars", GOOSE, {"OPENAI_BASE_URL", "OPENAI_API_KEY", "GOOSE_PROVIDER", "GOOSE_MODEL"}, ("ANTHROPIC_", "OPENROUTER_")),
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
    with then("every env value (each leaf of opencode's config) is the session token, a URL, the model id, a provider/package name — never a credential-shaped value"):
        attach_json("verdict: env values per harness (token shown as <token>)",
                    {f"{d['harness']} on {d['rail']}": {k: ("<token>" if v == d["session"]["token"] else v) for k, v in d["env"].items()} for d in docs})
        for doc in docs:
            token = doc["session"]["token"]
            wire = doc["model"].split("/", 1)[-1]
            for k, v in _env_leaves(doc["env"]):
                assert v == token or v.startswith(("http://", "https://opencode.ai/", "@ai-sdk/")) or v in (doc["model"], wire, f"gateway/{wire}", "openai"), (k, v)
                assert v == token or not looks_like_credential(v), (k, v)


def _env_leaves(env: dict) -> list[tuple[str, str]]:
    """Every string an env carries: a plain var's value, and each leaf (key and value) of opencode's JSON config."""
    out: list[tuple[str, str]] = []
    for k, v in env.items():
        if k != "OPENCODE_CONFIG_CONTENT":
            out.append((k, v))
            continue
        stack = [("OPENCODE_CONFIG_CONTENT", json.loads(v))]
        while stack:
            path, node = stack.pop()
            if isinstance(node, dict):
                stack.extend((f"{path}.{ck}", cv) for ck, cv in node.items())
                out.extend((f"{path}.{ck}<key>", ck) for ck in node if ck not in ("$schema", "model", "small_model", "provider", "gateway", "npm", "options", "baseURL", "apiKey", "models"))
            elif isinstance(node, str):
                out.append((path, node))
    return out


CODEX_ROWS = [
    ("codex: the base url is this gateway's openai path (wrapper-rendered)", "OPENAI_BASE_URL", f"{SELF_URL}/openai/v1"),
    ("codex: the api key is the session token, read through env_key", "OPENAI_API_KEY", "<token>"),
    ("codex: the model var carries the bare id (wrapper-rendered)", "CODEX_MODEL", "fixture-model"),
]


async def _codex_dispatch(codex_app, codex_gw, clock) -> dict:
    with given("world policy-codex: a fresh headroom observation (the rail's admission gate)"):
        codex_app.state.codex.headroom.observe(fresh_report(clock))
    with when("POST /sessions {role: prober, harness: codex} → dispatch on codex"):
        return await open_session(codex_gw, role="prober", harness="codex")


@pytest.mark.parametrize(("var", "value"), [r[1:] for r in CODEX_ROWS], ids=[r[0] for r in CODEX_ROWS])
async def test_codex_env_var(codex_app, codex_gw, clock, var, value):
    world("policy-codex")
    doc = await _codex_dispatch(codex_app, codex_gw, clock)
    expected = doc["session"]["token"] if value == "<token>" else value
    with then(f"env var {var} = value {value}", **{var: {"expected": value, "actual": "<token>" if doc["env"].get(var) == doc["session"]["token"] else doc["env"].get(var)}}):
        assert doc["env"][var] == expected, doc["env"]


async def test_codex_env_shape(codex_app, codex_gw, clock):
    """row: codex's env is exactly three vars"""
    world("policy-codex")
    env = (await _codex_dispatch(codex_app, codex_gw, clock))["env"]
    want = {"OPENAI_BASE_URL", "OPENAI_API_KEY", "CODEX_MODEL"}
    with then(f"env keys present = exactly {sorted(want)}", present={"expected": sorted(want), "actual": sorted(env)}):
        assert set(env) == want, env
    with then("absent: no ANTHROPIC_* / OPENROUTER_* key"):
        assert not any(k.startswith(("ANTHROPIC_", "OPENROUTER_")) for k in env), env


CTX_ROWS = [("a declared `context_tokens` is echoed", OPENCODE, 1000000), ("an undeclared `context_tokens` is null, never a default", CLAUDE, None)]


@pytest.mark.parametrize(("body", "ctx"), [r[1:] for r in CTX_ROWS], ids=[r[0] for r in CTX_ROWS])
async def test_context_tokens(gw, body, ctx):
    world()
    with given(f"policy: the dispatched model's declared ctx (context_tokens) is {ctx}"):
        pass
    with when(f"POST /sessions body {body} → dispatch"):
        doc = await open_session(gw, **body)
    then_eq("context_tokens", doc["context_tokens"], ctx, claim=f"ctx: context_tokens = {ctx}")
