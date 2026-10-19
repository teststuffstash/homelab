"""The `policy-codex` world (specs/worlds/README.md): the codex rail's fake upstream, the FAKE
credential store and fixtures. Not a test module — the codex test modules import its fixtures.

Every credential here is an obviously-fake `DUMMY-SECRET-…` string; nothing real is minted, read or
written, and the store is process memory (GW-CODEX-OAUTH: the FAKE store only).
"""

from __future__ import annotations

import asyncio
import copy
import dataclasses
import json
import threading
from collections.abc import Callable

import httpx
import pytest
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import Response, StreamingResponse
from starlette.routing import Route

from agent_gateway.app import create_app
from agent_gateway.codex import CodexBackend
from agent_gateway.config import Policy
from agent_gateway.oauth import Credential, Record

from .conftest import (
    HERE,
    UPSTREAM_BASES,
    RailTransport,
    _body_of,
    _headers,
    attach_json,
    given,
    open_session,
    quiet,
    when,
)

CODEX_POLICY = HERE / "fixtures" / "policy-codex.json"
CODEX_BASE = "https://codex.test/backend-api/codex"
WIRE_MODEL = "fixture-model"  # rails.codex.models.* = codex/fixture-model, prefix stripped
TEXT = "codex fixture complete"
ACCOUNT = "dummy-account"


def sse(kind: str, **fields) -> bytes:
    return ("event: " + kind + "\ndata: " + json.dumps({"type": kind, **fields}) + "\n\n").encode()


def completion(usage: dict | None = None, terminal: str = "response.completed", status: str = "completed",
               duplicate: dict | None = None) -> list[bytes]:
    """A Responses stream in the shape the native CLI accepted (experiments/codex-rail/compat.py)."""
    usage = usage if usage is not None else {"input_tokens": 7, "output_tokens": 3, "total_tokens": 10,
                                             "input_tokens_details": {"cached_tokens": 0},
                                             "output_tokens_details": {"reasoning_tokens": 0}}
    item = {"id": "msg_fixture", "type": "message", "role": "assistant", "status": "completed",
            "content": [{"type": "output_text", "text": TEXT, "annotations": []}]}
    response = {"id": "resp_fixture", "object": "response", "created_at": 1, "status": status,
                "model": WIRE_MODEL, "output": [item], "usage": usage}
    events = [sse("response.created", response={**response, "status": "in_progress", "output": []}),
              sse("response.output_item.added", output_index=0, item={**item, "status": "in_progress", "content": []}),
              sse("response.output_text.delta", item_id=item["id"], output_index=0, content_index=0, delta=TEXT),
              sse("response.output_item.done", output_index=0, item=item)]
    if terminal:
        events.append(sse(terminal, response=response))
    if duplicate is not None:
        events.append(sse("response.completed", response={**response, "usage": duplicate}))
    return events


CACHED_USAGE = {"input_tokens": 312, "output_tokens": 7, "input_tokens_details": {"cached_tokens": 300}}

BEHAVIOURS = {  # name → (status, content-type, extra headers, body chunks)
    "upstream-ok": lambda: (200, "text/event-stream", {}, completion()),
    "upstream-ok-cached": lambda: (200, "text/event-stream", {}, completion(CACHED_USAGE)),
    "upstream-stream-failed": lambda: (200, "text/event-stream", {}, completion(terminal="response.failed", status="failed")),
    "upstream-stream-incomplete": lambda: (200, "text/event-stream", {}, completion(terminal="response.incomplete", status="incomplete")),
    "upstream-stream-truncated": lambda: (200, "text/event-stream", {}, completion(terminal="")),
    "upstream-stream-invalid": lambda: (200, "text/event-stream", {}, completion()[:2] + [b"data: DUMMY-SECRET-not-json\n\n"]),
    "upstream-stream-duplicate": lambda: (200, "text/event-stream", {}, completion(duplicate={"input_tokens": 99, "output_tokens": 99})),
    "upstream-401": lambda: (401, "application/json", {}, [b'{"error":{"message":"invalid token DUMMY-SECRET-LEAK"}}']),
    "upstream-403": lambda: (403, "application/json", {}, [b'{"error":{"message":"forbidden"}}']),
    "upstream-429": lambda: (429, "application/json", {"retry-after": "30"}, [b'{"error":{"type":"usage_limit_reached"}}']),
    "upstream-500": lambda: (500, "application/json", {}, [b'{"error":"boom"}']),
    "upstream-302": lambda: (302, "text/html", {"location": "http://127.0.0.1:1/never-follow"}, [b""]),
    "upstream-wrong-type": lambda: (200, "application/json", {}, [b'{"output":[]}']),
}


