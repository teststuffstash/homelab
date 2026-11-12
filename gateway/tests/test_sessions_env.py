"""GW-SESSIONS-ENV — the dispatch answer's env is the pod's complete LLM env for the harness
(specs/endpoints/sessions.md §The session → GW-SESSIONS-ENV). One table per harness, the shape
table, the context window and the policy guard. Header == argnames, description == id (tests/_rows.py)."""

from __future__ import annotations

import json

import pytest

from agent_gateway.config import Policy, PolicyError
from agent_gateway.logging import looks_like_credential

from ._codex_world import fresh_report
from ._rows import NULL, POLICY, body_of, enter_world, expect, inputs
from .conftest import POLICY_FIXTURE, SELF_URL, attach_json, given, open_session, rule, then, when

pytestmark = rule("GW-SESSIONS-ENV")

TOKEN = "the session token"
OPENAI_V1 = f"{SELF_URL}/openai/v1"


def _shown(value, token: str):
    return TOKEN if value == token else value


# -- the claude env (a reviewer with harness claude) -------------------------------------------------
CLAUDE_ROWS = [
    pytest.param("policy-default", POLICY, "ANTHROPIC_BASE_URL", f"{SELF_URL}/anthropic", id="claude: the base url is this gateway's anthropic path"),
    pytest.param("policy-default", POLICY, "ANTHROPIC_AUTH_TOKEN", TOKEN, id="claude: the auth token is the session token"),
    pytest.param("policy-default", POLICY, "ANTHROPIC_MODEL", "sonnet", id="claude: the model name is the alias the CLI resolves"),
    pytest.param("policy-default", "opencode", "ANTHROPIC_MODEL", "claude-haiku-5-5", id="claude on the Go rail: same three vars, Go's model name"),
]


@pytest.mark.parametrize(("world", "rail", "var", "expected_value"), CLAUDE_ROWS)
async def test_the_claude_env(gw, world, rail, var, expected_value):
    enter_world(world)
    inputs(rail=rail, var=var)
    body = {"role": "reviewer", "harness": "claude", **body_of(rail=rail)}
    with when(f"POST /sessions {body} → dispatch"):
        doc = await open_session(gw, **body)
    expect({"value": _shown(doc["env"].get(var), doc["session"]["token"])}, value=expected_value)


# -- the opencode env (a worker with harness opencode): ONE var holding a JSON config, read by path -------
OPENCODE_ROWS = [
    pytest.param("policy-default", ".provider.gateway.npm", "@ai-sdk/openai-compatible", id="opencode: an openai-compatible provider block"),
    pytest.param("policy-default", ".provider.gateway.options.baseURL", OPENAI_V1, id="opencode: the provider's base url is this gateway's openai path"),
    pytest.param("policy-default", ".provider.gateway.options.apiKey", TOKEN, id="opencode: the provider's api key is the session token"),
    pytest.param("policy-default", ".model", "gateway/deepseek-v4.1-flash", id="opencode: the session model is the bare id under that provider"),
    pytest.param("policy-default", ".small_model", "gateway/deepseek-v4.1-flash", id="opencode: the title model is the same id"),
]


@pytest.mark.parametrize(("world", "path", "expected_value"), OPENCODE_ROWS)
async def test_the_opencode_env(gw, world, path, expected_value):
    enter_world(world)
    inputs(path=path)
    body = {"role": "worker", "harness": "opencode"}
    with when(f"POST /sessions {body} → dispatch; read OPENCODE_CONFIG_CONTENT as JSON at {path}"):
        doc = await open_session(gw, **body)
        actual = json.loads(doc["env"]["OPENCODE_CONFIG_CONTENT"])
        for key in path.strip(".").split("."):
            actual = actual[key]
    expect({"value": _shown(actual, doc["session"]["token"])}, value=expected_value)


# -- the goose env (a worker with harness goose on rail openrouter) ---------------------------------------
GOOSE_ROWS = [
    pytest.param("policy-default", "GOOSE_PROVIDER", "openai", id="goose: the provider is goose's openai provider"),
    pytest.param("policy-default", "OPENAI_BASE_URL", OPENAI_V1, id="goose: the base url is this gateway's openai path"),
    pytest.param("policy-default", "OPENAI_API_KEY", TOKEN, id="goose: the api key is the session token"),
    pytest.param("policy-default", "GOOSE_MODEL", "deepseek/deepseek-v4-flash", id="goose: the model var carries the bare id"),
]


@pytest.mark.parametrize(("world", "var", "expected_value"), GOOSE_ROWS)
async def test_the_goose_env(gw, world, var, expected_value):
    enter_world(world)
    inputs(var=var)
    body = {"role": "worker", "harness": "goose", "rail": "openrouter"}
    with when(f"POST /sessions {body} → dispatch"):
        doc = await open_session(gw, **body)
    expect({"value": _shown(doc["env"].get(var), doc["session"]["token"])}, value=expected_value)


