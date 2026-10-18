"""The Go catalog's fake vendor (GW-CATALOG-GO; specs/worlds/README.md §The Go catalog's fakes).

One in-process Starlette app answers both sources the leg reads — the console's V2 config and the
vendor's Go page source — from the fixtures in `tests/fixtures/go-catalog/` (trimmed from the live
answers of 2026-10-17). Each source has its own behaviour knob; the variants are derived from the
fixture in memory, so the file on disk is the one live-shaped copy. Offline, deterministic.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

import httpx
import pytest
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse, Response
from starlette.routing import Route

from agent_gateway.app import create_app
from agent_gateway.config import Settings

from .conftest import (
    GO_KEY,
    POLICY_FIXTURE,
    SELF_URL,
    UPSTREAM_BASES,
    ObservedAsyncClient,
    RailTransport,
    _body_of,
    _headers,
    attach_json,
)

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "go-catalog"
CONFIG_URL = "https://console.opencode.test/console/api/v2/config"
DOCS_URL = "https://raw.vendor.test/anomalyco/opencode/dev/go.mdx"
SHRUNK = ("deepseek-v4-pro", "deepseek-v4.1-flash")
TRIMMED = ("claude-haiku-5-5", "deepseek-v4-pro", "deepseek-v4.1-flash")
SHRUNK_NAMES = ("DeepSeek V4.1 Flash", "DeepSeek V4 Pro")


def config_doc(behaviour: str) -> dict:
    doc = json.loads((FIXTURES / "config.json").read_text(encoding="utf-8"))
    models = doc["providers"]["opencode-go"]["models"]
    if behaviour == "catalog-shrunk":
        doc["providers"]["opencode-go"]["models"] = {k: v for k, v in models.items() if k in SHRUNK}
    elif behaviour == "catalog-trimmed":
        doc["providers"]["opencode-go"]["models"] = {k: v for k, v in models.items() if k in TRIMMED}
    elif behaviour == "catalog-malformed":
        del models["deepseek-v4-pro"]["cost"]
    elif behaviour == "catalog-no-provider":
        doc["providers"] = {"opencode": copy.deepcopy(doc["providers"]["opencode-go"])}
    elif behaviour == "catalog-empty":
        doc["providers"]["opencode-go"]["models"] = {}
    return doc


def docs_text(behaviour: str) -> str:
    text = (FIXTURES / "go.mdx").read_text(encoding="utf-8")
    lines = text.splitlines()
    if behaviour == "docs-unknown-model":
        i = next(n for n, line in enumerate(lines) if "DeepSeek V4.1 Flash (Off-Peak)" in line)
        lines.insert(i, lines[i].replace("DeepSeek V4.1 Flash (Off-Peak)", "DeepSeek V4.2 Flash            "))
    elif behaviour == "docs-short-endpoint-row":
        i = next(n for n, line in enumerate(lines) if line.startswith("| Step 5 Preview ") and "step-5-preview" in line)
        lines[i] = "| Step 5 Preview |"
    elif behaviour == "docs-header-drift":
        lines = [line.replace("| Monthly limit ", "| Limit         ") for line in lines]
    elif behaviour == "docs-no-peak-hours":
        lines = [line for line in lines if "Peak hours are" not in line]
    elif behaviour == "docs-no-shares":
        lines = [line for line in lines if not line.startswith(("Each model has the following usage limits", "weekly — 50%"))]
    elif behaviour == "docs-shrunk":
        def keep(line: str) -> bool:
            cell = line.strip().strip("|").split("|")[0].strip() if line.lstrip().startswith("|") else None
            return (cell is None or cell in ("Model",) or cell.startswith("-") or any(cell.startswith(n) for n in SHRUNK_NAMES))
        lines = [line for line in lines if keep(line)]
    return "\n".join(lines) + "\n"


class FakeVendor:
    def __init__(self):
        self.config = "catalog-ok"
        self.docs = "docs-ok"
        self.calls: list[dict] = []
        self.app = Starlette(routes=[
            Route("/console/api/v2/config", self._config, methods=["GET"]),
            Route("/anomalyco/opencode/dev/go.mdx", self._docs, methods=["GET"]),
        ])

    def _reply(self, request: Request, behaviour: str, response: Response) -> Response:
        call = {"source": "config" if "config" in request.url.path else "docs", "path": request.url.path,
                "headers": dict(request.headers), "behaviour": behaviour}
        self.calls.append(call)
        body = getattr(response, "body", b"")
        attach_json(f"vendor {request.url.path} → {response.status_code}",
                    {"behaviour": behaviour, "request": {"path": request.url.path, "headers": _redacted(_headers(request.headers))},
                     "response": {"status": response.status_code, "body": _body_of(body, response.media_type)}})
        return response

    async def _config(self, request: Request) -> Response:
        b = self.config
        if b == "catalog-503":
            return self._reply(request, b, JSONResponse({"error": "unavailable"}, status_code=503))
        if b == "catalog-401-echo":
            return self._reply(request, b, JSONResponse({"error": f"invalid key {GO_KEY}"}, status_code=401))
        return self._reply(request, b, JSONResponse(config_doc(b)))

    async def _docs(self, request: Request) -> Response:
        b = self.docs
        if b == "docs-404":
            return self._reply(request, b, PlainTextResponse("404: Not Found", status_code=404))
        return self._reply(request, b, PlainTextResponse(docs_text(b), media_type="text/plain"))


def _redacted(h: dict) -> dict:
    """The fake's own attachment never carries the key either (the GW-REDACT discipline in evidence)."""
    return {k: ("Bearer <the Go key>" if k.lower() == "authorization" else v) for k, v in h.items()}