class FakeCodexUpstream:
    """The ChatGPT backend's Responses endpoint, offline: one `POST /responses`."""

    rail = "codex"

    def __init__(self):
        self.behaviour = "upstream-ok"
        self.calls: list[dict] = []
        # Extra response headers (the turn-state rows: what the backend issues) — a dict, or a callable
        # of the recorded call (per-turn issuance for the ordering row).
        self.response_headers: dict[str, str] | Callable[[dict], dict[str, str]] = {}
        self.hold_first: asyncio.Event | None = None  # the turn-state ordering row: the FIRST call answers only once set
        self.app = Starlette(routes=[Route("/responses", self._responses, methods=["POST"])])

    async def _responses(self, request: Request) -> Response:
        raw = await request.body()
        call = {"path": request.url.path, "headers": dict(request.headers), "raw": raw,
                "body": json.loads(raw) if raw else None}
        self.calls.append(call)
        if self.hold_first is not None and len(self.calls) == 1:
            await self.hold_first.wait()
        status, ctype, extra, chunks = BEHAVIOURS[self.behaviour]()
        issued = self.response_headers(call) if callable(self.response_headers) else self.response_headers
        extra = {**extra, **issued}
        if ctype == "text/event-stream" and status == 200:
            async def gen():
                for c in chunks:
                    yield c
            resp: Response = StreamingResponse(gen(), status_code=status, media_type=ctype, headers=extra)
            shown = f"<{len(chunks)} SSE events — {self.behaviour}>"
        else:
            resp = Response(b"".join(chunks), status_code=status, media_type=ctype, headers=extra)
            shown = _body_of(b"".join(chunks), ctype)
        attach_json(f"upstream codex {call['path']} → {status}",
                    {"behaviour": self.behaviour,
                     "request": {"path": call["path"], "headers": _headers(call["headers"]), "body": call["body"]},
                     "response": {"status": status, "headers": _headers(resp.headers), "body": shown}})
        return resp


class MemoryStore:
    """The FAKE credential store (GW-CODEX-OAUTH): a fake durable medium that survives owner
    replacement. `fail_at` = the save number that raises; `commit_then_fail` = it commits first."""

    def __init__(self, credential: Credential):
        self.record = Record(credential)
        self.mutex = threading.Lock()
        self.writes = 0
        self.loads = 0
        self.fail_at: int | None = None
        self.commit_then_fail = False

    def lock(self):
        return self.mutex

    def load(self) -> Record:
        self.loads += 1
        return copy.deepcopy(self.record)

    def save(self, record: Record) -> None:
        self.writes += 1
        if self.writes == self.fail_at:
            if self.commit_then_fail:
                self.record = copy.deepcopy(record)
            raise RuntimeError("DUMMY-SECRET storage detail")
        self.record = copy.deepcopy(record)


class Exchange:
    """The fake refresh exchange: counts calls, returns the rotated credential (or raises `fault`)."""

    def __init__(self, store: MemoryStore, rotated: Credential):
        self.store, self.rotated = store, rotated
        self.calls = 0
        self.fault: BaseException | None = None
        self.states_seen: list[str] = []

    def __call__(self, old: Credential) -> Credential:
        self.states_seen.append(self.store.record.state)  # the write-ahead marker must be durable first
        self.calls += 1
        if self.fault is not None:
            raise self.fault
        return self.rotated