# -- the codex env (world policy-codex: a prober with harness codex, on fresh headroom) -----------------
CODEX_ROWS = [
    pytest.param("policy-codex", "OPENAI_BASE_URL", OPENAI_V1, id="codex: the base url is this gateway's openai path (wrapper-rendered) ⚖"),
    pytest.param("policy-codex", "OPENAI_API_KEY", TOKEN, id="codex: the api key is the session token, read through env_key ⚖"),
    pytest.param("policy-codex", "CODEX_MODEL", "fixture-model", id="codex: the model var carries the bare id (wrapper-rendered) ⚖"),
]


async def _codex_dispatch(codex_app, codex_gw, clock) -> dict:
    with given("codex headroom observed fresh: 20 % / 64 % (the rail's admission gate)"):
        codex_app.state.codex.headroom.observe(fresh_report(clock))
    body = {"role": "prober", "harness": "codex"}
    with when(f"POST /sessions {body} → dispatch on codex"):
        return await open_session(codex_gw, **body)


@pytest.mark.parametrize(("world", "var", "expected_value"), CODEX_ROWS)
async def test_the_codex_env(codex_app, codex_gw, clock, world, var, expected_value):
    enter_world(world)
    inputs(var=var)
    doc = await _codex_dispatch(codex_app, codex_gw, clock)
    expect({"value": _shown(doc["env"].get(var), doc["session"]["token"])}, value=expected_value)


# -- exactly these vars ---------------------------------------------------------------------------------
SHAPE_ROWS = [
    pytest.param("policy-default", "claude", "ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL", "ANTHROPIC_API_KEY, OPENAI_*, OPENROUTER_*",
                 id="claude's env is exactly three vars"),
    pytest.param("policy-default", "opencode", "OPENCODE_CONFIG_CONTENT", "ANTHROPIC_*, OPENAI_*, OPENROUTER_*",
                 id="opencode's env is exactly the provider config"),
    pytest.param("policy-default", "goose", "OPENAI_BASE_URL, OPENAI_API_KEY, GOOSE_PROVIDER, GOOSE_MODEL", "ANTHROPIC_*, OPENROUTER_*",
                 id="goose's env is exactly four vars"),
]
CODEX_SHAPE_ROWS = [
    pytest.param("policy-codex", "codex", "OPENAI_BASE_URL, OPENAI_API_KEY, CODEX_MODEL", "ANTHROPIC_*, OPENROUTER_*",
                 id="codex's env is exactly three vars ⚖"),
]
BODIES = {"claude": {"role": "reviewer", "harness": "claude"}, "opencode": {"role": "worker", "harness": "opencode"},
          "goose": {"role": "worker", "harness": "goose", "rail": "openrouter"}}


def _shape(env: dict, expected_absent: str) -> dict:
    """The env's keys in order, and the `absent?` cell when no key matches a listed name or prefix (`X_*`)."""
    names = expected_absent.split(", ")
    hits = [k for k in env for n in names if (k.startswith(n[:-1]) if n.endswith("*") else k == n)]
    return {"present": ", ".join(env), "absent": expected_absent if not hits else f"present: {', '.join(hits)}"}


@pytest.mark.parametrize(("world", "harness", "expected_present", "expected_absent"), SHAPE_ROWS)
async def test_exactly_these_vars(gw, world, harness, expected_present, expected_absent):
    enter_world(world)
    inputs(harness=harness)
    with when(f"POST /sessions {BODIES[harness]} → dispatch"):
        env = (await open_session(gw, **BODIES[harness]))["env"]
    expect(_shape(env, expected_absent), present=expected_present, absent=expected_absent)


@pytest.mark.parametrize(("world", "harness", "expected_present", "expected_absent"), CODEX_SHAPE_ROWS)
async def test_exactly_these_vars_codex(codex_app, codex_gw, clock, world, harness, expected_present, expected_absent):
    enter_world(world)
    inputs(harness=harness)
    env = (await _codex_dispatch(codex_app, codex_gw, clock))["env"]
    expect(_shape(env, expected_absent), present=expected_present, absent=expected_absent)


# -- no env value is a real key --------------------------------------------------------------------------
KEY_ROWS = [
    pytest.param("policy-default", "claude, claude on Go, opencode, goose", 0, id="no env value is a real key"),
]


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


