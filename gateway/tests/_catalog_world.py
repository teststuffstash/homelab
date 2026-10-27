"""The Go catalog's fake vendor (GW-CATALOG-GO; specs/worlds/README.md §The Go catalog's fakes).

One in-process Starlette app answers the three reads the leg makes — models.dev's `api.json` (the
catalog), the console's V2 config (the workspace overlay) and the vendor's Go page source — from
the fixtures in `tests/fixtures/go-catalog/` (`models-dev.json` + `config.json` trimmed from the
live answers of 2026-10-20, `go.mdx` from 2026-10-17/20). Each read has its own behaviour knob
(`catalog-*`, `config-*`, `docs-*`); the variants are derived from the fixture in memory, so the
file on disk is the one live-shaped copy. Offline, deterministic.
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
    GO_CATALOG_URL,
    GO_CONFIG_URL,
    GO_DOCS_URL,
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
CATALOG_URL = GO_CATALOG_URL
CONFIG_URL = GO_CONFIG_URL
DOCS_URL = GO_DOCS_URL
HOSTS = {httpx.URL(u).host: read for read, u in (("catalog", CATALOG_URL), ("config", CONFIG_URL), ("docs", DOCS_URL))}
SHRUNK = ("deepseek-v4-pro", "deepseek-v4.1-flash")
TRIMMED = ("claude-haiku-5-5", "deepseek-v4-pro", "deepseek-v4.1-flash")
SHRUNK_NAMES = ("DeepSeek V4.1 Flash", "DeepSeek V4 Pro")


def catalog_doc(behaviour: str) -> dict:
    """models.dev's `api.json` cut to the `opencode-go` provider: five listed models + one
    `status: deprecated` row (`step-5-preview-free`)."""
    doc = json.loads((FIXTURES / "models-dev.json").read_text(encoding="utf-8"))
    models = doc["opencode-go"]["models"]
    if behaviour == "catalog-shrunk":
        doc["opencode-go"]["models"] = {k: v for k, v in models.items() if k in SHRUNK}
    elif behaviour == "catalog-trimmed":
        doc["opencode-go"]["models"] = {k: v for k, v in models.items() if k in TRIMMED}
    elif behaviour == "catalog-retired":  # the vendor drops the policy's model (the spike's §F3, replayed)
        del models["deepseek-v4.1-flash"]
    elif behaviour == "catalog-malformed":
        del models["deepseek-v4-pro"]["cost"]
    elif behaviour == "catalog-legacy-tier":  # the legacy spelling alone: context_over_200k, no tiers
        models["deepseek-v4-pro"]["cost"]["context_over_200k"] = {"input": 1.32, "output": 3.96, "cache_read": 0.044}
        models["deepseek-v4-pro"]["cost"].pop("tiers", None)
    elif behaviour == "catalog-google":  # #2933: the vendor lists a model on a dialect the gateway
        # does not speak (@ai-sdk/google) — the row is DROPPED, the other five keep landing
        models["gemini-4-argon"] = {**copy.deepcopy(models["deepseek-v4-pro"]),
                                    "id": "gemini-4-argon", "name": "Gemini 4 Argon", "family": "gemini",
                                    "provider": {"npm": "@ai-sdk/google",
                                                 "api": "https://opencode.ai/inference/go/google/v1beta"}}
    elif behaviour == "catalog-no-provider":
        doc = {"opencode": doc["opencode-go"]}
    elif behaviour == "catalog-empty":
        doc["opencode-go"]["models"] = {}
    return doc


ADDED_ROW = {"name": "DeepSeek V4 Flash", "family": "deepseek-flash", "capabilities": {"tools": True},
             "cost": [{"input": 0.14, "output": 0.28, "cache": {"read": 0.028}}], "limit": {"context": 1000000, "output": 384000}}
REPRICED = {"cost": [{"input": 0.2, "output": 1.0, "cache": {"read": 0.02, "write": 0.25}},
                     {"tier": {"type": "context", "size": 200000}, "input": 1.0, "output": 5.0, "cache": {"read": 0.1, "write": 1.25}}],
            "limit": {"context": 200000}}


def config_doc(behaviour: str) -> dict:
    """The console's V2 config as the live answer of 2026-10-20 carries it: the workspace's overrides
    on a default catalog (`opencode` rows `disabled: true`, `opencode-go.models: {}`), then one
    override added to the Go provider per variant."""
    doc = json.loads((FIXTURES / "config.json").read_text(encoding="utf-8"))
    models = doc["providers"]["opencode-go"]["models"]
    if behaviour == "config-disables":
        models["deepseek-v4-pro"] = {"disabled": True}
    elif behaviour == "config-reprices":
        models["claude-haiku-5-5"] = copy.deepcopy(REPRICED)
    elif behaviour == "config-adds":  # a console-only row with a cost and both limits
        models["deepseek-v4-flash"] = copy.deepcopy(ADDED_ROW)
    elif behaviour == "config-adds-bare":  # a console-only row that is no row
        models["deepseek-v4-flash"] = {"disabled": False}
    elif behaviour == "config-malformed":
        models["deepseek-v4-pro"] = {"cost": "free"}
    elif behaviour == "config-no-provider":
        del doc["providers"]["opencode-go"]
    return doc


def docs_text(behaviour: str) -> str:
    text = (FIXTURES / "go.mdx").read_text(encoding="utf-8")
    lines = text.splitlines()
    if behaviour == "docs-promo":  # #2933 case (a): the live page's PROMOTION spelling on Gemini
        # 4 Argon — a trailing ` (50% off)` on a plan-row name the Endpoints table has; the plan
        # cells and the limits are the live rows of 2026-10-25, laid into the fixture's tables
        def promo_row(limit: str) -> str:
            return (f"| Gemini 4 Argon (50% off)   | ~~$4.00~~ $2.00 | ~~$20.00~~ $10.00 | ~~$0.20~~ $0.10 "
                    f"| -            | {limit} |")
        for plan_tab, limit in (("go", "**$30**"), ("go-plus", "**$120**")):
            i = next(n for n, line in enumerate(lines) if _slot_holds(lines, n, plan_tab)
                     and line.lstrip().startswith("| Claude Haiku 5.5 (> 100K tokens)"))
            lines.insert(i + 1, promo_row(limit))
        i = next(n for n, line in enumerate(lines) if line.lstrip().startswith("| Step 5 Preview")
                 and "opencode.ai/inference" in line)  # the Endpoints table's last row
        lines.insert(i + 1, "| Gemini 4 Argon             | gemini-4-argon          "
                            "| `https://opencode.ai/inference/go/google/v1beta/models/gemini-4-argon` "
                            "| `@ai-sdk/google`         |")
    elif behaviour == "docs-unknown-model":
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
    elif behaviour == "docs-retired":  # the page drops claude-haiku-5-5's plan rows (the console still lists it)
        lines = [line for line in lines if not line.lstrip().startswith("| Claude Haiku 5.5 (")]
    elif behaviour == "docs-no-plan-table":  # the page without its Plan | Price table (the fee's home)
        lines = _drop_orphan_rules([line for line in lines if _first_cell(line) not in ("Plan", "**Go**", "**Go Plus**")])
    elif behaviour == "docs-shrunk":
        def keep(line: str) -> bool:
            cell = line.strip().strip("|").split("|")[0].strip() if line.lstrip().startswith("|") else None
            return (cell is None or cell in ("Model", "Plan", "**Go**", "**Go Plus**") or cell.startswith("-")
                    or any(cell.startswith(n) for n in SHRUNK_NAMES))
        lines = [line for line in lines if keep(line)]
    return "\n".join(lines) + "\n"


def _first_cell(line: str) -> str | None:
    return line.strip().strip("|").split("|")[0].strip() if line.lstrip().startswith("|") else None


def _slot_holds(lines: list[str], n: int, slot: str) -> bool:
    """Is lines[n] inside `<div slot="…">…</div>`? (the promo derivation inserts per tab)."""
    lo = next(i for i, line in enumerate(lines) if f'<div slot="{slot}">' in line)
    hi = next(i for i, line in enumerate(lines[lo + 1:], lo + 1) if line.lstrip().startswith("</div>"))
    return lo < n < hi


def _drop_orphan_rules(lines: list[str]) -> list[str]:
    """A table rule line (`| --- |`) whose header was removed is dropped with it."""
    out: list[str] = []
    for line in lines:
        if line.lstrip().startswith("| ---") and (not out or not out[-1].lstrip().startswith("|")):
            continue
        out.append(line)
    return out


class FakeVendor:
    def __init__(self):
        self.catalog = "catalog-ok"
        self.config = "config-ok"
        self.docs = "docs-ok"
        self.calls: list[dict] = []
        self.app = Starlette(routes=[
            Route("/api.json", self._catalog, methods=["GET"]),
            Route("/console/api/v2/config", self._config, methods=["GET"]),
            Route("/anomalyco/opencode/dev/go.mdx", self._docs, methods=["GET"]),
        ])

    def _reply(self, request: Request, behaviour: str, response: Response) -> Response:
        call = {"source": HOSTS[request.url.hostname], "path": request.url.path,
                "headers": dict(request.headers), "behaviour": behaviour}
        self.calls.append(call)
        body = getattr(response, "body", b"")
        attach_json(f"vendor {request.url.path} → {response.status_code}",
                    {"behaviour": behaviour, "request": {"path": request.url.path, "headers": _redacted(_headers(request.headers))},
                     "response": {"status": response.status_code, "body": _body_of(body, response.media_type)}})
        return response

    async def _catalog(self, request: Request) -> Response:
        b = self.catalog
        if b == "catalog-503":
            return self._reply(request, b, JSONResponse({"error": "unavailable"}, status_code=503))
        return self._reply(request, b, JSONResponse(catalog_doc(b)))

    async def _config(self, request: Request) -> Response:
        b = self.config
        if b == "config-503":
            return self._reply(request, b, JSONResponse({"error": "unavailable"}, status_code=503))
        if b == "config-401-echo":
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
    """The vendor's three hosts to the fake vendor; every other host to the rails' transport."""

    def __init__(self, vendor: FakeVendor, rails: RailTransport):
        self.vendor = httpx.ASGITransport(app=vendor.app)
        self.rails = rails
        self.down: set[str] = set()  # `catalog-down` / `config-down` / `docs-down`: a connect failure on that read

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        read = HOSTS.get(request.url.host)
        if read is not None:
            if read in self.down:
                raise httpx.ConnectError(f"{read} vendor unreachable (fake)", request=request)
            return await self.vendor.handle_async_request(request)
        return await self.rails.handle_async_request(request)


def catalog_settings(db_path: str, key: str | None = GO_KEY) -> Settings:
    env = {"GATEWAY_POLICY": str(POLICY_FIXTURE), "GATEWAY_DB": db_path, "GATEWAY_SELF_URL": SELF_URL,
           "ANTHROPIC_UPSTREAM": UPSTREAM_BASES["anthropic"], "OPENROUTER_UPSTREAM": UPSTREAM_BASES["openrouter"],
           "OPENCODE_GO_UPSTREAM": UPSTREAM_BASES["opencode"], "GATEWAY_GO_CATALOG_URL": CATALOG_URL,
           "GATEWAY_GO_CONFIG_URL": CONFIG_URL, "GATEWAY_GO_DOCS_URL": DOCS_URL}
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