def creds(clock) -> tuple[Credential, Credential]:
    """(the stored credential, near expiry; its rotation)."""
    old = Credential("DUMMY-SECRET-access", "DUMMY-SECRET-refresh", ACCOUNT, clock.t + 1)
    new = Credential("DUMMY-SECRET-rotated-access", "DUMMY-SECRET-rotated-refresh", ACCOUNT, clock.t + 2000)
    return old, new


def fresh_report(clock, used=(20, 64), limited=False, age=10, resets=(1000, 8000), source="poll") -> dict:
    return {"observed_at": clock.t - age, "source": source, "limited": limited,
            "windows": [{"used_percent": used[0], "resets_at": clock.t + resets[0], "window_minutes": 300},
                        {"used_percent": used[1], "resets_at": clock.t + resets[1], "window_minutes": 10080}]}


@pytest.fixture
def codex_policy() -> Policy:
    return Policy.load(CODEX_POLICY)


@pytest.fixture
def codex_upstream() -> FakeCodexUpstream:
    return FakeCodexUpstream()


@pytest.fixture
def codex_store(clock) -> MemoryStore:
    return MemoryStore(creds(clock)[0])


@pytest.fixture
def exchange(codex_store, clock) -> Exchange:
    return Exchange(codex_store, creds(clock)[1])


@pytest.fixture
def codex_transport(upstreams, codex_upstream) -> RailTransport:
    return RailTransport({**upstreams, "codex": codex_upstream}, {**UPSTREAM_BASES, "codex": CODEX_BASE})


@pytest.fixture
async def codex_app(settings, codex_policy, secrets, store, codex_transport, clock, codex_store, exchange):
    client = httpx.AsyncClient(transport=codex_transport)
    s = dataclasses.replace(settings, upstreams={**settings.upstreams, "codex": CODEX_BASE})
    a = create_app(s, policy=codex_policy, source=secrets, store=store, client=client, clock=clock,
                   codex_backend=CodexBackend(codex_store, exchange))
    yield a
    await client.aclose()


@pytest.fixture
async def codex_gw(codex_app):
    from .conftest import ObservedAsyncClient

    async with ObservedAsyncClient(transport=httpx.ASGITransport(app=codex_app), base_url="http://gw") as c:
        yield c


def observe(app, report: dict) -> None:
    """Given: an accepted headroom observation (the in-process seam — ingress itself is a ⚑ gap)."""
    with given(f"headroom observed: {report['source']} at now−{app.state.codex.headroom.clock() - report['observed_at']:g}s, "
               f"windows {[w['used_percent'] for w in report['windows']]}%, limited={report['limited']}"):
        app.state.codex.headroom.observe(report)
        attach_json("headroom report", report)


async def admitted(app, gw, clock, **extra) -> dict:
    """Given: a codex session (prober, harness codex) admitted on fresh headroom — the report and the
    dispatch muted, ONE summary attachment (report hygiene: arrange is not the evidence)."""
    with given("a codex session (prober, harness codex) admitted on fresh headroom 20 % / 64 %"):
        with quiet():
            app.state.codex.headroom.observe(fresh_report(clock))
            doc = await codex_session(gw, **extra)
        attach_json("arranged: headroom 20/64 observed, session dispatched",
                    {"rail": doc["rail"], "model": doc["model"], "session": doc["session"]["id"]})
    return doc


async def codex_session(gw, **extra) -> dict:
    return await open_session(gw, role="prober", harness="codex", task="oracle-562-probe", **extra)


def body(**over) -> dict:
    return {"model": WIRE_MODEL, "stream": True, "store": False,
            "input": [{"role": "user", "content": [{"type": "input_text", "text": "hi"}]}], **over}


async def ride(gw, doc: dict, payload: dict | None = None, headers: dict | None = None, label: str = ""):
    h = {"authorization": f"Bearer {doc['session']['token']}", **(headers or {})}
    p = body() if payload is None else payload
    with when(f"POST /openai/v1/responses{' · ' + label if label else ''} · body {({k: v for k, v in p.items() if k != 'input'})}"
              + (f" · inbound {headers}" if headers else "")):
        return await gw.post("/openai/v1/responses", json=p, headers=h)
