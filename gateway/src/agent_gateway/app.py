"""Starlette app factory (the island's one wiring point)."""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time

import httpx
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, PlainTextResponse
from starlette.routing import Route

from . import __version__
from .capacity import Capacity
from .catalog import GoCatalog
from .codex import CodexBackend, CodexProxy, CodexRail, openai_responses
from .config import Policy, Settings, wire_model
from .credentials import CredentialResolver, CredentialSource, KubeSecrets
from .liveness import KubePods, PodSource
from .logging import register_literal
from .metrics import Metrics
from .orcatalog import OpenRouterCatalog
from .providers import UNATTRIBUTED, EndpointSnapshot
from .proxy import Proxy, anthropic_messages, openai_chat, openai_models
from .pull import KubeTokenReviews, TokenReviewer
from .sessions import (
    SessionService,
    delete_session,
    get_session,
    list_sessions,
    post_session_env,
    post_session_outcome,
    post_sessions,
)
from .store import Store
from .tiers import tier_evidence_age

log = logging.getLogger("gateway.app")


async def healthz(request: Request) -> JSONResponse:
    store: Store = request.app.state.store
    if not store.ping():
        return JSONResponse({"error": {"code": "db-unavailable", "message": "the store does not answer"}}, status_code=503)
    return JSONResponse({"ok": True, "db": store.mode})


async def catalog_opencode(request: Request) -> JSONResponse:
    """GW-CATALOG-GO's read-only view: the snapshots admission reads, never a credential — with the
    Go rail's price per model (GW-MODEL-TIERS §Cost per clean ride: the plan fee over what it bought)."""
    svc: SessionService = request.app.state.sessions
    pricing = svc.capacity.go_pricing("opencode", svc.clock()) if "opencode" in svc.policy.rails else None
    return JSONResponse(request.app.state.catalog.view(pricing))


async def catalog_openrouter(request: Request) -> JSONResponse:
    """GW-CATALOG-OR's read-only view: the endpoint snapshot with every cell's entry state, the
    provider the data plane would pin per model, the canary budget — never a credential."""
    svc: SessionService = request.app.state.sessions
    cat: OpenRouterCatalog = request.app.state.orcatalog
    harness = cat.canary.harness if cat.canary else "opencode"

    def order(model: str) -> list[str]:
        verdict, plan = svc.provider_plan("openrouter", model, harness, "", "", svc.clock())
        return [e.slug for e in plan] if verdict == "pinned" else []

    return JSONResponse(cat.view(order))


async def metrics(request: Request) -> PlainTextResponse:
    return PlainTextResponse(request.app.state.metrics.render(), media_type="text/plain; version=0.0.4; charset=utf-8")


async def _reprobe_loop(proxy: Proxy, every_s: float = 30.0) -> None:
    while True:
        try:
            await proxy.reprobe()
        except Exception:  # noqa: BLE001 — the loop must outlive any one probe's failure
            log.exception("credential re-probe loop: one pass failed")
        await asyncio.sleep(every_s)


async def _reap_loop(sessions: SessionService, every_s: float) -> None:
    while True:
        await asyncio.sleep(every_s)
        try:
            await sessions.reap()
        except Exception:  # noqa: BLE001 — the loop must outlive any one pass's failure
            log.exception("session reaper: one pass failed")


