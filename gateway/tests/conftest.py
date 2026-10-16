"""Test chassis for the gateway island.

- `rule("GW-…")`: the one marker string with two duties — the report taxonomy and the link back
  to the spec heading. Fails at COLLECTION when `specs/` has no `## GW-…` heading (ported from
  oracle-fleet's tests/evidence.py, minus allure). With `GATEWAY_SPECS_OPTIONAL=1` and no
  `specs/` dir the check skips with a warning (a service-half-only checkout).
- The evidence plugin: every test's (rule, row id, outcome, duration) → `evidence/evidence.json`.
- Fake upstreams: one in-process Starlette app per rail, reached through httpx's ASGI transport
  (offline, deterministic). The kube API is the `CredentialSource` seam (`StaticSecrets`).
"""

from __future__ import annotations

import functools
import json
import os
import re
import time
import warnings
from pathlib import Path

import httpx
import pytest
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse
from starlette.routing import Route

from agent_gateway.app import create_app
from agent_gateway.config import Policy, Settings
from agent_gateway.credentials import StaticSecrets
from agent_gateway.store import Store

HERE = Path(__file__).resolve().parent
ISLAND = HERE.parent
SPECS = ISLAND / "specs"
EVIDENCE_DIR = ISLAND / "evidence"
POLICY_FIXTURE = HERE / "fixtures" / "policy-default.json"

_WARNED: list[str] = []
_RULE_RE = re.compile(r"^#{2,6}\s+(GW-[A-Z0-9-]+)(?:\s|$)")


# ---------------------------------------------------------------------------------------------
# rule() — the marker + collection-time check
# ---------------------------------------------------------------------------------------------
@functools.cache
def rule_index() -> dict[str, str] | None:
    """rule ID → page (relative to specs/) from `## GW-…` headings; None when specs/ is absent."""
    if not SPECS.is_dir():
        return None
    index: dict[str, str] = {}
    for md in sorted(SPECS.rglob("*.md")):
        page = md.relative_to(SPECS).as_posix()
        for line in md.read_text(encoding="utf-8").splitlines():
            m = _RULE_RE.match(line)
            if m:
                index[m.group(1)] = page
    return index


def rule(rule_id: str):
    """`@rule("GW-SESSIONS-ADMIT")` on a test or `pytestmark = rule("GW-…")` module-wide."""
    index = rule_index()
    if index is None:
        if os.environ.get("GATEWAY_SPECS_OPTIONAL") == "1":
            if not _WARNED:
                _WARNED.append(rule_id)
                warnings.warn("rule(): specs/ absent — heading checks skipped (GATEWAY_SPECS_OPTIONAL=1)", stacklevel=2)
        else:
            raise ValueError(f"rule({rule_id!r}): specs/ is absent — set GATEWAY_SPECS_OPTIONAL=1 for a service-only checkout")
    elif rule_id not in index:
        known = ", ".join(sorted(index)) or "<none>"
        raise ValueError(f"rule({rule_id!r}): no such `## {rule_id}` heading in specs/ — labels drift silently, so this fails loudly. Known: {known}")
    return pytest.mark.rule(rule_id)


# ---------------------------------------------------------------------------------------------
# the evidence plugin
# ---------------------------------------------------------------------------------------------
_ROWS: list[dict] = []


def pytest_runtest_logreport(report):
    if report.when != "call" and not (report.when == "setup" and report.outcome != "passed"):
        return
    item_rule = getattr(report, "_gw_rule", None)
    _ROWS.append(
        {
            "rule": item_rule,
            "module": report.location[0],
            "test": report.location[2],
            "row": _row_id(report.nodeid),
            "outcome": report.outcome,
            "duration_s": round(report.duration, 4),
        }
    )


def _row_id(nodeid: str) -> str:
    m = re.search(r"\[(.*)\]$", nodeid)
    return m.group(1) if m else nodeid.rsplit("::", 1)[-1]


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()
    marker = item.get_closest_marker("rule")
    report._gw_rule = marker.args[0] if marker else None


def pytest_sessionfinish(session, exitstatus):
    EVIDENCE_DIR.mkdir(exist_ok=True)
    rules: dict[str, dict] = {}
    for r in _ROWS:
        rid = r["rule"] or "(unlabelled)"
        bucket = rules.setdefault(rid, {"rows": [], "passed": 0, "failed": 0, "skipped": 0})
        bucket["rows"].append({k: r[k] for k in ("module", "test", "row", "outcome", "duration_s")})
        bucket[r["outcome"] if r["outcome"] in ("passed", "failed", "skipped") else "failed"] += 1
    doc = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "git_sha": _pr_head_sha() or os.environ.get("GITHUB_SHA") or _git_sha(),
        "policy_sha256": _sha256(POLICY_FIXTURE),
        "exitstatus": int(exitstatus),
        "rules": rules,
    }
    (EVIDENCE_DIR / "evidence.json").write_text(json.dumps(doc, indent=1, sort_keys=True) + "\n", encoding="utf-8")


