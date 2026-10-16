"""Test chassis for the gateway island — the oracle-fleet evidence conventions
(oracle-fleet docs/process/conventions.md; homelab ADR-156: one portable process).

- `rule("GW-…")`: one string, three duties — the Allure taxonomy (story == rule ID; epic == spec
  page; feature == the section the rule sits under; a link to the spec anchor), the legacy
  `rule` marker the evidence/evidence.json collector below reads, and the link back to the spec
  heading. Fails at COLLECTION when `specs/` has no `## GW-…` heading. With
  `GATEWAY_SPECS_OPTIONAL=1` and no `specs/` dir the check skips with a warning.
- The steps (§ Prime rule of reporting): every case reads `world()` → `given()` → ONE `when()`
  → one `then()` per claim; names carry the row's values; every verdict is a step carrying its
  compared values as a `verdict: …` JSON attachment. Every rule-labelled case names its world
  (`world()` — the `world` Allure label; a case that names none fails at teardown).
- Prime rule: every gateway exchange (`gw` fixture) and every fake-upstream exchange attaches ONE
  small JSON under the step that is open when it happens. `quiet()` mutes bulk arrange (filling
  a rail's cap) — the caller attaches one summary instead.
- The evidence plugin: every test's (rule, row id, outcome, duration) → `evidence/evidence.json`
  (read by scripts/evidence_render.py), plus `environment.properties` (+ `executor.json` in CI)
  in the Allure results dir.
- Fake upstreams: one in-process Starlette app per rail, reached through httpx's ASGI transport
  (offline, deterministic). The kube API is the `CredentialSource` seam (`StaticSecrets`).
"""

from __future__ import annotations

import contextlib
import contextvars
import functools
import hashlib
import json
import os
import re
import time
import warnings
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import allure
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
# The ONE place the spec-site URL pattern lives (mkdocs.yml: use_directory_urls: false). CI may
# point it at a PR preview (…/pr-<N>) so evidence links the spec revision it was earned against.
SPECS_BASE_URL = os.environ.get("SPECS_BASE_URL", "https://gateway-specs.homelab.teststuff.net").rstrip("/")
SPEC_URL = SPECS_BASE_URL + "/specs/{page}.html#{anchor}"

_WARNED: list[str] = []
_RULE_RE = re.compile(r"^#{2,6}\s+(GW-[A-Z0-9-]+)(?:\s|$)")
_HEAD_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")


# ---------------------------------------------------------------------------------------------
# rule() — the marker + collection-time check
# ---------------------------------------------------------------------------------------------
@functools.cache
def rule_pages() -> dict[str, tuple[str, str]] | None:
    """rule ID → (page stem relative to specs/, enclosing section) from `## GW-…` headings;
    None when specs/ is absent."""
    if not SPECS.is_dir():
        return None
    index: dict[str, tuple[str, str]] = {}
    for md in sorted(SPECS.rglob("*.md")):
        page = md.relative_to(SPECS).with_suffix("").as_posix()
        sections: dict[int, str] = {}
        for line in md.read_text(encoding="utf-8").splitlines():
            head = _HEAD_RE.match(line)
            if not head:
                continue
            level = len(head.group(1))
            m = _RULE_RE.match(line)
            if m:
                index[m.group(1)] = (page, next((sections[lv] for lv in range(level - 1, 0, -1) if lv in sections), page))
            else:
                sections[level] = head.group(2)
                for deeper in [lv for lv in sections if lv > level]:
                    del sections[deeper]
    return index


def rule(rule_id: str) -> list:
    """`pytestmark = rule("GW-SESSIONS-ADMIT")` module-wide (a list of marks: the legacy `rule`
    marker + allure story/epic/feature/link)."""
    pages = rule_pages()
    if pages is None:
        if os.environ.get("GATEWAY_SPECS_OPTIONAL") == "1":
            if not _WARNED:
                _WARNED.append(rule_id)
                warnings.warn("rule(): specs/ absent — heading checks skipped (GATEWAY_SPECS_OPTIONAL=1)", stacklevel=2)
        else:
            raise ValueError(f"rule({rule_id!r}): specs/ is absent — set GATEWAY_SPECS_OPTIONAL=1 for a service-only checkout")
    elif rule_id not in pages:
        known = ", ".join(sorted(pages)) or "<none>"
        raise ValueError(f"rule({rule_id!r}): no such `## {rule_id}` heading in specs/ — labels drift silently, so this fails loudly. Known: {known}")
    marks = [pytest.mark.rule(rule_id), allure.story(rule_id)]
    if pages is not None:
        page, section = pages[rule_id]
        marks += [allure.epic(page), allure.feature(section),
                  allure.link(SPEC_URL.format(page=page, anchor=rule_id.lower()), name=f"spec: {rule_id}")]
    return marks


# ---------------------------------------------------------------------------------------------
# steps — given / when / then (conventions § Prime rule of reporting)
# ---------------------------------------------------------------------------------------------
_QUIET: contextvars.ContextVar[bool] = contextvars.ContextVar("gw_quiet", default=False)
_WORLD: dict[str, str | None] = {"name": None}