def create_app(
    settings: Settings,
    policy: Policy | None = None,
    source: CredentialSource | None = None,
    store: Store | None = None,
    client: httpx.AsyncClient | None = None,
    clock=time.time,
    codex_backend: CodexBackend | None = None,
    reviewer: TokenReviewer | None = None,
    reprobe_every_s: float = 30.0,
    pods: PodSource | None = None,
) -> Starlette:
    policy = policy or Policy.load(settings.policy_path)
    register_literal(settings.opencode_go_api_key)  # the Go key has no recognisable shape — GW-REDACT masks it by value
    store = store or Store(settings.db_path)
    source = source or KubeSecrets()
    resolver = CredentialResolver(policy, source, settings.opencode_go_api_key, settings.cred_cache_s,
                                  settings.cred_negative_cache_s, clock)
    m = Metrics(policy.stacks)
    m.bind_active_sessions(lambda: store.active_counts(clock()))
    client = client or httpx.AsyncClient(
        timeout=httpx.Timeout(connect=settings.connect_timeout_s, read=settings.read_timeout_s, write=60, pool=10),
        follow_redirects=False,
    )
    # The Go catalog leg (GW-CATALOG-GO): starts from the store's last good snapshots, refreshes on
    # the schedule the lifespan runs (tests call refresh() themselves — ASGI transports run no lifespan).
    # Admission reads it: the Go window draw's prices, per-model limits and not-in-catalog.
    catalog = GoCatalog(policy, store, client, settings.go_catalog_urls, settings.opencode_go_api_key, clock,
                        settings.go_catalog_refresh_s)
    m.bind_extra(catalog.render)
    # GW-SESSIONS-PULL's identity check: the kube TokenReview API (tests hand a StaticTokenReviews in).
    sessions = SessionService(policy, store, resolver, m, settings.self_url, clock,
                              capacity=Capacity(policy, store, catalog, clock), reviewer=reviewer or KubeTokenReviews())
    sessions.pods = pods or KubePods()
    m.bind_transport_facts(lambda: sessions.capacity.cooled_counts(clock()), sessions.capacity.rejected_counts)
    # The openrouter rail's provider axis (GW-RAIL-OPENROUTER): the endpoint snapshot the catalog leg
    # writes (homelab#2742) and selection reads; no snapshot = every openrouter request rides unpinned.
    providers = EndpointSnapshot(store)
    sessions.providers = providers
    or_rail = policy.rails.get("openrouter")
    or_models = {wire_model("openrouter", mid) for tier in (or_rail.models.values() if or_rail else ()) for mid in tier}
    m.bind_provider_bounds(lambda: or_models, lambda: providers.slugs() | {UNATTRIBUTED})
    # The OpenRouter catalog leg (GW-CATALOG-OR): the registry the snapshot comes from, the cells' entry
    # states and the canary gate. Runs only when the policy declares `rails.openrouter.catalog`.
    orcatalog = OpenRouterCatalog(policy, store, client, resolver, providers, settings.upstreams["openrouter"],
                                  settings.or_mcp_url, clock, settings.or_catalog_refresh_s)
    sessions.orcatalog = orcatalog if orcatalog.enabled else None
    sessions.outcomes.judge = orcatalog.judge if orcatalog.enabled else None
    if orcatalog.enabled:
        m.bind_extra(orcatalog.render)
    # GW-MODEL-TIERS: the committed tier-evidence snapshot rides beside the policy; its age is the
    # staleness alert's signal (a comparison on a month-old price is a wrong answer — #2718 item 3).
    m.bind_tier_evidence(lambda: tier_evidence_age(settings.benchmarks_path, clock()))
    proxy = Proxy(sessions, m, settings.upstreams, client)
    # The codex rail exists only when the policy declares it; it has a credential backend only when
    # one is handed in (tests: the FAKE store) — production passes none (⚑ gap), so it ships dark.
    codex = (CodexRail(policy.rails["codex"], clock, codex_backend, settings.upstreams.get("codex", ""))
             if "codex" in policy.rails else None)
    sessions.codex = codex
    if codex is not None:
        # GW-CODEX-HEADROOM §Gauges: an ACCEPTED report renders gateway_subscription_*{rail="codex"};
        # a restart renders nothing until the next one (the headroom is forgotten with the process).
        codex.headroom.on_accept = lambda snapshot: m.subscription_report("codex", snapshot.windows)
    codex_proxy = CodexProxy(sessions, m, codex, client)

    @contextlib.asynccontextmanager
    async def lifespan(app):
        log.info("agent-gateway %s up: db=%s rails=%s stacks=%s", __version__, store.mode,
                 ",".join(policy.rails), ",".join(policy.stacks))
        # A rejected credential recovers WITHOUT traffic (sessions.md §Capacity): the re-probe loop.
        task = asyncio.create_task(_reprobe_loop(proxy)) if reprobe_every_s else None
        # A session whose pod is gone is reaped (GW-SESSIONS-LIVENESS).
        reaper = asyncio.create_task(_reap_loop(sessions, policy.liveness_check_s)) if policy.liveness_check_s else None
        # The Go catalog's schedule (GW-CATALOG-GO): a refresh at start unless the stored snapshots are younger than
        # go_catalog_refresh_s (then at fetched_at + the interval — a pod roll re-reads nothing), then every interval.
        refresher = (asyncio.create_task(catalog.run(), name="go-catalog")
                     if "opencode" in policy.rails and settings.go_catalog_refresh_s > 0 else None)
        # The OpenRouter catalog's schedule (GW-CATALOG-OR): the same rule — a roll inside the interval keeps the
        # persisted refreshed_at, i.e. the canary window (#2775 gap 2).
        or_refresher = (asyncio.create_task(orcatalog.run(), name="openrouter-catalog")
                        if orcatalog.enabled and settings.or_catalog_refresh_s > 0 else None)
        try:
            yield
        finally:
            for t in (task, reaper, refresher, or_refresher):
                if t is not None:
                    t.cancel()
                    with contextlib.suppress(asyncio.CancelledError):
                        await t
            await client.aclose()
            store.close()

    openai_routes = [
        Route("/chat/completions", openai_chat, methods=["POST"]),
        Route("/models", openai_models, methods=["GET"]),
    ]
    app = Starlette(
        routes=[
            Route("/healthz", healthz, methods=["GET"]),
            Route("/metrics", metrics, methods=["GET"]),
            Route("/catalog/opencode", catalog_opencode, methods=["GET"]),
            Route("/catalog/openrouter", catalog_openrouter, methods=["GET"]),
            Route("/sessions", post_sessions, methods=["POST"]),
            Route("/sessions", list_sessions, methods=["GET"]),
            Route("/sessions/{id}", get_session, methods=["GET"]),
            Route("/sessions/{id}", delete_session, methods=["DELETE"]),
            Route("/sessions/{id}/env", post_session_env, methods=["POST"]),
            Route("/sessions/{id}/outcome", post_session_outcome, methods=["POST"]),
            Route("/anthropic/v1/messages", anthropic_messages, methods=["POST"]),
            # The OpenAI dialect under its contract prefix AND the OpenRouter-shaped `/api/v1`
            # alias: goose computes `$OPENROUTER_HOST/api/v1/…` and opencode's provider baseURL
            # is `<host>/api/v1` today (agent-session.sh), so the alias is what those harnesses
            # reach without a new launcher knob. One handler set, two prefixes.
            # The `responses` dialect (GW-RAIL-CODEX) — the contract prefix only, no `/api/v1` alias.
            Route("/openai/v1/responses", openai_responses, methods=["POST"]),
            *[Route("/openai/v1" + r.path, r.endpoint, methods=list(r.methods or [])) for r in openai_routes],
            *[Route("/api/v1" + r.path, r.endpoint, methods=list(r.methods or [])) for r in openai_routes],
        ],
        lifespan=lifespan,
    )
    app.state.settings = settings
    app.state.policy = policy
    app.state.store = store
    app.state.resolver = resolver
    app.state.metrics = m
    app.state.sessions = sessions
    app.state.capacity = sessions.capacity
    app.state.proxy = proxy
    app.state.codex = codex
    app.state.codex_proxy = codex_proxy
    app.state.catalog = catalog
    app.state.providers = providers
    app.state.orcatalog = orcatalog
    return app