def _pr_head_sha() -> str | None:
    """On a `pull_request` run GITHUB_SHA is the test-MERGE commit, which no PR ever shows as its
    head — so a stamp built from it can never name the head a reviewer is looking at. The event
    payload carries the real head; prefer it (push runs have no pull_request key → None)."""
    path = os.environ.get("GITHUB_EVENT_PATH")
    if not path:
        return None
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))["pull_request"]["head"]["sha"] or None
    except (OSError, ValueError, KeyError, TypeError):
        return None


def _git_sha() -> str | None:
    import subprocess

    try:
        return subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, cwd=ISLAND, check=True).stdout.strip()
    except Exception:  # noqa: BLE001
        return None


def _sha256(path: Path) -> str | None:
    import hashlib

    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


# ---------------------------------------------------------------------------------------------
# fake upstreams — one Starlette app per rail; behaviour switched by the `behaviour` knob
# (specs/worlds/: upstream-ok | upstream-429 | upstream-401 | upstream-stream; the transport-level
# worlds upstream-down / upstream-slow live on RailTransport below)
# ---------------------------------------------------------------------------------------------
class FakeUpstream:
    def __init__(self, rail: str):
        self.rail = rail
        self.behaviour = "upstream-ok"
        self.calls: list[dict] = []
        self.app = Starlette(
            routes=[
                Route("/v1/messages", self._messages, methods=["POST"]),
                Route("/v1/chat/completions", self._chat, methods=["POST"]),
                Route("/v1/models", self._models, methods=["GET"]),
            ]
        )

    async def _record(self, request: Request) -> dict:
        raw = await request.body()
        call = {
            "path": request.url.path,
            "query": request.url.query,
            "headers": dict(request.headers),
            "body": json.loads(raw) if raw else None,
            "raw": raw,
        }
        self.calls.append(call)
        return call

    def _behave(self) -> Response | None:
        if self.behaviour == "upstream-429":
            return JSONResponse({"error": {"type": "rate_limit_error", "message": "slow down"}}, status_code=429,
                                headers={"retry-after": "30"})
        if self.behaviour == "upstream-429-no-header":
            return JSONResponse({"error": {"type": "rate_limit_error"}}, status_code=429)
        if self.behaviour == "upstream-401":
            return JSONResponse({"error": {"type": "authentication_error", "message": "invalid x-api-key sk-ant-oat-LEAK"}}, status_code=401)
        if self.behaviour == "upstream-400-missing-session":
            return JSONResponse({"type": "MissingSessionID", "message": "Error from provider (Console Go): Request is missing x-opencode-session and cannot be routed efficiently"}, status_code=400)
        if self.behaviour == "upstream-403":
            return JSONResponse({"error": {"type": "permission_error"}}, status_code=403)
        if self.behaviour == "upstream-500":
            return JSONResponse({"error": "boom"}, status_code=500)
        return None

    async def _messages(self, request: Request) -> Response:
        call = await self._record(request)
        if (r := self._behave()) is not None:
            return r
        model = (call["body"] or {}).get("model")
        if self.behaviour == "upstream-stream":
            return StreamingResponse(_anthropic_sse(model), media_type="text/event-stream", headers={"x-fake-rail": self.rail})
        return JSONResponse(
            {"id": "msg_1", "type": "message", "role": "assistant", "model": model,
             "content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn",
             "usage": {"input_tokens": 11, "output_tokens": 5}},
            headers={"x-fake-rail": self.rail},
        )

    async def _chat(self, request: Request) -> Response:
        call = await self._record(request)
        if (r := self._behave()) is not None:
            return r
        model = (call["body"] or {}).get("model")
        if self.behaviour == "upstream-stream":
            return StreamingResponse(_openai_sse(model), media_type="text/event-stream", headers={"x-fake-rail": self.rail})
        return JSONResponse(
            {"id": "chatcmpl-1", "object": "chat.completion", "model": model,
             "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}],
             "usage": {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10}},
            headers={"x-fake-rail": self.rail},
        )

    async def _models(self, request: Request) -> Response:
        await self._record(request)
        if (r := self._behave()) is not None:
            return r
        return JSONResponse({"object": "list", "data": [{"id": "fake-model", "object": "model"}]}, headers={"x-fake-rail": self.rail})


async def _anthropic_sse(model):
    events = [
        ("message_start", {"type": "message_start", "message": {"id": "msg_s", "type": "message", "role": "assistant", "model": model, "content": [], "usage": {"input_tokens": 23, "output_tokens": 1}}}),
        ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
        ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hel"}}),
        ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "lo"}}),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 9}}),
        ("message_stop", {"type": "message_stop"}),
    ]
    for name, ev in events:
        yield f"event: {name}\ndata: {json.dumps(ev)}\n\n".encode()


async def _openai_sse(model):
    chunks = [
        {"id": "c", "object": "chat.completion.chunk", "model": model, "choices": [{"index": 0, "delta": {"role": "assistant", "content": "Hel"}}]},
        {"id": "c", "object": "chat.completion.chunk", "model": model, "choices": [{"index": 0, "delta": {"content": "lo"}}]},
        {"id": "c", "object": "chat.completion.chunk", "model": model, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 19, "completion_tokens": 4}},
    ]
    for c in chunks:
        yield f"data: {json.dumps(c)}\n\n".encode()
    yield b"data: [DONE]\n\n"


