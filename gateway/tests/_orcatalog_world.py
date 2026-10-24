"""The OpenRouter catalog's fake sources (GW-CATALOG-OR; specs/worlds/README.md §The openrouter-catalog world).

Two in-process fakes: the MCP server (`mcp.openrouter.test/mcp` — JSON-RPC `initialize` + `tools/call`
for `list-daily-model-rankings` per slice and `list-benchmarks`) answering from the fixtures in
`tests/fixtures/openrouter-catalog/` (trimmed from the live MCP answers of 2026-10-19), and the
endpoints route on the openrouter rail's fake (`/v1/models/{author}/{slug}/endpoints`) answering
the two endpoint fixtures (deepseek-v4.1-flash, glm-5.3-flash) and 404 for every other model.
Offline, deterministic.
"""

from __future__ import annotations

import json
from pathlib import Path

import httpx
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse, Response
from starlette.routing import Route

from .conftest import _body_of, _headers, attach_json

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "openrouter-catalog"
MCP_URL = "https://mcp.openrouter.test/mcp"
ACCOUNT_REF = "agent-egress/router-account-key"
ACCOUNT_KEY = "sk-or-v1-test-account-key"
ENDPOINT_FIXTURES = {"deepseek/deepseek-v4.1-flash": "deepseek-v4.1-flash.json", "z-ai/glm-5.3-flash": "glm-5.3-flash.json"}
# ranked (the latest week, both slices) ∩ AA-benched, in the fixtures: the seven below — two with endpoint fixtures
BENCHED_RANKED = ("anthropic/claude-opus-5.5", "deepseek/deepseek-v4-flash", "deepseek/deepseek-v4.1-flash", "moonshotai/kimi-k3",
                  "xiaomi/mimo-v2.5", "xiaomi/mimo-v2.6-flash", "z-ai/glm-5.3-flash")


def fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class FakeMcp:
    """`mcp` = ok | 503 | down (the transport) | malformed (a tool result that is not JSON) |
    rankings-undated (rows without `date`) | benchmarks-empty."""

    def __init__(self):
        self.mcp = "ok"
        self.calls: list[dict] = []
        self.app = Starlette(routes=[Route("/mcp", self._mcp, methods=["POST"])])

    async def _mcp(self, request: Request) -> Response:
        body = json.loads(await request.body())
        call = {"method": body.get("method"), "params": body.get("params"), "headers": dict(request.headers)}
        self.calls.append(call)
        resp = self._answer(body)
        attach_json(f"mcp {body.get('method')} {((body.get('params') or {}).get('name') or '')} → {resp.status_code}",
                    {"behaviour": self.mcp, "request": {"method": body.get("method"), "params": body.get("params"),
                                                        "headers": _redacted(_headers(request.headers))},
                     "response": {"status": resp.status_code, "body": _body_of(getattr(resp, "body", b""), resp.media_type)}})
        return resp

    def _answer(self, body: dict) -> Response:
        if self.mcp == "503":
            return JSONResponse({"error": "unavailable"}, status_code=503)
        if body.get("method") == "initialize":
            return JSONResponse({"jsonrpc": "2.0", "id": body.get("id"), "result": {"protocolVersion": "2025-03-26", "capabilities": {}}})
        params = body.get("params") or {}
        tool, args = params.get("name"), (params.get("arguments") or {}).get("request") or {}
        if self.mcp == "malformed":
            return _tool(body, "not json at all")
        if tool == "list-daily-model-rankings":
            name = "rankings-programming.json" if args.get("category") == "programming" else "rankings-tool_calling.json"
            doc = fixture(name)
            if self.mcp == "rankings-undated":
                doc = {"data": [{k: v for k, v in r.items() if k != "date"} for r in doc["data"]], "meta": doc["meta"]}
            return _tool(body, json.dumps(doc))
        if tool == "list-benchmarks":
            doc = fixture("benchmarks-aa.json")
            if self.mcp == "benchmarks-empty":
                doc = {"data": [], "meta": doc["meta"]}
            return _tool(body, json.dumps(doc))
        return JSONResponse({"jsonrpc": "2.0", "id": body.get("id"), "error": {"code": -32601, "message": f"unknown tool {tool}"}})


def _tool(body: dict, text: str) -> JSONResponse:
    return JSONResponse({"jsonrpc": "2.0", "id": body.get("id"), "result": {"content": [{"type": "text", "text": text}]}})


def _redacted(h: dict) -> dict:
    return {k: ("Bearer <the account key>" if k.lower() == "authorization" else v) for k, v in h.items()}


def endpoints_answer(model: str, behaviour: str) -> Response:
    """The openrouter rail fake's `/v1/models/<id>/endpoints` answer: the fixture, or the behaviour."""
    if behaviour == "endpoints-503":
        return JSONResponse({"error": "unavailable"}, status_code=503)
    if behaviour == "endpoints-malformed":
        return JSONResponse({"data": {"id": model, "endpoints": [{"tag": "x"}]}})
    name = ENDPOINT_FIXTURES.get(model)
    if name is None:
        return PlainTextResponse("not found", status_code=404)
    doc = fixture(name)
    if behaviour.startswith("endpoints-null-uptime"):  # the vendor's answer for a fresh or idle endpoint (seen live 2026-10-20)
        tag = behaviour.partition("@")[2]  # `endpoints-null-uptime@<tag>` names the endpoint; bare = the first row
        rows = doc["data"]["endpoints"]
        (next(e for e in rows if e["tag"] == tag) if tag else rows[0])["uptime_last_1d"] = None
    return JSONResponse(doc)


class McpTransport(httpx.AsyncBaseTransport):
    """The MCP host → the fake MCP; everything else → the vendor + rails transport."""

    def __init__(self, mcp: FakeMcp, inner: httpx.AsyncBaseTransport):
        self.mcp = httpx.ASGITransport(app=mcp.app)
        self.inner = inner
        self.down = False

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        if request.url.host == httpx.URL(MCP_URL).host:
            if self.down:
                raise httpx.ConnectError("mcp unreachable (fake)", request=request)
            return await self.mcp.handle_async_request(request)
        return await self.inner.handle_async_request(request)