@pytest.mark.parametrize(("world", "harnesses", "expected_credential_shaped_values"), KEY_ROWS)
async def test_no_env_value_is_a_real_key(gw, world, harnesses, expected_credential_shaped_values):
    enter_world(world)
    inputs(harnesses=harnesses)
    docs = []
    with when(f"POST /sessions for each harness shape: {harnesses}"):
        for body in (BODIES["claude"], {**BODIES["claude"], "rail": "opencode"}, BODIES["opencode"], BODIES["goose"]):
            docs.append(await open_session(gw, **body))
    suspects = []
    for doc in docs:
        token = doc["session"]["token"]
        wire = doc["model"].split("/", 1)[-1]
        for k, v in _env_leaves(doc["env"]):
            known = v == token or v.startswith(("http://", "https://opencode.ai/", "@ai-sdk/")) or v in (doc["model"], wire, f"gateway/{wire}", "openai")
            if not known or (v != token and looks_like_credential(v)):
                suspects.append((doc["harness"], k, v))
    attach_json("env values per harness (the token shown as <token>)",
                {f"{d['harness']} on {d['rail']}": {k: _shown(v, d["session"]["token"]) for k, v in d["env"].items()} for d in docs})
    expect({"credential_shaped_values": len(suspects)}, credential_shaped_values=expected_credential_shaped_values)
    if suspects:
        with then(f"suspect values: {suspects}"):
            raise AssertionError(suspects)


# -- context_tokens --------------------------------------------------------------------------------------
# The Go rail answers the catalog's `context` for the wire model (GW-CATALOG-GO ruling 5 — the seeded
# catalog-ok snapshot, tests/fixtures/go-catalog/models-dev.json, gives deepseek-v4.1-flash `limit.context`
# 1000000; the world's policy declares no Go entry); every other rail answers the policy's declared window
# (the world declares the openrouter heavy model's, a world value) or null.
CTX_ROWS = [
    pytest.param("policy-default", "worker", "opencode", POLICY, POLICY, 1000000, "dispatch", "—",
                 id="a Go model's context_tokens is the catalog's context ⚖"),
    pytest.param("policy-default · catalog-retired", "worker", "opencode", "opencode", POLICY, NULL, "defer", "not-in-catalog",
                 id="a Go model with no catalog row answers null, never a default"),
    pytest.param("policy-default", "worker", "goose", "openrouter", "heavy", 163840, "dispatch", "—",
                 id="a declared context_tokens is echoed"),
    pytest.param("policy-default", "reviewer", "claude", POLICY, POLICY, NULL, "dispatch", "—",
                 id="an undeclared context_tokens is null, never a default"),
]


@pytest.mark.parametrize(("world", "role", "harness", "rail", "tier", "expected_context_tokens", "expected_decision", "expected_reason"), CTX_ROWS)
async def test_context_tokens(gw, app, vendor, world, role, harness, rail, tier, expected_context_tokens, expected_decision, expected_reason):
    enter_world(world)
    inputs(role=role, harness=harness, rail=rail, tier=tier)
    if world.endswith("catalog-retired"):
        with given("the config source refreshes against catalog-retired: the catalog (models.dev) without deepseek-v4.1-flash"):
            vendor.catalog = "catalog-retired"
            outcome = await app.state.catalog.refresh_source("config")
            attach_json("refresh outcome", {"source": "config", "behaviour": "catalog-retired", "outcome": outcome})
            assert outcome == "ok", outcome
    body = {"stack": "platform", "task": "homelab-2650-r1", **body_of(role=role, harness=harness, rail=rail, tier=tier)}
    with when(f"POST /sessions {body}" + ("; the catalog read for the wire model (GoCatalog.context_for)" if world.endswith("catalog-retired") else "")):
        r = await gw.post("/sessions", json=body)
        doc = r.json()
        context = doc["context_tokens"] if doc.get("decision") == "dispatch" else app.state.catalog.context_for("deepseek-v4.1-flash")
    assert r.status_code == 200, r.text
    view = {"context_tokens": context, "decision": doc.get("decision"), "reason": doc.get("reason")}
    expect(view, context_tokens=expected_context_tokens, decision=expected_decision, reason=expected_reason)
    if doc.get("decision") == "defer":
        with then("the defer carries no context_tokens: no answer ever carries a guessed window"):
            assert "context_tokens" not in doc, doc


LOAD_ROWS = [
    pytest.param("policy-default", '{"opencode-go/deepseek-v4.1-flash": 1000000}', "refused, naming context_tokens",
                 id="a declared context_tokens for a Go model refuses the load ⚖"),
]


@pytest.mark.parametrize(("world", "context_tokens", "expected_load"), LOAD_ROWS)
def test_the_policy_refuses_a_go_context_tokens(world, context_tokens, expected_load):
    enter_world(world)
    inputs(context_tokens=context_tokens)
    doc = json.loads(POLICY_FIXTURE.read_text(encoding="utf-8"))
    doc["context_tokens"] = json.loads(context_tokens)
    with when(f"Policy.from_dict(policy-default with context_tokens = {context_tokens})"):
        try:
            Policy.from_dict(doc)
            load = "loaded"
        except PolicyError as e:
            load = "refused, naming context_tokens" if "context_tokens" in str(e) else f"refused: {e}"
    expect({"load": load}, load=expected_load)