class RailTransport(httpx.AsyncBaseTransport):
    """Routes the gateway's upstream calls to the fake app whose base URL matches."""

    def __init__(self, upstreams: dict[str, FakeUpstream], bases: dict[str, str]):
        self.bases = {rail: httpx.URL(base) for rail, base in bases.items()}
        self.transports = {rail: httpx.ASGITransport(app=u.app) for rail, u in upstreams.items()}
        self.unreachable: set[str] = set()  # the `upstream-down` world: a connect failure that is not a timeout
        self.slow: set[str] = set()  # the `upstream-slow` world, clock-faked: the read "takes" > 600 s

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        for rail, base in self.bases.items():
            if request.url.host == base.host and request.url.path.startswith(base.path.rstrip("/") + "/"):
                if rail in self.unreachable:
                    raise httpx.ConnectError(f"{rail} upstream unreachable (fake)", request=request)
                if rail in self.slow:
                    raise httpx.ReadTimeout(f"{rail} upstream read past 600 s (fake)", request=request)
                prefix = base.path.rstrip("/")
                sub = request.url.copy_with(path=request.url.path[len(prefix):])
                return await self.transports[rail].handle_async_request(httpx.Request(request.method, sub, headers=request.headers, content=request.content))
        raise httpx.ConnectError(f"no fake upstream for {request.url}", request=request)


# ---------------------------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------------------------
UPSTREAM_BASES = {
    "anthropic": "https://api.anthropic.test",
    "openrouter": "https://openrouter.test/api",
    "opencode": "https://opencode.test/zen/go",
}
SELF_URL = "http://agent-gateway.agent-egress.svc.cluster.local:8080"
GO_KEY = "go-key-for-tests-only"
ANTHROPIC_TOKEN = "sk-ant-oat-test-subscription-token"
OPENROUTER_KEY = "sk-or-v1-test-openrouter-key"


class Clock:
    def __init__(self, t: float = 1_800_000_000.0):
        self.t = t

    def __call__(self) -> float:
        return self.t

    def advance(self, s: float) -> None:
        self.t += s


@pytest.fixture
def policy() -> Policy:
    return Policy.load(POLICY_FIXTURE)


@pytest.fixture
def clock() -> Clock:
    return Clock()


@pytest.fixture
def secrets() -> StaticSecrets:
    """Every stack's refs resolvable + labelled; tests mutate for the negative rows."""
    s = StaticSecrets()
    for ns, ref in (("platform-agents", "platform-openrouter"), ("oracle-agents", "oracle-openrouter")):
        s.secrets[f"{ns}/{ref}"] = StaticSecrets.secret(OPENROUTER_KEY, "OPENROUTER_API_KEY")
    for ns in ("platform-agents", "oracle-agents"):
        s.secrets[f"{ns}/claude-session"] = StaticSecrets.secret(ANTHROPIC_TOKEN, "AUTH_TOKEN")
    return s


@pytest.fixture
def upstreams() -> dict[str, FakeUpstream]:
    return {rail: FakeUpstream(rail) for rail in UPSTREAM_BASES}


@pytest.fixture
def transport(upstreams) -> RailTransport:
    return RailTransport(upstreams, UPSTREAM_BASES)


@pytest.fixture
def settings(tmp_path) -> Settings:
    return Settings.from_env(
        {
            "GATEWAY_POLICY": str(POLICY_FIXTURE),
            "GATEWAY_DB": str(tmp_path / "gateway.db"),
            "GATEWAY_SELF_URL": SELF_URL,
            "ANTHROPIC_UPSTREAM": UPSTREAM_BASES["anthropic"],
            "OPENROUTER_UPSTREAM": UPSTREAM_BASES["openrouter"],
            "OPENCODE_GO_UPSTREAM": UPSTREAM_BASES["opencode"],
            "OPENCODE_GO_API_KEY": GO_KEY,
        }
    )


@pytest.fixture
def store(settings) -> Store:
    return Store(settings.db_path)


@pytest.fixture
async def app(settings, policy, secrets, store, transport, clock):
    client = httpx.AsyncClient(transport=transport)
    a = create_app(settings, policy=policy, source=secrets, store=store, client=client, clock=clock)
    yield a
    await client.aclose()


@pytest.fixture
async def gw(app):
    """An httpx client against the gateway itself (ASGI, in-process)."""
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://gw") as c:
        yield c


async def open_session(gw, **body) -> dict:
    defaults = {"stack": "platform", "role": "worker", "task": "homelab-2588-r1"}
    r = await gw.post("/sessions", json={**defaults, **body})
    assert r.status_code == 200, r.text
    doc = r.json()
    assert doc["decision"] == "dispatch", doc
    return doc


def err(r) -> str:
    """The error envelope's code: {error: {code, message}}."""
    body = r.json()
    assert set(body) == {"error"} and set(body["error"]) == {"code", "message"}, body
    return body["error"]["code"]


def bearer(doc: dict) -> dict[str, str]:
    return {"authorization": f"Bearer {doc['session']['token']}"}
