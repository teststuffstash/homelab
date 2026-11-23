"""The Go catalog's fake vendor (GW-CATALOG-GO; specs/worlds/README.md §The Go catalog's fakes).

One in-process Starlette app answers the three reads the leg makes — models.dev's `api.json` (the
catalog), the console's V2 config (the workspace overlay) and the vendor's Go page source and Go models list — from
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
    GO_LIMITS_URL,
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
LIMITS_URL = GO_LIMITS_URL
HOSTS = {httpx.URL(u).host: read for read, u in (("catalog", CATALOG_URL), ("config", CONFIG_URL), ("docs", DOCS_URL), ("limits", LIMITS_URL))}
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
    elif behaviour == "config-adds-gemini":  # #2933 round 2: a COMPLETE override for the id the
        # catalog read DROPPED (gemini-4-argon on @ai-sdk/google) — the overlay still never
        # re-lists a dropped id (a guessed dialect would be its cost)
        models["gemini-4-argon"] = {"name": "Gemini 4 Argon", "family": "gemini",
                                    "cost": [{"input": 2.0, "output": 10.0, "cache": {"read": 0.1}}],
                                    "limit": {"context": 1000000, "output": 384000}}
    elif behaviour == "config-malformed":
        models["deepseek-v4-pro"] = {"cost": "free"}
    elif behaviour == "config-no-provider":
        del doc["providers"]["opencode-go"]
    return doc


LIMITS_FIVE = {"deepseek-v4.1-flash": (80, 160), "step-5-preview": (60, 240), "deepseek-v4-pro": (15, 60), "claude-haiku-5-5": (15, 60)}
PEAK_INPUTS = {"deepseek-v4.1-flash": (0.15, 0.6, 0.003), "deepseek-v4-pro": (0.66, 1.98, 0.022)}
PEAK_WHEN = {"when": {"utc_days": {"in": ["mon", "tue", "wed", "thu", "fri"]},
                      "any": [{"all": [{"utc_hours": {"gte": "01:00"}}, {"utc_hours": {"lt": "04:00"}}]},
                              {"all": [{"utc_hours": {"gte": "06:00"}}, {"utc_hours": {"lt": "10:00"}}]}]}, "factor": 2}
NULL_ROW_ID = "longcat-2.5-preview-free"


def limits_fixture() -> list[dict]:
    """The `data[]` list of the recorded limits answer (fixtures/go-catalog/limits.json)."""
    return json.loads((FIXTURES / "limits.json").read_text(encoding="utf-8"))


def _limits_ok() -> list[dict]:
    """`limits-ok`: five rows derived from the recorded fixture — its rows of the four ids it holds plus its
    first `monthly_usage: null` row under `longcat-2.5-preview-free` (a stand-in with a non-null row when the
    cut lacks one of the five ids), with the world's limits and the two DeepSeek rows' peak inputs written in."""
    rows = {r["id"]: r for r in limits_fixture()}
    first_limited = next(r for r in rows.values() if r["go"]["monthly_usage"] is not None)
    first_null = next(r for r in rows.values() if r["go"]["monthly_usage"] is None)
    out = []
    for mid, (go, plus) in LIMITS_FIVE.items():
        row = copy.deepcopy(rows.get(mid, first_limited))
        row["id"] = mid
        row["go"]["monthly_usage"] = {**(row["go"]["monthly_usage"] or {}), "go": go, "go-plus": plus}
        row.setdefault("cost", {}).pop("multipliers", None)
        if mid in PEAK_INPUTS:
            i, o, cr = PEAK_INPUTS[mid]
            row["cost"]["text"] = {"input": {"price": i, "cache": {"read": cr}}, "output": {"price": o}}
            row["cost"]["multipliers"] = [copy.deepcopy(PEAK_WHEN)]
        out.append(row)
    null = copy.deepcopy(rows.get(NULL_ROW_ID, first_null))
    null["id"] = NULL_ROW_ID
    null["go"]["monthly_usage"] = None
    out.append(null)
    return out


def limits_doc(behaviour: str) -> dict:
    if behaviour == "limits-recorded":
        return {"object": "list", "data": limits_fixture()}
    if behaviour == "limits-no-data":
        return {"object": "list"}
    data = _limits_ok()
    by = {r["id"]: r for r in data}
    if behaviour in ("docs-retired",):
        data = [r for r in data if r["id"] != "claude-haiku-5-5"]
    elif behaviour == "limits-shrunk":
        data = [r for r in data if r["id"] in SHRUNK]
    elif behaviour == "limits-no-go-plus":
        del by["deepseek-v4-pro"]["go"]["monthly_usage"]["go-plus"]
    elif behaviour == "limits-odd-when":
        by["deepseek-v4-pro"]["cost"]["multipliers"][0]["when"] = {"region": {"in": ["eu"]}}
    elif behaviour == "limits-two-windows":
        by["deepseek-v4-pro"]["cost"]["multipliers"][0]["when"]["any"][1]["all"][0]["utc_hours"]["gte"] = "07:00"
    elif behaviour == "limits-no-peak":
        for mid in SHRUNK:
            del by[mid]["cost"]["multipliers"]
    elif behaviour == "limits-dated":  # the shape the vendor's own gemini-4-argon row carries in the record of 2026-11-23
        dated = copy.deepcopy(by["step-5-preview"])
        dated["id"] = "gemini-4-argon"
        dated["cost"]["multipliers"] = [{"when": {"date": {"gte": "2026-12-01"}}, "factor": 2}]
        data.append(dated)
    return {"object": "list", "data": data}


def docs_text(behaviour: str) -> str:
    text = (FIXTURES / "go.mdx").read_text(encoding="utf-8")
    lines = text.splitlines()
    if behaviour == "docs-no-go-plus":  # the Plan table without its Go Plus row — the fees
        # cannot price both plans: a whole-source parse failure (the no-table knob's sibling)
        lines = [line for line in lines if _first_cell(line) != "**Go Plus**"]
    elif behaviour == "docs-no-shares":  # the page without its two share bullets
        lines = [line for line in lines if not line.startswith(("- The **5-hour limit**", "- The **weekly limit**"))]
    elif behaviour == "docs-no-plan-table":  # the page without its Plan | Price table (the fee's home)
        lines = _drop_orphan_rules([line for line in lines if _first_cell(line) not in ("Plan", "**Go**", "**Go Plus**", "**Go Teams**")])
    return "\n".join(lines) + "\n"


def _first_cell(line: str) -> str | None:
    return line.strip().strip("|").split("|")[0].strip() if line.lstrip().startswith("|") else None


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
        self.limits = "limits-ok"
        self.calls: list[dict] = []
        self.app = Starlette(routes=[
            Route("/api.json", self._catalog, methods=["GET"]),
            Route("/console/api/v2/config", self._config, methods=["GET"]),
            Route("/anomalyco/opencode/dev/go.mdx", self._docs, methods=["GET"]),
            Route("/inference/go/v1/models", self._limits, methods=["GET"]),
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
        if b == "config-200-echo":
            return self._reply(request, b, JSONResponse({"note": f"key {GO_KEY}"}))
        return self._reply(request, b, JSONResponse(config_doc(b)))

    async def _docs(self, request: Request) -> Response:
        b = self.docs
        if b == "docs-404":
            return self._reply(request, b, PlainTextResponse("404: Not Found", status_code=404))
        return self._reply(request, b, PlainTextResponse(docs_text("docs-ok" if b == "docs-retired" else b), media_type="text/plain"))

    async def _limits(self, request: Request) -> Response:
        b = "docs-retired" if self.docs == "docs-retired" else self.limits  # `docs-retired` = limits-ok without haiku's row
        if b == "limits-503":
            return self._reply(request, b, JSONResponse({"error": "unavailable"}, status_code=503))
        return self._reply(request, b, JSONResponse(limits_doc(b)))


def _redacted(h: dict) -> dict:
    """The fake's own attachment never carries the key either (the GW-REDACT discipline in evidence)."""
    return {k: ("Bearer <the Go key>" if k.lower() == "authorization" else v) for k, v in h.items()}