def attach_json(name: str, obj: Any) -> None:
    """One small JSON attachment under the open step (observability only — never raises)."""
    if _QUIET.get():
        return
    with contextlib.suppress(Exception):
        allure.attach(json.dumps(obj, indent=1, ensure_ascii=False, default=repr), name=name,
                      attachment_type=allure.attachment_type.JSON)


@contextlib.contextmanager
def quiet() -> Iterator[None]:
    """Mute exchange attachments for bulk arrange (e.g. filling a rail's cap); attach a summary."""
    tok = _QUIET.set(True)
    try:
        yield
    finally:
        _QUIET.reset(tok)


def world(policy: str = "policy-default", upstream: str | None = None, *, note: str | None = None) -> str:
    """Name the case's world (specs/worlds/README.md): a policy document + (when the row rides
    a rail) a fake-upstream behaviour. Sets the `world` Allure label and opens the first given
    step with the policy document attached (sha-stamped). The caller still applies a non-default
    upstream behaviour itself (`upstreams[rail].behaviour = …`) — the world NAMES it."""
    name = policy + (f" · {upstream}" if upstream else "")
    _WORLD["name"] = name
    with contextlib.suppress(Exception):
        allure.dynamic.label("world", name)
    with allure.step(f"Given: world {name}" + (f" — {note}" if note else "")):
        body = POLICY_FIXTURE.read_bytes()
        with contextlib.suppress(Exception):
            allure.attach(body.decode("utf-8"), name=f"world {policy} — policy-default.json (sha256:{hashlib.sha256(body).hexdigest()[:12]})",
                          attachment_type=allure.attachment_type.JSON)
    return name


@contextlib.contextmanager
def given(name: str) -> Iterator[None]:
    with allure.step(f"Given: {name}"):
        yield


@contextlib.contextmanager
def when(name: str) -> Iterator[None]:
    """Exactly ONE per case: the call under test; its exchange attaches under it."""
    with allure.step(f"When: {name}"):
        yield


@contextlib.contextmanager
def then(claim: str, **compared: Any) -> Iterator[None]:
    """A verdict as a STEP named with the claimed value; `compared` (`key={"expected": …,
    "actual": …}`) attaches as `verdict: <claim>`. Assertions run inside, so the step's status IS
    the verdict. When the actual value must be OBSERVED inside the step (a /metrics read, a store
    row), pass nothing here and call `check()` inside — the observation's exchange then attaches
    under this step, never flat at test level."""
    with allure.step(f"Then: {claim}"):
        if compared:
            attach_json(f"verdict: {claim}", compared)
        yield


def check(key: str, actual: Any, expected: Any) -> None:
    """Inside an open `then()`: attach `verdict: <key>` {expected, actual} and assert equality."""
    attach_json(f"verdict: {key}", {key: {"expected": expected, "actual": actual}})
    assert actual == expected, f"{key}: expected {expected!r}, got {actual!r}"


def then_eq(key: str, actual: Any, expected: Any, claim: str | None = None) -> None:
    """`Then: <key> = <expected>` — one equality claim on an already-observed value."""
    text = claim or f"{key} = {expected!r}"
    with then(text, **{key: {"expected": expected, "actual": actual}}):
        assert actual == expected, f"{text}: got {actual!r}"


def _body_of(content: bytes, ctype: str | None) -> Any:
    if not content:
        return None
    text = content.decode("utf-8", errors="replace")
    if ctype and "json" in ctype:
        with contextlib.suppress(ValueError):
            return json.loads(text)
    return text if len(text) <= 4096 else text[:4096] + f"… ({len(text)} chars)"


_DROP_HEADERS = {"content-length", "accept", "accept-encoding", "connection", "host"}


def _headers(h) -> dict[str, str]:
    return {k: v for k, v in h.items() if k.lower() not in _DROP_HEADERS}


class ObservedAsyncClient(httpx.AsyncClient):
    """Prime rule for HTTP: every gateway exchange attaches ONE JSON (request + response) under
    the step that is open — setup helpers included. Observability only, never request-building."""

    async def send(self, request: httpx.Request, **kwargs):  # type: ignore[override]
        response = await super().send(request, **kwargs)
        if not _QUIET.get() and not kwargs.get("stream"):
            attach_json(
                f"gateway {request.method} {request.url.path} → {response.status_code}",
                {"request": {"method": request.method, "path": request.url.path, "headers": _headers(request.headers),
                             "body": _body_of(request.content, request.headers.get("content-type"))},
                 "response": {"status": response.status_code, "headers": _headers(response.headers),
                              "body": _body_of(response.content, response.headers.get("content-type"))}},
            )
        return response


def _row_title(item) -> str | None:
    doc = (getattr(getattr(item, "function", None), "__doc__", None) or "").strip()
    return doc.splitlines()[0][len("row: "):].strip() if doc.startswith("row: ") else None