class VendorTransport(httpx.AsyncBaseTransport):
    """The vendor's two hosts to the fake vendor; every other host to the rails' transport."""

    def __init__(self, vendor: FakeVendor, rails: RailTransport):
        self.vendor = httpx.ASGITransport(app=vendor.app)
        self.rails = rails
        self.down: set[str] = set()  # `catalog-down` / `docs-down`: a connect failure

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        host = request.url.host
        if host in (httpx.URL(CONFIG_URL).host, httpx.URL(DOCS_URL).host):
            source = "config" if host == httpx.URL(CONFIG_URL).host else "docs"
            if source in self.down:
                raise httpx.ConnectError(f"{source} vendor unreachable (fake)", request=request)
            return await self.vendor.handle_async_request(request)
        return await self.rails.handle_async_request(request)


def catalog_settings(db_path: str, key: str | None = GO_KEY) -> Settings:
    env = {"GATEWAY_POLICY": str(POLICY_FIXTURE), "GATEWAY_DB": db_path, "GATEWAY_SELF_URL": SELF_URL,
           "ANTHROPIC_UPSTREAM": UPSTREAM_BASES["anthropic"], "OPENROUTER_UPSTREAM": UPSTREAM_BASES["openrouter"],
           "OPENCODE_GO_UPSTREAM": UPSTREAM_BASES["opencode"], "GATEWAY_GO_CATALOG_URL": CONFIG_URL,
           "GATEWAY_GO_DOCS_URL": DOCS_URL}
    if key:
        env["OPENCODE_GO_API_KEY"] = key
    return Settings.from_env(env)


@pytest.fixture
def vendor() -> FakeVendor:
    return FakeVendor()


@pytest.fixture
def vendor_transport(vendor, transport) -> VendorTransport:
    return VendorTransport(vendor, transport)


class CatalogWorld:
    """Builds gateways on one DB path (a restart = a second build on the same path)."""

    def __init__(self, tmp_path, policy, secrets, clock, reviews, vendor_transport):
        self.db = str(tmp_path / "gateway.db")
        self.policy, self.secrets, self.clock, self.reviews = policy, secrets, clock, reviews
        self.transport = vendor_transport
        self.clients: list[httpx.AsyncClient] = []

    def build(self, key: str | None = GO_KEY):
        client = httpx.AsyncClient(transport=self.transport)
        self.clients.append(client)
        from agent_gateway.store import Store
        return create_app(catalog_settings(self.db, key), policy=self.policy, source=self.secrets, store=Store(self.db),
                          client=client, clock=self.clock, reviewer=self.reviews)


@pytest.fixture
async def cworld(tmp_path, policy, secrets, clock, reviews, vendor_transport):
    w = CatalogWorld(tmp_path, policy, secrets, clock, reviews, vendor_transport)
    yield w
    for c in w.clients:
        await c.aclose()


def gw_client(app) -> ObservedAsyncClient:
    return ObservedAsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://gw")