class VendorTransport(httpx.AsyncBaseTransport):
    """The vendor's three hosts to the fake vendor; every other host to the rails' transport."""

    def __init__(self, vendor: FakeVendor, rails: RailTransport):
        self.vendor = httpx.ASGITransport(app=vendor.app)
        self.rails = rails
        self.attempts: dict[str, int] = {}
        self.down: set[str] = set()  # `catalog-down` / `config-down` / `docs-down` / `limits-down`: a connect failure on that read

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        read = HOSTS.get(request.url.host)
        if read is not None:
            self.attempts[read] = self.attempts.get(read, 0) + 1  # an answered request and a refused connection each count one
            if read in self.down:
                raise httpx.ConnectError(f"{read} vendor unreachable (fake)", request=request)
            return await self.vendor.handle_async_request(request)
        return await self.rails.handle_async_request(request)


def catalog_settings(db_path: str, key: str | None = GO_KEY) -> Settings:
    env = {"GATEWAY_POLICY": str(POLICY_FIXTURE), "GATEWAY_DB": db_path, "GATEWAY_SELF_URL": SELF_URL,
           "ANTHROPIC_UPSTREAM": UPSTREAM_BASES["anthropic"], "OPENROUTER_UPSTREAM": UPSTREAM_BASES["openrouter"],
           "OPENCODE_GO_UPSTREAM": UPSTREAM_BASES["opencode"], "GATEWAY_GO_CATALOG_URL": CATALOG_URL,
           "GATEWAY_GO_CONFIG_URL": CONFIG_URL, "GATEWAY_GO_DOCS_URL": DOCS_URL, "GATEWAY_GO_LIMITS_URL": LIMITS_URL}
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