@pytest.hookimpl(tryfirst=True)
def pytest_runtest_call(item):
    """A function-per-row case's `row: <intent>` docstring is its Allure title — the evidence
    row's case, which the spec table's description cell joins on (set at call time: allure-pytest
    rewrites the name during setup)."""
    if title := _row_title(item):
        with contextlib.suppress(Exception):
            allure.dynamic.title(title)


@pytest.fixture(autouse=True)
def _evidence_case(request):
    """A rule-labelled case that named no world fails (conventions § Evidence row identity)."""
    _WORLD["name"] = None
    yield
    if request.node.get_closest_marker("rule") and _WORLD["name"] is None:
        pytest.fail(f"{request.node.nodeid}: names no world — call world(...) first (conventions § Evidence row identity)")


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
    _write_allure_run_meta(session.config, doc)


def _write_allure_run_meta(config, doc: dict) -> None:
    """`environment.properties` (+ `executor.json` in CI) into the Allure results dir — run
    metadata is a convention, not polish (conventions § Prime rule). `artifact` says what was
    tested: the PR head's SOURCE, in-process — never an image digest (no image ran; digest
    evidence needs the suite to run AGAINST the built image — specs-reviewer.md open question 2)."""
    alluredir = getattr(config.option, "allure_report_dir", None)
    if not alluredir:
        return
    out = Path(alluredir)
    out.mkdir(parents=True, exist_ok=True)
    head = _pr_head_sha()
    props = {
        # `git.commit` is the PINNED key (allure-behavior-snippets CONVENTIONS.md § The head/artifact
        # stamp — evidence-pack's stamp check reads it; any other spelling reads as unstamped).
        # `image.digest` is deliberately ABSENT: it is written only by a suite that ran against the
        # built image, which this one never does.
        "git.commit": doc["git_sha"] or "unknown",
        "git_sha_source": "pull_request.head.sha" if head else ("GITHUB_SHA" if os.environ.get("GITHUB_SHA") else "git rev-parse HEAD"),
        "policy_sha256": doc["policy_sha256"] or "unknown",
        "policy_file": POLICY_FIXTURE.relative_to(ISLAND).as_posix(),
        "run_timestamp": doc["generated_at"],
        "artifact": "pr-head (not the built image)",
        "suite": "gateway/tests (in-process ASGI, fake upstreams)",
    }
    (out / "environment.properties").write_text("".join(f"{k}={v}\n" for k, v in props.items()), encoding="utf-8")
    server, repo, run = (os.environ.get(k) for k in ("GITHUB_SERVER_URL", "GITHUB_REPOSITORY", "GITHUB_RUN_ID"))
    if server and repo and run:
        url = f"{server}/{repo}/actions/runs/{run}"
        executor = {"name": "GitHub Actions", "type": "github", "buildName": f"{os.environ.get('GITHUB_WORKFLOW', 'ci')} #{run}",
                    "buildUrl": url, "reportName": "agent-gateway evidence"}
        (out / "executor.json").write_text(json.dumps(executor, indent=1) + "\n", encoding="utf-8")


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

    def _reply(self, call: dict, response: Response) -> Response:
        """Prime rule for the stub side: the exchange the fake saw, under the open step."""
        body = getattr(response, "body", None)
        attach_json(
            f"upstream {self.rail} {call['path']} → {response.status_code}",
            {"behaviour": self.behaviour,
             "request": {"path": call["path"], "query": call["query"] or None, "headers": _headers(call["headers"]), "body": call["body"]},
             "response": {"status": response.status_code, "headers": _headers(response.headers),
                          "body": _body_of(body, response.media_type) if body is not None else f"<{response.media_type} stream — {self.rail} fake events>"}},
        )
        return response

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
            return self._reply(call, r)
        model = (call["body"] or {}).get("model")
        if self.behaviour == "upstream-stream":
            return self._reply(call, StreamingResponse(_anthropic_sse(model), media_type="text/event-stream", headers={"x-fake-rail": self.rail}))
        return self._reply(call, JSONResponse(
            {"id": "msg_1", "type": "message", "role": "assistant", "model": model,
             "content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn",
             "usage": {"input_tokens": 11, "output_tokens": 5}},
            headers={"x-fake-rail": self.rail},
        ))

    async def _chat(self, request: Request) -> Response:
        call = await self._record(request)
        if (r := self._behave()) is not None:
            return self._reply(call, r)
        model = (call["body"] or {}).get("model")
        if self.behaviour == "upstream-stream":
            return self._reply(call, StreamingResponse(_openai_sse(model), media_type="text/event-stream", headers={"x-fake-rail": self.rail}))
        return self._reply(call, JSONResponse(
            {"id": "chatcmpl-1", "object": "chat.completion", "model": model,
             "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}],
             "usage": {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10}},
            headers={"x-fake-rail": self.rail},
        ))

    async def _models(self, request: Request) -> Response:
        call = await self._record(request)
        if (r := self._behave()) is not None:
            return self._reply(call, r)
        return self._reply(call, JSONResponse({"object": "list", "data": [{"id": "fake-model", "object": "model"}]}, headers={"x-fake-rail": self.rail}))


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
    async with ObservedAsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://gw") as c:
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
